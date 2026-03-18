from __future__ import annotations

import threading
from typing import Optional

import cv2
import numpy as np

from .hand_mapping import Go2Command


class VisionOverlayRenderer:
    """Render the outgoing Vision Pro frame using Go2 camera + compact status overlay."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._camera_frame: Optional[np.ndarray] = None
        self._command = Go2Command(enabled=False)

    def update_camera(self, frame: np.ndarray) -> None:
        with self._lock:
            self._camera_frame = frame.copy()

    def update_command(self, command: Go2Command) -> None:
        with self._lock:
            self._command = command

    def render(self, blank_frame: np.ndarray) -> np.ndarray:
        h, w = blank_frame.shape[:2]
        with self._lock:
            camera = None if self._camera_frame is None else self._camera_frame.copy()
            command = self._command

        if camera is None:
            blank_frame[:] = (15, 15, 15)
            cv2.putText(
                blank_frame,
                "Waiting for Go2 camera...",
                (32, h // 2),
                cv2.FONT_HERSHEY_SIMPLEX,
                1.0,
                (220, 220, 220),
                2,
                cv2.LINE_AA,
            )
        else:
            blank_frame[:] = cv2.resize(camera, (w, h), interpolation=cv2.INTER_LINEAR)

        overlay = blank_frame.copy()
        panel_w = min(460, w - 32)
        panel_h = min(220, h - 32)
        cv2.rectangle(overlay, (16, 16), (16 + panel_w, 16 + panel_h), (0, 0, 0), -1)
        cv2.addWeighted(overlay, 0.45, blank_frame, 0.55, 0.0, blank_frame)

        lines = [
            "GO2 Teleop",
            f"Tracking: {'OK' if command.tracking_ok else 'NO DATA'}",
            f"Pinch Drive: {'ACTIVE' if command.pinch_active else 'OPEN'}",
            f"vx:   {command.vx:+.3f} m/s",
            f"vy:   {command.vy:+.3f} m/s",
            f"vyaw: {command.vyaw:+.3f} rad/s",
            "Release pinch to stop",
        ]

        y = 44
        for i, line in enumerate(lines):
            scale = 0.8 if i == 0 else 0.62
            thickness = 2 if i == 0 else 1
            cv2.putText(
                blank_frame,
                line,
                (28, y),
                cv2.FONT_HERSHEY_SIMPLEX,
                scale,
                (245, 245, 245),
                thickness,
                cv2.LINE_AA,
            )
            y += 30 if i == 0 else 25

        return blank_frame
