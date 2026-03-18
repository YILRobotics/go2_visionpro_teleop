# Go2TeleopVision (Swift visionOS app)

This is the integrated Vision Pro app for `go2_teleop`.
It keeps the same START/connection-screen style as the original app, but removes cloud and calibration-only flows not needed for Go2 hand-teleop.

It includes:

- `HandTrackingService`: ARKit hand tracking (right wrist + pinch distance)
- `TeleopSocketClient`: websocket sender for hand packets
- `ContentView`: START lobby + runtime camera/status panels
- `TeleopViewModel`: runtime loop, endpoint monitoring, room-code/session utilities

## Open in Xcode

This app now includes an Xcode project:

- `/Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision/Go2TeleopVision.xcodeproj`

1. Open project in Xcode:

```bash
open /Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision/Go2TeleopVision.xcodeproj
```

2. In Xcode, choose a visionOS target device and run.

Alternative: you can still open `Package.swift`.

## Regenerate Project

`Go2TeleopVision.xcodeproj` is generated from `project.yml`.
If you change target settings there, regenerate with:

```bash
cd /Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision
xcodegen generate
```

## Runtime Endpoints

- WebSocket input for hand packets: `ws://<robot-host>:8765/ws`
- Camera snapshot endpoint: `http://<robot-host>:8080/snapshot.jpg`

The lobby lets you edit these before pressing `START`.

## Backend Command

Run Python backend in Swift-input mode:

```bash
cd /Users/ferdinand/unitree/go2_visionpro_teleop
python -m go2_teleop.main --input-source swift --swift-bind-host 0.0.0.0 --swift-ws-port 8765 --swift-http-port 8080
```

For local red-block simulation instead of robot motion:

```bash
python -m go2_teleop.main --input-source swift --simulation-mode block
```

## Hand Packet Format

Outgoing JSON packet:

```json
{
  "type": "hand_tracking",
  "timestamp": 1742400000.123,
  "rightWrist": { "x": 0.01, "y": 1.24, "z": -0.31 },
  "rightWristRoll": 0.21,
  "rightPinchDistance": 0.018,
  "rightPinchActive": true
}
```
