from __future__ import annotations

import logging
import sys
import threading
import time
from pathlib import Path
from typing import Optional

from .config import AppConfig
from .hand_mapping import Go2Command, HandToGo2Mapper
from .renderer import VisionOverlayRenderer
from .simulator import RedBlockSimulator
from .swift_bridge import SwiftBridgeServer
from .unitree_bridge import (
    DryRunMotionClient,
    OpenCVCameraClient,
    PlaceholderCameraClient,
    UnitreeGo2CameraClient,
    UnitreeGo2MotionClient,
    initialize_unitree_dds,
)


LOGGER = logging.getLogger(__name__)


def _load_vision_pro_streamer():
    try:
        from avp_stream import VisionProStreamer  # type: ignore
        return VisionProStreamer
    except ModuleNotFoundError:
        # Fallback to local repo checkout: ../visionProTeleop/avp_stream
        workspace_root = Path(__file__).resolve().parents[2]
        local_vpt = workspace_root / "visionProTeleop"
        if (local_vpt / "avp_stream").exists():
            sys.path.insert(0, str(local_vpt))
            from avp_stream import VisionProStreamer  # type: ignore
            return VisionProStreamer
        raise


class Go2TeleopApp:
    def __init__(self, config: AppConfig) -> None:
        self.cfg = config
        self.renderer = VisionOverlayRenderer()
        self.mapper = HandToGo2Mapper(
            pinch_threshold=config.pinch_threshold,
            deadband_m=config.deadband_m,
            deadband_yaw=config.deadband_yaw,
            gain_forward=config.gain_forward,
            gain_lateral=config.gain_lateral,
            gain_yaw=config.gain_yaw,
            max_forward=config.max_forward,
            max_lateral=config.max_lateral,
            max_yaw=config.max_yaw,
        )

        self._stop_event = threading.Event()
        self._camera_thread: Optional[threading.Thread] = None
        self._camera_client = None
        self._motion_client = None
        self._streamer = None
        self._swift_bridge: Optional[SwiftBridgeServer] = None
        self._simulator: Optional[RedBlockSimulator] = None
        self._sent_nonzero_motion = False
        self._last_tracking_ts = 0.0

    def run(self) -> None:
        try:
            self._setup_clients()
            self._setup_input_source()
            self._start_camera_loop()
            self._control_loop()
        except KeyboardInterrupt:
            LOGGER.info("Interrupted, shutting down...")
        finally:
            self._shutdown()

    def _setup_input_source(self) -> None:
        if self.cfg.input_source == "avp":
            self._setup_vision_stream()
            return

        self._swift_bridge = SwiftBridgeServer(
            bind_host=self.cfg.swift_bind_host,
            ws_port=self.cfg.swift_ws_port,
            http_port=self.cfg.swift_http_port,
        )
        self._swift_bridge.start()

    def _setup_clients(self) -> None:
        if self.cfg.simulation_mode == "block":
            self._camera_client = self._create_local_camera_client()
            self._motion_client = None
            self._simulator = RedBlockSimulator(canvas_px=self.cfg.simulation_canvas_px)
            self._simulator.start()
            LOGGER.info("Simulation mode enabled: controlling local red block window.")
            return

        if self.cfg.dry_run:
            self._camera_client = self._create_local_camera_client()
            self._motion_client = None if self.cfg.no_motion else DryRunMotionClient()
            LOGGER.info("Running in dry-run mode (webcam + logged commands).")
            return

        initialize_unitree_dds(self.cfg.dds_domain, self.cfg.network_interface)
        self._camera_client = UnitreeGo2CameraClient()
        self._motion_client = None if self.cfg.no_motion else UnitreeGo2MotionClient()

        if self.cfg.start_stand and self._motion_client is not None:
            self._motion_client.stand_up()

    def _create_local_camera_client(self):
        if self.cfg.webcam_index < 0:
            LOGGER.info("Local webcam disabled (--webcam-index %d). Using synthetic placeholder feed.", self.cfg.webcam_index)
            return PlaceholderCameraClient()
        return OpenCVCameraClient(self.cfg.webcam_index)

    def _setup_vision_stream(self) -> None:
        try:
            VisionProStreamer = _load_vision_pro_streamer()
        except ModuleNotFoundError as exc:
            raise ModuleNotFoundError(
                "Could not import avp_stream. Install AVP extras with "
                "`python3 -m pip install -e \".[avp]\"` or keep visionProTeleop next to this repo."
            ) from exc

        if not self.cfg.vision_pro_ip:
            raise ValueError("--vision-pro-ip is required for AVP input mode.")

        self._streamer = VisionProStreamer(
            ip=self.cfg.vision_pro_ip,
            ht_backend=self.cfg.hand_tracking_backend,
        )
        self._streamer.register_frame_callback(self.renderer.render)
        self._streamer.configure_video(
            device=None,
            size=self.cfg.stream_size,
            fps=self.cfg.stream_fps,
        )
        self._streamer.start_webrtc(port=self.cfg.webrtc_port)
        LOGGER.info("Vision Pro stream started on port %d.", self.cfg.webrtc_port)

    def _start_camera_loop(self) -> None:
        self._camera_thread = threading.Thread(target=self._camera_loop, daemon=True, name="go2-camera-loop")
        self._camera_thread.start()

    def _camera_loop(self) -> None:
        period = 1.0 / max(self.cfg.camera_hz, 1e-6)
        while not self._stop_event.is_set():
            start = time.perf_counter()
            frame = None
            if self._camera_client is not None:
                try:
                    frame = self._camera_client.read_frame()
                except Exception as exc:
                    LOGGER.debug("Camera read failed: %s", exc)
            if frame is not None:
                self.renderer.update_camera(frame)
                if self._swift_bridge is not None:
                    self._swift_bridge.update_camera(frame)

            elapsed = time.perf_counter() - start
            time.sleep(max(0.0, period - elapsed))

    def _control_loop(self) -> None:
        period = 1.0 / max(self.cfg.control_hz, 1e-6)
        LOGGER.info("Teleoperation loop started. Right-hand pinch enables movement.")
        while not self._stop_event.is_set():
            start = time.perf_counter()

            tracking = None
            if self.cfg.input_source == "avp" and self._streamer is not None:
                try:
                    tracking = self._streamer.get_latest(use_cache=True, cache_ms=8)
                except Exception as exc:
                    LOGGER.debug("Hand tracking fetch failed: %s", exc)
            elif self.cfg.input_source == "swift" and self._swift_bridge is not None:
                tracking = self._swift_bridge.get_latest_tracking(max_age_s=self.cfg.command_timeout_s)

            if tracking is not None:
                self._last_tracking_ts = time.monotonic()
                cmd = self.mapper.update(tracking)
            else:
                cmd = Go2Command(enabled=False, tracking_ok=False, pinch_active=False)

            # Hard safety timeout on stale tracking.
            if (time.monotonic() - self._last_tracking_ts) > self.cfg.command_timeout_s:
                self.mapper.reset()
                cmd = Go2Command(enabled=False, tracking_ok=False, pinch_active=False)

            self.renderer.update_command(cmd)
            if self._simulator is not None:
                self._simulator.update_command(cmd)
            self._send_motion_command(cmd)

            elapsed = time.perf_counter() - start
            time.sleep(max(0.0, period - elapsed))

    def _send_motion_command(self, cmd: Go2Command) -> None:
        if self._motion_client is None:
            return

        if cmd.enabled:
            self._motion_client.send_velocity(cmd.vx, cmd.vy, cmd.vyaw)
            if abs(cmd.vx) > 1e-4 or abs(cmd.vy) > 1e-4 or abs(cmd.vyaw) > 1e-4:
                self._sent_nonzero_motion = True
        elif self._sent_nonzero_motion:
            self._motion_client.stop()
            self._sent_nonzero_motion = False

    def _shutdown(self) -> None:
        self._stop_event.set()

        if self._camera_thread is not None and self._camera_thread.is_alive():
            self._camera_thread.join(timeout=1.0)

        if self._motion_client is not None:
            try:
                self._motion_client.stop()
            except Exception:
                pass
            try:
                self._motion_client.close()
            except Exception:
                pass

        if self._camera_client is not None:
            try:
                self._camera_client.close()
            except Exception:
                pass

        if self._streamer is not None:
            try:
                self._streamer.cleanup()
            except Exception:
                pass

        if self._swift_bridge is not None:
            try:
                self._swift_bridge.stop()
            except Exception:
                pass
        if self._simulator is not None:
            try:
                self._simulator.stop()
            except Exception:
                pass
