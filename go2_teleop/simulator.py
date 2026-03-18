from __future__ import annotations

import math
import threading
import time
from dataclasses import dataclass

import cv2
import numpy as np

from .hand_mapping import Go2Command


@dataclass(slots=True)
class SimulationState:
    x: float = 0.0
    y: float = 0.0
    yaw: float = 0.0


class RedBlockSimulator:
    """Simple local 2D simulator controlled by teleop velocity commands."""

    def __init__(self, canvas_px: int = 700) -> None:
        self.canvas_px = canvas_px
        self.window_name = "Go2 Teleop Simulation"

        self._state = SimulationState()
        self._cmd = Go2Command(enabled=False)
        self._lock = threading.Lock()
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._gui_available = True

        # 1 meter equals this many pixels in the local plot.
        self._scale_px_per_meter = float(canvas_px) * 0.35

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, name="red-block-sim", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread is not None and self._thread.is_alive():
            self._thread.join(timeout=1.0)
        self._thread = None
        if self._gui_available:
            try:
                cv2.destroyWindow(self.window_name)
            except Exception:
                pass

    def update_command(self, cmd: Go2Command) -> None:
        with self._lock:
            self._cmd = cmd

    def get_state(self) -> SimulationState:
        with self._lock:
            return SimulationState(self._state.x, self._state.y, self._state.yaw)

    def _run(self) -> None:
        dt_target = 1.0 / 60.0
        last_t = time.perf_counter()

        while not self._stop_event.is_set():
            now = time.perf_counter()
            dt = max(1e-4, min(0.05, now - last_t))
            last_t = now

            with self._lock:
                cmd = self._cmd
                state = self._state

                vx = cmd.vx if cmd.enabled else 0.0
                vy = cmd.vy if cmd.enabled else 0.0
                vyaw = cmd.vyaw if cmd.enabled else 0.0

                # Integrate body-frame command into world frame.
                c = math.cos(state.yaw)
                s = math.sin(state.yaw)
                world_vx = c * vx - s * vy
                world_vy = s * vx + c * vy

                state.x += world_vx * dt
                state.y += world_vy * dt
                state.yaw = _wrap_angle(state.yaw + vyaw * dt)

                # Keep object inside local map bounds for visibility.
                limit = 0.95
                state.x = float(np.clip(state.x, -limit, limit))
                state.y = float(np.clip(state.y, -limit, limit))

            frame = self._render_frame(cmd, state)
            if self._gui_available:
                try:
                    cv2.imshow(self.window_name, frame)
                    key = cv2.waitKey(1) & 0xFF
                    if key == ord("q"):
                        self._stop_event.set()
                        break
                except cv2.error:
                    self._gui_available = False
            elapsed = time.perf_counter() - now
            time.sleep(max(0.0, dt_target - elapsed))

    def _render_frame(self, cmd: Go2Command, state: SimulationState) -> np.ndarray:
        canvas = np.full((self.canvas_px, self.canvas_px, 3), 247, dtype=np.uint8)
        center = self.canvas_px // 2

        # Grid
        for i in range(9):
            t = int(i * (self.canvas_px - 1) / 8)
            color = (220, 220, 220)
            cv2.line(canvas, (0, t), (self.canvas_px - 1, t), color, 1, cv2.LINE_AA)
            cv2.line(canvas, (t, 0), (t, self.canvas_px - 1), color, 1, cv2.LINE_AA)

        # Axis
        cv2.line(canvas, (center, 0), (center, self.canvas_px - 1), (180, 180, 180), 2, cv2.LINE_AA)
        cv2.line(canvas, (0, center), (self.canvas_px - 1, center), (180, 180, 180), 2, cv2.LINE_AA)

        # Red block pose
        cx = center + int(state.x * self._scale_px_per_meter)
        cy = center - int(state.y * self._scale_px_per_meter)
        block_w = int(0.16 * self._scale_px_per_meter)
        block_h = int(0.11 * self._scale_px_per_meter)
        corners = np.array(
            [
                [-block_w / 2, -block_h / 2],
                [block_w / 2, -block_h / 2],
                [block_w / 2, block_h / 2],
                [-block_w / 2, block_h / 2],
            ],
            dtype=np.float32,
        )
        c = math.cos(state.yaw)
        s = math.sin(state.yaw)
        rot = np.array([[c, -s], [s, c]], dtype=np.float32)
        pts = (corners @ rot.T + np.array([cx, cy], dtype=np.float32)).astype(np.int32)
        cv2.fillConvexPoly(canvas, pts, (42, 42, 235))
        cv2.polylines(canvas, [pts], isClosed=True, color=(24, 24, 160), thickness=2, lineType=cv2.LINE_AA)

        # Heading line
        heading = np.array([math.cos(state.yaw), -math.sin(state.yaw)], dtype=np.float32)
        p2 = np.array([cx, cy], dtype=np.float32) + heading * (block_w * 0.8)
        cv2.line(canvas, (cx, cy), (int(p2[0]), int(p2[1])), (255, 255, 255), 2, cv2.LINE_AA)

        # Status overlay
        cv2.rectangle(canvas, (16, 16), (380, 162), (0, 0, 0), -1)
        cv2.addWeighted(canvas, 0.8, np.full_like(canvas, 255), 0.2, 0.0, canvas)
        lines = [
            "Simulation mode: red block",
            f"Pinch: {'ACTIVE' if cmd.pinch_active else 'OPEN'}",
            f"vx={cmd.vx:+.3f} vy={cmd.vy:+.3f} vyaw={cmd.vyaw:+.3f}",
            f"x={state.x:+.3f} y={state.y:+.3f} yaw={state.yaw:+.3f}",
            "Press q in window to close",
        ]
        y = 40
        for text in lines:
            cv2.putText(
                canvas,
                text,
                (24, y),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.55,
                (255, 255, 255),
                1,
                cv2.LINE_AA,
            )
            y += 24
        return canvas


def _wrap_angle(value: float) -> float:
    return float(np.arctan2(np.sin(value), np.cos(value)))
