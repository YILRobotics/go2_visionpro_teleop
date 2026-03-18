from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Optional, Tuple

import numpy as np


@dataclass(slots=True)
class Go2Command:
    enabled: bool
    vx: float = 0.0
    vy: float = 0.0
    vyaw: float = 0.0
    pinch_active: bool = False
    tracking_ok: bool = False


class HandToGo2Mapper:
    """Map Vision Pro right-hand tracking into Go2 base velocity commands."""

    def __init__(
        self,
        pinch_threshold: float,
        deadband_m: float,
        deadband_yaw: float,
        gain_forward: float,
        gain_lateral: float,
        gain_yaw: float,
        max_forward: float,
        max_lateral: float,
        max_yaw: float,
    ) -> None:
        self.pinch_threshold = pinch_threshold
        self.deadband_m = deadband_m
        self.deadband_yaw = deadband_yaw
        self.gain_forward = gain_forward
        self.gain_lateral = gain_lateral
        self.gain_yaw = gain_yaw
        self.max_forward = max_forward
        self.max_lateral = max_lateral
        self.max_yaw = max_yaw

        self._ref_pos: Optional[np.ndarray] = None
        self._ref_roll: Optional[float] = None

    def reset(self) -> None:
        self._ref_pos = None
        self._ref_roll = None

    def update(self, tracking: Any) -> Go2Command:
        hand_state = self._extract_right_hand_state(tracking)
        if hand_state is None:
            self.reset()
            return Go2Command(enabled=False, tracking_ok=False, pinch_active=False)

        wrist_pos, pinch_distance, wrist_roll = hand_state
        pinch_active = pinch_distance <= self.pinch_threshold

        if not pinch_active:
            self.reset()
            return Go2Command(enabled=False, tracking_ok=True, pinch_active=False)

        # Capture reference pose on pinch start for relative control.
        if self._ref_pos is None or self._ref_roll is None:
            self._ref_pos = wrist_pos.copy()
            self._ref_roll = wrist_roll

        delta = wrist_pos - self._ref_pos
        delta_roll = _wrap_angle(wrist_roll - self._ref_roll)

        vx = _clip(_apply_deadband(delta[0], self.deadband_m) * self.gain_forward, self.max_forward)
        vy = _clip(_apply_deadband(delta[1], self.deadband_m) * self.gain_lateral, self.max_lateral)
        vyaw = _clip(_apply_deadband(delta_roll, self.deadband_yaw) * self.gain_yaw, self.max_yaw)

        return Go2Command(
            enabled=True,
            vx=vx,
            vy=vy,
            vyaw=vyaw,
            pinch_active=True,
            tracking_ok=True,
        )

    def _extract_right_hand_state(self, tracking: Any) -> Optional[Tuple[np.ndarray, float, float]]:
        if tracking is None:
            return None

        try:
            wrist = np.asarray(tracking.right.wrist, dtype=np.float64)
            pinch_distance = float(tracking.right.pinch_distance)
            wrist_roll = float(tracking.right.wrist_roll)
        except Exception:
            # Backward-compatible path for dict-style tracking objects.
            if not isinstance(tracking, dict):
                return None
            wrist = np.asarray(tracking.get("right_wrist"), dtype=np.float64)
            if wrist.size == 0:
                return None
            pinch_distance = float(tracking.get("right_pinch_distance", 1.0))
            wrist_roll = float(tracking.get("right_wrist_roll", 0.0))

        if wrist.ndim == 3:
            wrist = wrist[0]
        if wrist.shape != (4, 4):
            return None

        wrist_pos = np.asarray(wrist[:3, 3], dtype=np.float64)
        if not np.all(np.isfinite(wrist_pos)):
            return None
        return wrist_pos, pinch_distance, wrist_roll


def _clip(value: float, max_abs: float) -> float:
    return float(np.clip(value, -max_abs, max_abs))


def _apply_deadband(value: float, deadband: float) -> float:
    if abs(value) <= deadband:
        return 0.0
    return float(np.sign(value) * (abs(value) - deadband))


def _wrap_angle(value: float) -> float:
    return float(np.arctan2(np.sin(value), np.cos(value)))
