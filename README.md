# Go2 Teleop (Vision Pro)

This repository now uses an integrated Go2-focused stack:

- receive Vision Pro hand tracking
- stream camera video back to Vision Pro
- convert hand motion into robot commands

Current scope:

- hand tracking
- camera image streaming
- Go2 velocity command mapping
- local red-block simulation mode

## Vision Pro App

Primary app:

- [Go2TeleopVision](/Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision)

It keeps the same START/connection-screen style from the original app, but is trimmed to Go2 teleoperation only.
Unneeded cloud/calibration onboarding was removed from the new flow.

## What It Does

- Uses `VisionProStreamer` from `avp_stream` for AVP mode (optional dependency).
- Uses Unitree SDK clients for:
  - Go2 camera frames
  - Go2 movement commands (base velocity)
- Uses right-hand pinch as a dead-man switch:
  - pinch active: wrist delta drives `vx`/`vy`
  - wrist roll drives `vyaw`
  - pinch released: stop

## Project Layout

```text
go2_teleop/
├── go2_teleop/
│   ├── app.py
│   ├── config.py
│   ├── hand_mapping.py
│   ├── renderer.py
│   ├── simulator.py
│   ├── swift_bridge.py
│   ├── unitree_bridge.py
│   └── main.py
├── visionos_app/
│   ├── Go2TeleopVision/               # Integrated Go2 app (primary)
│   └── README.md
└── pyproject.toml
```

## Build The Vision Pro App (Xcode)

You now have both options:

- Open the Xcode project directly:
  [Go2TeleopVision.xcodeproj](/Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision/Go2TeleopVision.xcodeproj)
- Or open the Swift package entry:
  [Package.swift](/Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision/Package.swift)

1. Open the Xcode project:

```bash
open /Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision/Go2TeleopVision.xcodeproj
```

Alternative (package entry):

```bash
open /Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision/Package.swift
```

2. In Xcode, select scheme **Go2TeleopVision**.
3. Go to **Signing & Capabilities**:
- set your Apple Team
- set a unique Bundle Identifier
4. Select your Vision Pro device (or visionOS simulator).
5. Press **Run**.

If you edit `project.yml`, regenerate the project with:

```bash
cd /Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision
xcodegen generate
```

## Make / Install App Build

1. In Xcode (Go2TeleopVision), choose **Product > Archive**.
2. In Organizer, choose **Distribute App**.
3. Use **Development** or **Ad Hoc** flow and install to your device.

For local testing, regular **Run** is usually enough.

## Quick Start

1. Install dependencies:

```bash
cd /Users/ferdinand/unitree/go2_visionpro_teleop
python3 -m pip install -e .
```

For AVP input mode (Tracking Streamer compatible), install optional extras:

```bash
python3 -m pip install -e ".[avp]"
```

2. Run teleop:

```bash
python -m go2_teleop.main \
  --input-source swift \
  --swift-bind-host 0.0.0.0 \
  --swift-ws-port 8765 \
  --swift-http-port 8080 \
  --no-motion
```

Then in `Go2TeleopVision`:

- set WebSocket to `ws://<robot-host>:8765/ws`
- set Snapshot to `http://<robot-host>:8080/snapshot.jpg`
- press `START`

## Simple Simulation Mode (Red Block)

This mode does not command a robot. It:

- reads hand tracking
- moves a red block in a local desktop window
- still streams webcam video to Vision Pro

Run it with the Swift app input:

```bash
python3 -m go2_teleop.main --input-source swift --simulation-mode block --webcam-index 1
```

Press `q` in the simulation window to close the local viewer.

Camera behavior:

- default `--webcam-index 0` on macOS uses auto-selection and prefers built-in webcam over iPhone/Continuity camera
- set explicit `--webcam-index N` to force a specific camera
- set `--webcam-index -1` only if you explicitly want synthetic placeholder feed

macOS permission fix:

```bash
tccutil reset Camera
```

Then allow camera access for your terminal app in System Settings.

Ubuntu camera hint:

- if `/dev/video0` is not your camera, run with `--webcam-index 1` (or `2`, etc.)
- if you do not want any local webcam at all (for example to avoid Continuity Camera on macOS), use `--webcam-index -1`

## Useful Flags

- `--hand-tracking-backend grpc|webrtc`
- `--input-source swift` (recommended app in this repo)
- `--input-source avp` (for compatible external Vision Pro streamers)
- `--simulation-mode off|block`
- `--simulation-canvas-px 700`
- `--stream-size 1280x720`
- `--stream-fps 30`
- `--control-hz 30`
- `--camera-hz 25`
- `--start-stand` (send stand-up command if supported by your SDK variant)
- `--no-motion` (camera + tracking only, no robot movement)
- `--dry-run --webcam-index 0` (local test mode without Go2)
- `--swift-bind-host 0.0.0.0 --swift-ws-port 8765 --swift-http-port 8080`

## Safety

- Start with `--no-motion` and verify hand tracking + camera stream first.
- Keep `pinch` released while validating coordinate directions.
- Tune gains and max velocity before real operation in tight spaces.
