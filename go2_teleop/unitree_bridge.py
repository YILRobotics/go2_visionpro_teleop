from __future__ import annotations

import importlib
import logging
import platform
import re
import subprocess
import time
from typing import Any, Iterable, Optional

import cv2
import numpy as np


LOGGER = logging.getLogger(__name__)
_DDS_INITIALIZED = False


class UnitreeSDKUnavailable(RuntimeError):
    pass


def initialize_unitree_dds(domain_id: int, network_interface: Optional[str]) -> None:
    """Initialize Unitree DDS once before creating Go2 clients."""
    global _DDS_INITIALIZED
    if _DDS_INITIALIZED:
        return

    try:
        channel_module = importlib.import_module("unitree_sdk2py.core.channel")
        init_fn = getattr(channel_module, "ChannelFactoryInitialize")
    except Exception as exc:
        raise UnitreeSDKUnavailable(
            "unitree_sdk2py is not available. Install unitree_sdk2_python first."
        ) from exc

    kwargs: dict[str, Any] = {}
    if network_interface:
        kwargs["networkInterface"] = network_interface
    init_fn(domain_id, **kwargs)
    _DDS_INITIALIZED = True


def _import_attr(module_candidates: Iterable[str], attr_name: str) -> Any:
    last_exc: Optional[Exception] = None
    for module_name in module_candidates:
        try:
            module = importlib.import_module(module_name)
        except Exception as exc:
            last_exc = exc
            continue
        if hasattr(module, attr_name):
            return getattr(module, attr_name)

    raise UnitreeSDKUnavailable(
        f"Could not import '{attr_name}' from candidates: {list(module_candidates)}"
    ) from last_exc


class DryRunMotionClient:
    def __init__(self) -> None:
        self._last_log_ts = 0.0

    def send_velocity(self, vx: float, vy: float, vyaw: float) -> None:
        now = time.monotonic()
        if now - self._last_log_ts >= 0.25:
            LOGGER.info("[DRY-RUN] cmd: vx=%+.3f vy=%+.3f vyaw=%+.3f", vx, vy, vyaw)
            self._last_log_ts = now

    def stop(self) -> None:
        LOGGER.info("[DRY-RUN] stop")

    def close(self) -> None:
        return


class UnitreeGo2MotionClient:
    """Wrapper around Unitree Go2 SportClient with method-name compatibility handling."""

    def __init__(self, timeout_s: float = 0.5) -> None:
        sport_cls = _import_attr(
            (
                "unitree_sdk2py.go2.sport.sport_client",
                "unitree_sdk2py.go2.sport_client",
            ),
            "SportClient",
        )
        self._client = sport_cls()
        self._best_effort_call(("SetTimeout",), timeout_s)
        self._best_effort_call(("Init",))

    def stand_up(self) -> None:
        self._best_effort_call(("StandUp", "RecoveryStand", "BalanceStand"))

    def send_velocity(self, vx: float, vy: float, vyaw: float) -> None:
        move = getattr(self._client, "Move", None) or getattr(self._client, "move", None)
        if move is None:
            raise RuntimeError("Go2 SportClient does not expose a Move method.")

        # SDK variants use either continous_move or continuous_move.
        call_variants = (
            {"continous_move": False},
            {"continuous_move": False},
            {},
        )
        for kwargs in call_variants:
            try:
                move(vx, vy, vyaw, **kwargs)
                return
            except TypeError:
                continue
        # Final fallback to positional 3-arg signature.
        move(vx, vy, vyaw)

    def stop(self) -> None:
        if self._best_effort_call(("StopMove", "Stop", "Damp", "Stand")):
            return
        self.send_velocity(0.0, 0.0, 0.0)

    def close(self) -> None:
        try:
            self.stop()
        except Exception:
            pass

    def _best_effort_call(self, method_names: Iterable[str], *args: Any, **kwargs: Any) -> bool:
        for name in method_names:
            method = getattr(self._client, name, None)
            if method is None:
                continue
            try:
                method(*args, **kwargs)
                return True
            except TypeError:
                try:
                    method(*args)
                    return True
                except Exception:
                    continue
            except Exception:
                continue
        return False


class OpenCVCameraClient:
    def __init__(self, camera_index: int = 0) -> None:
        self._cap: Optional[cv2.VideoCapture] = None
        if platform.system().lower() == "darwin" and camera_index == 0:
            listed = _mac_avfoundation_video_devices()
            if listed:
                formatted = ", ".join(f"[{idx}] {name}" for idx, name in listed)
                LOGGER.info("Detected macOS cameras: %s", formatted)
        attempts = list(_iter_camera_open_attempts(camera_index))
        for idx, backend in attempts:
            cap = _open_camera_capture(idx, backend)
            if cap is None:
                continue
            self._cap = cap
            backend_name = _camera_backend_name(backend)
            LOGGER.info("Opened webcam index %d using backend %s.", idx, backend_name)
            break

        if self._cap is None:
            attempt_text = ", ".join(
                f"{idx}/{_camera_backend_name(backend)}" for idx, backend in attempts
            )
            raise RuntimeError(
                f"Failed to open webcam. Tried: {attempt_text}. "
                "On macOS, grant Camera permission to your terminal in "
                "System Settings > Privacy & Security > Camera."
            )

    def read_frame(self) -> Optional[np.ndarray]:
        if self._cap is None:
            return None
        ok, frame = self._cap.read()
        if not ok:
            return None
        return frame

    def close(self) -> None:
        if self._cap is not None:
            self._cap.release()
            self._cap = None


class PlaceholderCameraClient:
    """Synthetic camera feed used when local webcam access is unavailable."""

    def __init__(self, width: int = 1280, height: int = 720) -> None:
        self._width = width
        self._height = height
        self._tick = 0

    def read_frame(self) -> Optional[np.ndarray]:
        self._tick += 1
        frame = np.full((self._height, self._width, 3), 18, dtype=np.uint8)

        # Simple animated bar so operators can see stream freshness.
        bar_w = max(80, self._width // 8)
        x = (self._tick * 8) % max(1, self._width - bar_w)
        cv2.rectangle(frame, (x, self._height - 36), (x + bar_w, self._height - 12), (0, 100, 220), -1)

        cv2.putText(
            frame,
            "Local camera unavailable",
            (32, 64),
            cv2.FONT_HERSHEY_SIMPLEX,
            1.0,
            (230, 230, 230),
            2,
            cv2.LINE_AA,
        )
        cv2.putText(
            frame,
            "Allow camera permission or set --webcam-index to a valid device.",
            (32, 104),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.72,
            (200, 200, 200),
            2,
            cv2.LINE_AA,
        )
        return frame

    def close(self) -> None:
        return


class UnitreeGo2CameraClient:
    """Read JPEG-encoded Go2 camera samples through Unitree SDK and decode to BGR."""

    def __init__(self, timeout_s: float = 0.5) -> None:
        video_cls = _import_attr(
            (
                "unitree_sdk2py.go2.video.video_client",
                "unitree_sdk2py.go2.video_client",
            ),
            "VideoClient",
        )
        self._client = video_cls()
        self._best_effort_call(("SetTimeout",), timeout_s)
        self._best_effort_call(("Init",))

    def read_frame(self) -> Optional[np.ndarray]:
        result = self._fetch_frame_payload()
        if result is None:
            return None
        return self._decode_frame(result)

    def close(self) -> None:
        return

    def _fetch_frame_payload(self) -> Any:
        for method_name in ("GetImageSample", "GetImage", "GetFrame"):
            method = getattr(self._client, method_name, None)
            if method is None:
                continue
            try:
                raw = method()
            except TypeError:
                # Some SDK variants accept stream index/channel id.
                try:
                    raw = method(0)
                except Exception:
                    continue
            except Exception:
                continue
            payload = self._unwrap_payload(raw)
            if payload is not None:
                return payload
        return None

    def _unwrap_payload(self, raw: Any) -> Any:
        if raw is None:
            return None
        if isinstance(raw, tuple):
            if len(raw) >= 2:
                code, payload = raw[0], raw[1]
                if isinstance(code, (int, float, bool)) and code not in (0, True):
                    return None
                return payload
            if len(raw) == 1:
                return raw[0]
            return None
        if isinstance(raw, dict):
            for key in ("data", "image", "frame", "jpg", "jpeg"):
                if key in raw:
                    return raw[key]
            return None
        return raw

    def _decode_frame(self, payload: Any) -> Optional[np.ndarray]:
        if payload is None:
            return None

        if isinstance(payload, np.ndarray):
            if payload.ndim == 3:
                return payload
            if payload.ndim == 2:
                return cv2.cvtColor(payload, cv2.COLOR_GRAY2BGR)
            return None

        if isinstance(payload, memoryview):
            payload = payload.tobytes()
        elif isinstance(payload, (list, tuple)):
            try:
                payload = bytes(payload)
            except Exception:
                return None

        if not isinstance(payload, (bytes, bytearray)):
            return None

        encoded = np.frombuffer(payload, dtype=np.uint8)
        if encoded.size == 0:
            return None
        frame = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
        return frame

    def _best_effort_call(self, method_names: Iterable[str], *args: Any, **kwargs: Any) -> bool:
        for name in method_names:
            method = getattr(self._client, name, None)
            if method is None:
                continue
            try:
                method(*args, **kwargs)
                return True
            except TypeError:
                try:
                    method(*args)
                    return True
                except Exception:
                    continue
            except Exception:
                continue
        return False


def _iter_camera_open_attempts(camera_index: int) -> Iterable[tuple[int, int]]:
    system = platform.system().lower()
    cap_any = getattr(cv2, "CAP_ANY", 0)
    cap_avfoundation = getattr(cv2, "CAP_AVFOUNDATION", cap_any)
    cap_v4l2 = getattr(cv2, "CAP_V4L2", cap_any)
    cap_gstreamer = getattr(cv2, "CAP_GSTREAMER", cap_any)

    if system == "darwin":
        backend_order = [cap_avfoundation, cap_any]
    elif system == "linux":
        backend_order = [cap_v4l2, cap_gstreamer, cap_any]
    else:
        backend_order = [cap_any]

    if system == "darwin":
        candidate_indices = _preferred_mac_camera_indices(camera_index)
    else:
        candidate_indices = [camera_index]
        if camera_index == 0:
            # Common case: default index is wrong on some Linux setups.
            candidate_indices.extend([1, 2])

    seen: set[tuple[int, int]] = set()
    for idx in candidate_indices:
        for backend in backend_order:
            key = (idx, backend)
            if key in seen:
                continue
            seen.add(key)
            yield key


def _open_camera_capture(camera_index: int, backend: int) -> Optional[cv2.VideoCapture]:
    cap_any = getattr(cv2, "CAP_ANY", 0)
    cap: cv2.VideoCapture
    if backend == cap_any:
        cap = cv2.VideoCapture(camera_index)
    else:
        cap = cv2.VideoCapture(camera_index, backend)

    if not cap.isOpened():
        cap.release()
        return None

    # Reduce buffering latency when backend supports it.
    try:
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    except Exception:
        pass

    # Validate by trying to read a few startup frames.
    for _ in range(5):
        ok, frame = cap.read()
        if ok and frame is not None and frame.size > 0:
            return cap
        time.sleep(0.04)

    cap.release()
    return None


def _camera_backend_name(backend: int) -> str:
    cap_any = getattr(cv2, "CAP_ANY", 0)
    cap_avfoundation = getattr(cv2, "CAP_AVFOUNDATION", cap_any)
    cap_v4l2 = getattr(cv2, "CAP_V4L2", cap_any)
    cap_gstreamer = getattr(cv2, "CAP_GSTREAMER", cap_any)

    if backend == cap_any:
        return "CAP_ANY"
    if backend == cap_avfoundation:
        return "CAP_AVFOUNDATION"
    if backend == cap_v4l2:
        return "CAP_V4L2"
    if backend == cap_gstreamer:
        return "CAP_GSTREAMER"
    return str(int(backend))


def _preferred_mac_camera_indices(camera_index: int) -> list[int]:
    if camera_index != 0:
        return [camera_index]

    from_ffmpeg = _mac_avfoundation_video_devices()
    if from_ffmpeg:
        non_iphone = [idx for idx, name in from_ffmpeg if not _is_iphone_camera_name(name)]
        iphone = [idx for idx, name in from_ffmpeg if _is_iphone_camera_name(name)]
        ordered = non_iphone + iphone
        if ordered:
            return ordered

    # Heuristic fallback: on many Macs with Continuity Camera, index 1 is built-in webcam.
    return [1, 0, 2, 3]


def _mac_avfoundation_video_devices() -> list[tuple[int, str]]:
    try:
        proc = subprocess.run(
            ["ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return []
    except Exception:
        return []

    text = (proc.stderr or "") + "\n" + (proc.stdout or "")
    video_devices: list[tuple[int, str]] = []
    in_video_section = False
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if "AVFoundation video devices" in line:
            in_video_section = True
            continue
        if "AVFoundation audio devices" in line:
            in_video_section = False
        if not in_video_section:
            continue

        # Example: [AVFoundation input device @ ...] [0] FaceTime HD Camera
        match = re.search(r"\[(\d+)\]\s+(.+)$", line)
        if not match:
            continue
        idx = int(match.group(1))
        name = match.group(2).strip()
        video_devices.append((idx, name))

    return video_devices


def _is_iphone_camera_name(name: str) -> bool:
    lowered = name.lower()
    return "iphone" in lowered or "continuity" in lowered
