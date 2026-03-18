from __future__ import annotations

import importlib
import logging
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
        self._cap = cv2.VideoCapture(camera_index)
        if not self._cap.isOpened():
            raise RuntimeError(f"Failed to open webcam index {camera_index}.")

    def read_frame(self) -> Optional[np.ndarray]:
        ok, frame = self._cap.read()
        if not ok:
            return None
        return frame

    def close(self) -> None:
        if self._cap is not None:
            self._cap.release()


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
