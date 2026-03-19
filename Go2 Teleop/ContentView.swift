import SwiftUI
import Foundation

func dlog(_ msg: @autoclosure () -> String) {
    #if DEBUG
    print(msg())
    #endif
}

private func getIPAddresses() -> [(name: String, address: String)] {
    var addresses: [(name: String, address: String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
        return []
    }
    defer { freeifaddrs(ifaddr) }

    var ptr = firstAddr
    while true {
        let interface = ptr.pointee
        guard let addr = interface.ifa_addr else {
            guard let next = interface.ifa_next else { break }
            ptr = next
            continue
        }

        let family = addr.pointee.sa_family
        if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
            let rawName = String(cString: interface.ifa_name)
            if rawName != "lo0" && (interface.ifa_flags & UInt32(IFF_UP)) != 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )

                if result == 0 {
                    var address = String(cString: host)
                    if let zoneIndex = address.firstIndex(of: "%") {
                        address = String(address[..<zoneIndex])
                    }
                    if !address.hasPrefix("fe80:") {
                        let displayName: String
                        switch rawName {
                        case "en0":
                            displayName = "Wi-Fi"
                        case "en1":
                            displayName = "Ethernet"
                        case "pdp_ip0":
                            displayName = "Cellular"
                        default:
                            displayName = rawName
                        }
                        addresses.append((displayName, address))
                    }
                }
            }
        }

        guard let next = interface.ifa_next else { break }
        ptr = next
    }

    var seen = Set<String>()
    return addresses
        .filter { seen.insert($0.address).inserted }
        .sorted { $0.name < $1.name }
}

struct ContentView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var signalingClient = SignalingClient.shared

    @State private var serverReady = false
    @State private var dotCount = 0
    @State private var isStarting = false

    var body: some View {
        mainContentView
            .padding(24)
            .background(Color.black.opacity(0.3))
            .cornerRadius(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            signalingClient.connect()
            DataManager.shared.crossNetworkRoomCode = signalingClient.roomCode
        }
        .onReceive(Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }

    // MARK: - Main Content View
    private var mainContentView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 4) {
                Text("VisionProTeleop")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundColor(.white)
                Text("Tracking Streamer")
                    .font(.largeTitle)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.top, 32)

            // Animated data flow visualization + START button
            HStack(spacing: 10) {
                // Video/Audio/Sim label (left side)
                VStack(spacing: 4) {
                    Image(systemName: "video.fill")
                        .font(.title)
                        .foregroundColor(Color(hex: "#9F1239"))
                    Text("Video · Audio")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Text("MuJoCo · IsaacLab")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(width: 120)

                // Arrows flowing right (from video/audio/sim toward button)
                AnimatedArrows(color: Color(hex: "#9F1239"))

                // Simple START button
                Button {
                    handleStartButton()
                } label: {
                    Text(isStarting ? "STARTING..." : "START")
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
                .buttonStyle(.plain)
                .disabled(isStarting)

                // Arrows flowing right (from button toward hand tracking)
                AnimatedArrows(color: Color(hex: "#6366F1"))

                // Hand/Head tracking label (right side)
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
            .padding(.top, 16)

            // Connection Info - Side by side: Local Network | Remote
            HStack(alignment: .top, spacing: 32) {
                // LEFT: Local Network Section
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text("Local Network")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.7))

                        InfoTooltipButton(
                            title: "Local Network Mode",
                            message: "Use this when your Vision Pro and Python client are on the same network (e.g., same WiFi). Provides the lowest latency connection via direct gRPC."
                        )
                    }

                    IPAddressCard(addresses: getIPAddresses())

                    // Server status
                    HStack(spacing: 8) {
                        Circle()
                            .fill(serverReady ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                            .shadow(color: serverReady ? Color.green.opacity(0.6) : Color.orange.opacity(0.6), radius: 4)
                        Text(serverReady ? "gRPC Server Ready" : "Starting gRPC...")
                            .font(.caption.weight(.medium))
                            .foregroundColor(serverReady ? .green : .orange)
                    }
                }
                .frame(minWidth: 200)

                // Vertical Divider
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 100)

                // RIGHT: Remote Section
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.caption)
                            .foregroundColor(.cyan)
                        Text("Remote (Any Network)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.7))

                        InfoTooltipButton(
                            title: "Cross-Network Mode",
                            message: "Use this when your Vision Pro and Python client are on different networks, or when firewalls block direct connections. Uses STUN/TURN server relaying to establish connectivity."
                        )
                    }

                    Text(signalingClient.roomCode)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .tracking(2)

                    Text(signalingClient.isConnected ? "Connected" : "Connecting" + String(repeating: ".", count: dotCount))
                        .font(.caption.monospaced())
                        .foregroundColor(signalingClient.isConnected ? .green : .white.opacity(0.7))

                    // Button row: New Code and Lock/Unlock
                    HStack(spacing: 8) {
                        Button {
                            signalingClient.generateRoomCode()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                Text("New Code")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Button {
                            signalingClient.setRoomCodeLocked(!signalingClient.isRoomCodeLocked)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: signalingClient.isRoomCodeLocked ? "lock.fill" : "lock.open")
                                    .font(.caption)
                                Text(signalingClient.isRoomCodeLocked ? "Locked" : "Lock")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundColor(signalingClient.isRoomCodeLocked ? .yellow : .white.opacity(0.5))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(signalingClient.isRoomCodeLocked ? Color.yellow.opacity(0.15) : Color.white.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .help(signalingClient.isRoomCodeLocked ? "Room code persists across sessions. Tap to unlock." : "Tap to keep this code across sessions.")
                    }
                }
                .frame(minWidth: 200)
            }
            .onAppear {
                // Poll for server ready status (keep polling even if hidden, so state is ready when switching back)
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                    serverReady = DataManager.shared.grpcServerReady
                    if serverReady {
                        timer.invalidate()
                    }
                }
            }

            // Exit button
            HStack(spacing: 24) {
                Button {
                    exit(0)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 50, height: 50)
                        Text("✕")
                            .font(.title.bold())
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 520)
    }

    private func handleStartButton() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            await proceedToImmersiveSpace()
        }
    }

    private func proceedToImmersiveSpace() async {
        signalingClient.connect()
        DataManager.shared.crossNetworkRoomCode = signalingClient.roomCode
        await openImmersiveSpace(id: "combinedStreamSpace")
        dismissWindow()
    }
}

private struct AnimatedArrows: View {
    let color: Color
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { idx in
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundColor(color.opacity(opacity(for: idx)))
            }
        }
        .onReceive(Timer.publish(every: 0.18, on: .main, in: .common).autoconnect()) { _ in
            phase = (phase + 1) % 4
        }
    }

    private func opacity(for index: Int) -> Double {
        index == phase ? 1.0 : 0.25
    }
}

private struct InfoTooltipButton: View {
    let title: String
    let message: String
    @State private var showInfo = false

    var body: some View {
        Button {
            showInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .frame(maxWidth: 320, alignment: .leading)
        }
    }
}

private struct IPAddressCard: View {
    let addresses: [(name: String, address: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if addresses.isEmpty {
                Text("No active interface")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                ForEach(addresses, id: \.address) { ip in
                    HStack(spacing: 8) {
                        Text(ip.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 52, alignment: .trailing)
                        Text(ip.address)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }
}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (255, 255, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: 1
        )
    }
}
