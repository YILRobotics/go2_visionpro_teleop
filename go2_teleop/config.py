from __future__ import annotations

import argparse
from dataclasses import dataclass
from typing import Optional, Tuple


@dataclass(slots=True)
class AppConfig:
    vision_pro_ip: Optional[str]
    webrtc_port: int
    stream_size: str
    stream_fps: int
    control_hz: float
    camera_hz: float
    hand_tracking_backend: str
    input_source: str
    pinch_threshold: float
    deadband_m: float
    deadband_yaw: float
    gain_forward: float
    gain_lateral: float
    gain_yaw: float
    max_forward: float
    max_lateral: float
    max_yaw: float
    command_timeout_s: float
    dds_domain: int
    network_interface: Optional[str]
    start_stand: bool
    no_motion: bool
    dry_run: bool
    webcam_index: int
    simulation_mode: str
    simulation_canvas_px: int
    swift_bind_host: str
    swift_ws_port: int
    swift_http_port: int

    @property
    def stream_resolution(self) -> Tuple[int, int]:
        try:
            width_str, height_str = self.stream_size.lower().split("x")
            width = int(width_str)
            height = int(height_str)
        except ValueError as exc:
            raise ValueError(
                f"Invalid stream size '{self.stream_size}'. Use WIDTHxHEIGHT, e.g. 1280x720."
            ) from exc
        if width <= 0 or height <= 0:
            raise ValueError(f"Invalid stream size '{self.stream_size}'. Width and height must be > 0.")
        return width, height

    def validate(self) -> None:
        if self.input_source == "avp" and not self.vision_pro_ip:
            raise ValueError("--vision-pro-ip is required when --input-source=avp.")
        if self.simulation_mode not in {"off", "block"}:
            raise ValueError(f"Unsupported simulation mode: {self.simulation_mode}")
        if self.simulation_canvas_px < 320:
            raise ValueError("--simulation-canvas-px must be >= 320.")

    @classmethod
    def from_cli(cls) -> "AppConfig":
        parser = build_arg_parser()
        args = parser.parse_args()
        config = cls(
            vision_pro_ip=args.vision_pro_ip if args.vision_pro_ip else None,
            webrtc_port=args.webrtc_port,
            stream_size=args.stream_size,
            stream_fps=args.stream_fps,
            control_hz=args.control_hz,
            camera_hz=args.camera_hz,
            hand_tracking_backend=args.hand_tracking_backend,
            input_source=args.input_source,
            pinch_threshold=args.pinch_threshold,
            deadband_m=args.deadband_m,
            deadband_yaw=args.deadband_yaw,
            gain_forward=args.gain_forward,
            gain_lateral=args.gain_lateral,
            gain_yaw=args.gain_yaw,
            max_forward=args.max_forward,
            max_lateral=args.max_lateral,
            max_yaw=args.max_yaw,
            command_timeout_s=args.command_timeout_s,
            dds_domain=args.dds_domain,
            network_interface=args.network_interface,
            start_stand=args.start_stand,
            no_motion=args.no_motion,
            dry_run=args.dry_run,
            webcam_index=args.webcam_index,
            simulation_mode=args.simulation_mode,
            simulation_canvas_px=args.simulation_canvas_px,
            swift_bind_host=args.swift_bind_host,
            swift_ws_port=args.swift_ws_port,
            swift_http_port=args.swift_http_port,
        )
        config.validate()
        return config


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Teleoperate Unitree Go2 from Vision Pro hand tracking and stream Go2 camera back."
    )

    parser.add_argument(
        "--vision-pro-ip",
        default=None,
        help="Vision Pro IP address (or Tracking Streamer room code in cross-network mode).",
    )
    parser.add_argument("--webrtc-port", type=int, default=9999, help="Local WebRTC offer port.")
    parser.add_argument("--stream-size", type=str, default="1280x720", help="Outgoing stream size WIDTHxHEIGHT.")
    parser.add_argument("--stream-fps", type=int, default=30, help="Outgoing stream FPS to Vision Pro.")
    parser.add_argument("--control-hz", type=float, default=30.0, help="Go2 command update rate in Hz.")
    parser.add_argument("--camera-hz", type=float, default=25.0, help="Go2 camera polling rate in Hz.")
    parser.add_argument(
        "--hand-tracking-backend",
        choices=["grpc", "webrtc"],
        default="grpc",
        help="Transport for incoming hand tracking data.",
    )
    parser.add_argument(
        "--input-source",
        choices=["avp", "swift"],
        default="avp",
        help="Tracking source: `avp` for Tracking Streamer app, `swift` for Go2TeleopVision app.",
    )

    parser.add_argument("--pinch-threshold", type=float, default=0.03, help="Pinch distance threshold in meters.")
    parser.add_argument("--deadband-m", type=float, default=0.015, help="Deadband for wrist position deltas.")
    parser.add_argument("--deadband-yaw", type=float, default=0.08, help="Deadband for wrist roll delta in radians.")
    parser.add_argument("--gain-forward", type=float, default=2.0, help="Gain for forward velocity from wrist x.")
    parser.add_argument("--gain-lateral", type=float, default=1.5, help="Gain for lateral velocity from wrist y.")
    parser.add_argument("--gain-yaw", type=float, default=1.8, help="Gain for yaw velocity from wrist roll.")
    parser.add_argument("--max-forward", type=float, default=0.35, help="Max |vx| in m/s.")
    parser.add_argument("--max-lateral", type=float, default=0.25, help="Max |vy| in m/s.")
    parser.add_argument("--max-yaw", type=float, default=0.8, help="Max |vyaw| in rad/s.")
    parser.add_argument(
        "--command-timeout-s",
        type=float,
        default=0.25,
        help="Safety timeout: if tracking is stale for this duration, stop the robot.",
    )

    parser.add_argument("--dds-domain", type=int, default=0, help="DDS domain id for real robot (usually 0).")
    parser.add_argument(
        "--network-interface",
        type=str,
        default=None,
        help="Optional network interface for Unitree DDS (e.g. enp3s0).",
    )
    parser.add_argument("--start-stand", action="store_true", help="Send stand-up command on startup if available.")
    parser.add_argument("--no-motion", action="store_true", help="Do not send movement commands.")

    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Use local webcam and log commands instead of controlling a real Go2.",
    )
    parser.add_argument("--webcam-index", type=int, default=0, help="OpenCV camera index for dry-run mode.")
    parser.add_argument(
        "--simulation-mode",
        choices=["off", "block"],
        default="off",
        help="Simple local simulation mode. `block` controls a red block window on this computer.",
    )
    parser.add_argument(
        "--simulation-canvas-px",
        type=int,
        default=700,
        help="Local simulation window size in pixels.",
    )
    parser.add_argument(
        "--swift-bind-host",
        type=str,
        default="0.0.0.0",
        help="Bind host for Swift app bridge endpoints.",
    )
    parser.add_argument(
        "--swift-ws-port",
        type=int,
        default=8765,
        help="WebSocket port for receiving hand packets from Swift app.",
    )
    parser.add_argument(
        "--swift-http-port",
        type=int,
        default=8080,
        help="HTTP port exposing /snapshot.jpg for Swift app camera preview.",
    )

    return parser
