# visionos_app

Primary app (integrated Go2 version):

- `Go2TeleopVision/`

Open in Xcode (project file):

```bash
open /Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision/Go2TeleopVision.xcodeproj
```

Then:

1. Select scheme `Go2TeleopVision`
2. Set your Team + unique Bundle Identifier in Signing
3. Run on Vision Pro

Alternative: you can also open `Package.swift`.

Project regeneration (if needed):

```bash
cd /Users/ferdinand/unitree/go2_visionpro_teleop/visionos_app/Go2TeleopVision
xcodegen generate
```
