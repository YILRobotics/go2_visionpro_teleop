from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import socket
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Optional

import cv2
import numpy as np


LOGGER = logging.getLogger(__name__)


class SwiftBridgeUnavailable(RuntimeError):
    pass


class SwiftBridgeServer:
    """Bridge for the custom Swift visionOS app.

    - Receives hand tracking packets over WebSocket.
    - Exposes latest camera frame as JPEG snapshot on HTTP.
    """

    def __init__(self, bind_host: str, ws_port: int, http_port: int) -> None:
        self.bind_host = bind_host
        self.ws_port = ws_port
        self.http_port = http_port

        self._latest_tracking_lock = threading.Lock()
        self._latest_tracking: Optional[dict[str, Any]] = None
        self._latest_tracking_ts = 0.0

        self._latest_jpeg_lock = threading.Lock()
        self._latest_jpeg: Optional[bytes] = None

        self._http_server: Optional[ThreadingHTTPServer] = None
        self._http_thread: Optional[threading.Thread] = None

        self._ws_loop: Optional[asyncio.AbstractEventLoop] = None
        self._ws_server = None
        self._ws_thread: Optional[threading.Thread] = None
        self._ws_ready = threading.Event()
        self._ws_start_error: Optional[Exception] = None
        self._received_first_tracking = False

    def start(self) -> None:
        self._start_http_server()
        self._start_ws_server()
        LOGGER.info(
            "Swift bridge bound: ws://%s:%d/ws, http://%s:%d/snapshot.jpg",
            self.bind_host,
            self.ws_port,
            self.bind_host,
            self.http_port,
        )
        if _is_wildcard_host(self.bind_host):
            lan_ips = _local_ipv4_addresses()
            if lan_ips:
                primary = lan_ips[0]
                LOGGER.info(
                    "Connect Vision Pro to your Mac LAN IP (not 0.0.0.0). Example: ws://%s:%d/ws and http://%s:%d/snapshot.jpg",
                    primary,
                    self.ws_port,
                    primary,
                    self.http_port,
                )
                if len(lan_ips) > 1:
                    LOGGER.info("Detected Mac LAN IPv4 addresses: %s", ", ".join(lan_ips))
            else:
                LOGGER.info(
                    "Connect Vision Pro using this Mac's LAN IP: ws://<mac-ip>:%d/ws and http://<mac-ip>:%d/snapshot.jpg",
                    self.ws_port,
                    self.http_port,
                )

    def stop(self) -> None:
        if self._http_server is not None:
            try:
                self._http_server.shutdown()
                self._http_server.server_close()
            except Exception:
                pass
            self._http_server = None
        if self._http_thread is not None and self._http_thread.is_alive():
            self._http_thread.join(timeout=1.0)
            self._http_thread = None

        if self._ws_loop is not None:
            loop = self._ws_loop
            try:
                loop.call_soon_threadsafe(loop.stop)
            except Exception:
                pass
        if self._ws_thread is not None and self._ws_thread.is_alive():
            self._ws_thread.join(timeout=1.0)
            self._ws_thread = None
        self._ws_loop = None

    def update_camera(self, frame_bgr: np.ndarray) -> None:
        ok, encoded = cv2.imencode(".jpg", frame_bgr, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
        if not ok:
            return
        with self._latest_jpeg_lock:
            self._latest_jpeg = encoded.tobytes()

    def get_latest_tracking(self, max_age_s: float) -> Optional[dict[str, Any]]:
        with self._latest_tracking_lock:
            if self._latest_tracking is None:
                return None
            if (time.monotonic() - self._latest_tracking_ts) > max_age_s:
                return None
            return dict(self._latest_tracking)

    def _start_http_server(self) -> None:
        bridge = self

        class SnapshotHandler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                if self.path != "/snapshot.jpg":
                    self.send_response(HTTPStatus.NOT_FOUND)
                    self.end_headers()
                    return

                with bridge._latest_jpeg_lock:
                    jpeg = bridge._latest_jpeg

                if jpeg is None:
                    self.send_response(HTTPStatus.SERVICE_UNAVAILABLE)
                    self.end_headers()
                    return

                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(jpeg)))
                self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
                self.end_headers()
                self.wfile.write(jpeg)

            def log_message(self, format: str, *args: Any) -> None:
                return

        self._http_server = ThreadingHTTPServer((self.bind_host, self.http_port), SnapshotHandler)
        self._http_thread = threading.Thread(
            target=self._http_server.serve_forever,
            name="swift-http-server",
            daemon=True,
        )
        self._http_thread.start()

    def _start_ws_server(self) -> None:
        try:
            import websockets
        except ModuleNotFoundError as exc:
            raise SwiftBridgeUnavailable(
                "Missing dependency `websockets`. Run `python3 -m pip install -e .` from the repo root."
            ) from exc
        self._ws_ready.clear()
        self._ws_start_error = None

        def runner() -> None:
            loop = asyncio.new_event_loop()
            self._ws_loop = loop
            asyncio.set_event_loop(loop)

            async def handler(websocket, path: Optional[str] = None) -> None:
                peer = getattr(websocket, "remote_address", None)
                request = getattr(websocket, "request", None)
                request_path = getattr(request, "path", None)
                path = path or getattr(websocket, "path", None) or request_path or "/ws"
                if path != "/ws":
                    try:
                        await websocket.close(code=1008, reason="Use /ws endpoint")
                    except Exception:
                        pass
                    return
                LOGGER.info("Swift app websocket connected from %s.", peer)
                async for message in websocket:
                    await self._on_ws_message(message, websocket)
                LOGGER.info("Swift app websocket disconnected from %s.", peer)

            try:
                async def create_server():
                    return await websockets.serve(handler, self.bind_host, self.ws_port)

                self._ws_server = loop.run_until_complete(create_server())
                self._ws_ready.set()
            except Exception as exc:
                self._ws_start_error = exc
                self._ws_ready.set()
                loop.close()
                return
            try:
                loop.run_forever()
            finally:
                if self._ws_server is not None:
                    self._ws_server.close()
                    loop.run_until_complete(self._ws_server.wait_closed())
                loop.close()

        self._ws_thread = threading.Thread(target=runner, name="swift-ws-server", daemon=True)
        self._ws_thread.start()
        if not self._ws_ready.wait(timeout=3.0):
            raise SwiftBridgeUnavailable("Timed out while starting Swift bridge websocket server.")
        if self._ws_start_error is not None:
            raise SwiftBridgeUnavailable(
                f"Failed to start Swift bridge websocket server: {self._ws_start_error}"
            ) from self._ws_start_error

    async def _on_ws_message(self, message: Any, websocket: Any) -> None:
        if isinstance(message, bytes):
            try:
                message = message.decode("utf-8")
            except UnicodeDecodeError:
                return
        if not isinstance(message, str):
            return

        try:
            payload = json.loads(message)
        except json.JSONDecodeError:
            return

        if payload.get("type") != "hand_tracking":
            return

        tracking = _packet_to_tracking(payload)
        if tracking is None:
            return

        with self._latest_tracking_lock:
            self._latest_tracking = tracking
            self._latest_tracking_ts = time.monotonic()
        if not self._received_first_tracking:
            self._received_first_tracking = True
            LOGGER.info("Received first tracking packet from Swift app.")

        try:
            await websocket.send('{"type":"ack"}')
        except Exception:
            pass


def _packet_to_tracking(payload: dict[str, Any]) -> Optional[dict[str, Any]]:
    wrist = payload.get("rightWrist")
    if not isinstance(wrist, dict):
        return None
    try:
        x = float(wrist["x"])
        y = float(wrist["y"])
        z = float(wrist["z"])
        roll = float(payload.get("rightWristRoll", 0.0))
        pinch_distance = float(payload.get("rightPinchDistance", 1.0))
    except (KeyError, TypeError, ValueError):
        return None

    right_wrist = np.eye(4, dtype=np.float64)
    right_wrist[:3, 3] = [x, y, z]

    return {
        "right_wrist": right_wrist,
        "right_pinch_distance": pinch_distance,
        "right_wrist_roll": roll,
    }


def _is_wildcard_host(host: str) -> bool:
    return host in {"0.0.0.0", "::", ""}


def _local_ipv4_addresses() -> list[str]:
    addresses: set[str] = set()

    # Prefer the outbound interface address, which is usually the active LAN interface.
    sock: Optional[socket.socket] = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        outbound_ip = sock.getsockname()[0]
        if outbound_ip and not outbound_ip.startswith("127."):
            addresses.add(outbound_ip)
    except Exception:
        pass
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass

    # Add host-resolved IPv4 addresses as fallbacks.
    try:
        for family, _, _, _, sockaddr in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            if family != socket.AF_INET:
                continue
            ip = sockaddr[0]
            if ip and not ip.startswith("127."):
                addresses.add(ip)
    except Exception:
        pass

    return sorted(addresses, key=_ipv4_sort_key)


def _ipv4_sort_key(ip: str) -> tuple[int, int]:
    try:
        addr = ipaddress.IPv4Address(ip)
    except Exception:
        return (3, 0)
    if addr.is_link_local:
        priority = 2
    elif addr.is_private:
        priority = 0
    else:
        priority = 1
    return (priority, int(addr))
