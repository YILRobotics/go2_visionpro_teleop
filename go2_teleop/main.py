from __future__ import annotations

import logging

from .config import AppConfig


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )

    try:
        config = AppConfig.from_cli()
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
    try:
        from .app import Go2TeleopApp
    except ModuleNotFoundError as exc:
        missing = exc.name or "unknown module"
        raise SystemExit(
            f"Missing dependency '{missing}'. Run `pip install -e .` in go2_teleop first."
        ) from exc

    app = Go2TeleopApp(config)
    app.run()


if __name__ == "__main__":
    main()
