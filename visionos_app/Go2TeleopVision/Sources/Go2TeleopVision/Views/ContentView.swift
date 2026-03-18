import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: TeleopViewModel
    @State private var showConnectionSettings = false

    var body: some View {
        Group {
            if viewModel.isRunning {
                runtimeView
            } else {
                lobbyView
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isRunning)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lobbyView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 4) {
                Text("Go2Teleop")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundColor(.white)
                Text("Tracking Streamer")
                    .font(.largeTitle)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.top, 24)

            HStack(spacing: 10) {
                VStack(spacing: 4) {
                    Image(systemName: "video.fill")
                        .font(.title)
                        .foregroundColor(Color(hex: "#9F1239"))
                    Text("Video Feed")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Text("Go2 Camera")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(width: 120)

                AnimatedArrows(color: Color(hex: "#9F1239"))

                Button {
                    Task { await viewModel.start() }
                } label: {
                    if viewModel.isStarting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .frame(height: 84)
                            .frame(minWidth: 240)
                            .background(
                                LinearGradient(
                                    colors: [Color(hex: "#9F1239"), Color(hex: "#A855F7"), Color(hex: "#6366F1")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                    } else {
                        Text("START")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.vertical, 20)
                            .padding(.horizontal, 60)
                            .background(
                                LinearGradient(
                                    colors: [Color(hex: "#9F1239"), Color(hex: "#A855F7"), Color(hex: "#6366F1")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isStarting)

                AnimatedArrows(color: Color(hex: "#6366F1"))

                VStack(spacing: 4) {
                    Image(systemName: "hand.raised.fill")
                        .font(.title)
                        .foregroundColor(Color(hex: "#6366F1"))
                    Text("Hand / Head")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Text("Tracking")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(width: 100)
            }
            .padding(.top, 8)

            connectionInfoCard

            endpointSettingsCard

            if let error = viewModel.errorText {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
        }
        .padding(28)
        .frame(minWidth: 760, minHeight: 620)
    }

    private var connectionInfoCard: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "wifi")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("Local Network")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.7))
                    InfoTooltipButton(
                        title: "Local Mode",
                        message: "Use this when Vision Pro and the Go2 backend are on the same network."
                    )
                }

                IPAddressCard(addresses: viewModel.localIPAddresses)

                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.backendReachable ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                        .shadow(
                            color: (viewModel.backendReachable ? Color.green : Color.orange).opacity(0.6),
                            radius: 4
                        )
                    Text(viewModel.backendReachable ? "Backend Reachable" : "Waiting for Backend")
                        .font(.caption.weight(.medium))
                        .foregroundColor(viewModel.backendReachable ? .green : .orange)
                }
            }
            .frame(minWidth: 220)

            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 100)

            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundColor(.cyan)
                    Text("Session Code")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.7))
                    InfoTooltipButton(
                        title: "Session Code",
                        message: "Simple pairing code kept in the app for manual coordination."
                    )
                }

                Text(viewModel.roomCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .tracking(2)

                HStack(spacing: 8) {
                    Button {
                        viewModel.generateRoomCode()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                            Text("New Code")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.isRoomCodeLocked.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: viewModel.isRoomCodeLocked ? "lock.fill" : "lock.open")
                                .font(.caption)
                            Text(viewModel.isRoomCodeLocked ? "Locked" : "Lock")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundColor(viewModel.isRoomCodeLocked ? .yellow : .white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(viewModel.isRoomCodeLocked ? Color.yellow.opacity(0.15) : Color.white.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 220)
        }
    }

    private var endpointSettingsCard: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showConnectionSettings.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: showConnectionSettings ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                    Text("Connection Settings")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .foregroundColor(.white.opacity(0.8))
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if showConnectionSettings {
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WebSocket (hand data)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("ws://robot-host:8765/ws", text: $viewModel.websocketURLString)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isStarting)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Camera snapshot URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("http://robot-host:8080/snapshot.jpg", text: $viewModel.snapshotURLString)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isStarting)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hand send rate: \(Int(viewModel.handSendRateHz)) Hz")
                                .font(.caption)
                            Slider(value: $viewModel.handSendRateHz, in: 10...90, step: 1)
                                .disabled(viewModel.isStarting)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Snapshot rate: \(Int(viewModel.snapshotRateHz)) Hz")
                                .font(.caption)
                            Slider(value: $viewModel.snapshotRateHz, in: 2...30, step: 1)
                                .disabled(viewModel.isStarting)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var runtimeView: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Go2 Teleoperation")
                        .font(.title2.bold())
                    Text("Hand tracking + camera streaming")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop Session") {
                    viewModel.stop()
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 18) {
                cameraPanel
                statusPanel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var cameraPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.88))

            if let image = viewModel.cameraImage {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Waiting for camera snapshots...")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow("Connection", viewModel.statusText)
            statusRow("Backend", viewModel.backendReachable ? "Reachable" : "Not reachable")
            statusRow("ARKit", viewModel.handTrackingService.stateText)
            statusRow("Packets sent", "\(viewModel.packetCount)")
            Divider()
            statusRow("Tracked", viewModel.latestSample.isTracked ? "YES" : "NO")
            statusRow("Pinch", viewModel.latestSample.pinchActive ? "ACTIVE" : "OPEN")
            statusRow("Pinch distance", String(format: "%.4f m", viewModel.latestSample.pinchDistance))
            statusRow(
                "Wrist XYZ",
                String(
                    format: "(%.3f, %.3f, %.3f)",
                    viewModel.latestSample.rightWristPosition.x,
                    viewModel.latestSample.rightWristPosition.y,
                    viewModel.latestSample.rightWristPosition.z
                )
            )
            statusRow("Wrist roll", String(format: "%.3f rad", viewModel.latestSample.rightWristRoll))

            if let error = viewModel.errorText {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .frame(width: 350)
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statusRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct IPAddressCard: View {
    let addresses: [(name: String, address: String)]

    var body: some View {
        VStack(spacing: 8) {
            if addresses.isEmpty {
                Text("No network connection")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.6))
            } else {
                ForEach(addresses, id: \.address) { ip in
                    HStack(spacing: 10) {
                        Text(ip.name)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 55)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(6)
                        Text(ip.address)
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
            }
        }
    }
}

private struct InfoTooltipButton: View {
    let title: String
    let message: String
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(nil)
            }
            .padding(16)
            .frame(width: 300)
        }
    }
}

private struct AnimatedArrows: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let dotCount = 8
                let dotSpacing: CGFloat = 8
                let totalWidth = CGFloat(dotCount) * dotSpacing
                let startX = (size.width - totalWidth) / 2
                let centerY = size.height / 2
                let phase = (time.truncatingRemainder(dividingBy: 0.8)) / 0.8

                for i in 0..<dotCount {
                    let baseX = startX + CGFloat(i) * dotSpacing
                    let normalizedPos = Double(i) / Double(dotCount - 1)
                    var diff = normalizedPos - phase
                    if diff < 0 { diff += 1.0 }
                    let opacity = diff < 0.4 ? (1.0 - diff / 0.4) * 0.85 + 0.15 : 0.15

                    let dotSize: CGFloat = 4
                    let rect = CGRect(x: baseX - dotSize / 2, y: centerY - dotSize / 2, width: dotSize, height: dotSize)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
                }
            }
        }
        .frame(width: 70, height: 24)
    }
}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
