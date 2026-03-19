import SwiftUI
import RealityKit
import Network
import AVFoundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import PhotosUI
import UniformTypeIdentifiers

/// Protocol for MuJoCo manager to allow StatusOverlay to display status
@MainActor
protocol MuJoCoManager: ObservableObject {
    var ipAddress: String { get }
    var connectionStatus: String { get }
    var grpcPort: Int { get }
    var isServerRunning: Bool { get }
    var simEnabled: Bool { get }  // True if simulation data has been received (USDZ loaded or poses streaming)
    var poseStreamingViaWebRTC: Bool { get }
    var bodyCount: Int { get }
    var updateFrequency: Double { get }  // Hz
}

/// Network information manager for displaying connection status
class NetworkInfoManager: ObservableObject {
    @Published var ipAddresses: [(name: String, address: String)] = []
    @Published var pythonClientIP: String? = nil
    @Published var webrtcServerInfo: (host: String, port: Int)? = nil
    
    init() {
        dlog("🔵 [StatusView] NetworkInfoManager init called")
        updateNetworkInfo()
        
        // Periodically update status
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateNetworkInfo()
        }
    }
    
    func updateNetworkInfo() {
        ipAddresses = getIPAddresses()
        pythonClientIP = DataManager.shared.pythonClientIP
        webrtcServerInfo = DataManager.shared.webrtcServerInfo
    }
}

/// Returns active local interface addresses used for connection diagnostics.
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

            // Skip loopback and inactive interfaces.
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
                    // Remove IPv6 zone identifier suffix (e.g. "%en0") for cleaner UI.
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

    // Deduplicate by IP and keep stable order by interface name.
    var seen = Set<String>()
    return addresses
        .filter { seen.insert($0.address).inserted }
        .sorted { $0.name < $1.name }
}

/// Enum to track which settings panel is currently expanded
enum ExpandedPanel: Equatable {
    case none
    case settings  // Shows the settings menu (Layer 2)
    case videoSource
    case viewControls
    case recording
    case statusPosition
    case visualizations  // Hand/head visualization toggles
    case positionLayout  // Combined video view + controller position
    case handTracking  // Hand tracking configuration (prediction, etc.)
    case stereoBaseline  // Stereo IPD/baseline adjustment
    case markerDetection  // ArUco marker detection settings
    case accessoryTracking  // Spatial controller tracking (visionOS 26+)
    case usdzCache  // USDZ scene cache management
}

/// App mode: Teleop (network-based teleoperation) vs Egorecord (local UVC recording)
enum AppMode: String, CaseIterable {
    case teleop = "teleop"
    case egorecord = "egorecord"
    
    var displayName: String {
        switch self {
        case .teleop: return "Teleoperation"
        case .egorecord: return "EgoRecord"
        }
    }
}

/// A floating status display that shows network connection info and follows the user's head
struct StatusOverlay: View {
    @Binding var hasFrames: Bool
    let showVideoStatus: Bool  // Whether to show WebRTC and frame status
    @Binding var isMinimized: Bool
    @Binding var showViewControls: Bool
    @Binding var previewZDistance: Float?
    @Binding var previewActive: Bool
    @Binding var userInteracted: Bool
    @Binding var videoMinimized: Bool
    @Binding var videoFixed: Bool
    @Binding var previewStatusPosition: (x: Float, y: Float)?
    @Binding var previewStatusActive: Bool
    var onReset: (() -> Void)? = nil
    var mujocoManager: (any MuJoCoManager)?  // Optional MuJoCo manager for combined streaming
    @ObservedObject var dataManager = DataManager.shared
    @ObservedObject private var uvcCameraManager = UVCCameraManager.shared
    @ObservedObject private var recordingManager = RecordingManager.shared
    @State private var ipAddresses: [(name: String, address: String)] = []
    @State private var pythonConnected: Bool = false
    @State private var pythonIP: String = "Not connected"
    @State private var webrtcConnected: Bool = false
    @State private var hidePreviewTask: Task<Void, Never>?
    @State private var expandedPanel: ExpandedPanel = .none
    @State private var showLocalExitConfirmation: Bool = false
    @State private var mujocoStatusUpdateTrigger: Bool = false  // Trigger for MuJoCo status updates
    @State private var resetHighlight: Bool = false

    @ObservedObject private var signalingClient = SignalingClient.shared
    
    // App mode persistence
    @AppStorage("appMode") private var appMode: AppMode = .teleop
    // Remember the video source used in teleop mode so we can restore it when switching back from egorecord
    @AppStorage("teleopVideoSource") private var teleopVideoSource: String = VideoSource.network.rawValue
    
    // Flashing animation for warnings
    @State private var flashingOpacity: Double = 1.0
    
    init(hasFrames: Binding<Bool> = .constant(false), showVideoStatus: Bool = true, isMinimized: Binding<Bool> = .constant(false), showViewControls: Binding<Bool> = .constant(false), previewZDistance: Binding<Float?> = .constant(nil), previewActive: Binding<Bool> = .constant(false), userInteracted: Binding<Bool> = .constant(false), videoMinimized: Binding<Bool> = .constant(false), videoFixed: Binding<Bool> = .constant(false), previewStatusPosition: Binding<(x: Float, y: Float)?> = .constant(nil), previewStatusActive: Binding<Bool> = .constant(false), onReset: (() -> Void)? = nil, mujocoManager: (any MuJoCoManager)? = nil) {
        self._hasFrames = hasFrames
        self.showVideoStatus = showVideoStatus
        self._isMinimized = isMinimized
        self._showViewControls = showViewControls
        self._previewZDistance = previewZDistance
        self._previewActive = previewActive
        self._userInteracted = userInteracted
        self._videoMinimized = videoMinimized
        self._videoFixed = videoFixed
        self._previewStatusPosition = previewStatusPosition
        self._previewStatusActive = previewStatusActive
        self.onReset = onReset
        self.mujocoManager = mujocoManager
//        dlog("🟢 [StatusView] StatusOverlay init called, hasFrames: \(hasFrames.wrappedValue), showVideoStatus: \(showVideoStatus), mujocoEnabled: \(mujocoManager != nil)")
    }
    
    var body: some View {
        return ZStack {
            Group {
                if isMinimized {
                    minimizedView
                } else {
                    expandedView
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isMinimized)
        }
        .onAppear {
            dlog("🔴 [StatusView] StatusOverlay onAppear called")
            ipAddresses = getIPAddresses()
            dlog("🔴 [StatusView] IP Addresses: \(ipAddresses)")
            
            // Flashing animation for warnings (gentle pulse 1.5s cycle)
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.75)) {
                    flashingOpacity = flashingOpacity == 1.0 ? 0.4 : 1.0
                }
            }
            
            // Update status periodically
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let wasPythonConnected = pythonConnected
                let wasWebrtcConnected = webrtcConnected
                
                // Check for Python connection via either local gRPC or remote signaling
                let localPythonConnected = DataManager.shared.pythonClientIP != nil
                let remotePythonConnected = signalingClient.peerConnected
                
                if localPythonConnected {
                    pythonConnected = true
                    pythonIP = DataManager.shared.pythonClientIP ?? "Connected"
                } else if remotePythonConnected {
                    pythonConnected = true
                    pythonIP = "Remote (\(signalingClient.roomCode))"
                } else {
                    pythonConnected = false
                    pythonIP = "Not connected"
                }
                
                // Check for WebRTC connection via either local or remote
                let localWebrtcConnected = DataManager.shared.webrtcServerInfo != nil
                webrtcConnected = localWebrtcConnected || remotePythonConnected
                
                // Toggle trigger to force MuJoCo status update
                mujocoStatusUpdateTrigger.toggle()
                
                // Detect disconnection and maximize status view
                if (wasPythonConnected && !pythonConnected) || (wasWebrtcConnected && !webrtcConnected) {
                    dlog("🔌 [StatusView] Connection lost - maximizing status view")
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        isMinimized = false
                        userInteracted = false  // Reset so it can auto-minimize again on next connection
                        hasFrames = false  // Clear frames flag
                    }
                }
                
                // Detect connection and minimize status view
                if (!wasPythonConnected && pythonConnected) {
                     // Only minimize on Python connection if NOT in video mode (hand tracking only)
                     // In video mode, we wait for frames to arrive (handled in ImmersiveView)
                     if !showVideoStatus {
                         dlog("🔌 [StatusView] Connection established - minimizing status view")
                         if !userInteracted {
                             withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                 isMinimized = true
                             }
                         }
                     }
                }
                
            }
        }
    }
    
    private var minimizedView: some View {
        VStack(spacing: 12) {
            // Recording timer (show above buttons when recording)
            if recordingManager.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.red.opacity(0.5), lineWidth: 2)
                                .scaleEffect(1.5)
                                .opacity(0.8)
                        )
                    Text("REC")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.red)
                    Text(recordingManager.formatDuration(recordingManager.recordingDuration))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("•")
                        .foregroundColor(.white.opacity(0.5))
                    Text("\(recordingManager.frameCount) frames")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.8))
                .cornerRadius(20)
            }
            
            // USDZ transfer progress indicator (show above buttons when transferring)
            if dataManager.usdzTransferInProgress {
                VStack(spacing: 6) {
                    // Header
                    HStack(spacing: 6) {
                        Image(systemName: "cube.transparent.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.purple)
                        
                        Text("Loading 3D Scene")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        
                        // Spinning indicator
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .purple))
                            .scaleEffect(0.7)
                    }
                    
                    // Filename
                    if !dataManager.usdzTransferFilename.isEmpty {
                        Text(dataManager.usdzTransferFilename)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    // Progress bar with percentage
                    HStack(spacing: 8) {
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 140, height: 8)
                            
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.purple)
                                .frame(width: 140 * CGFloat(dataManager.usdzTransferProgress), height: 8)
                                .animation(.easeInOut(duration: 0.2), value: dataManager.usdzTransferProgress)
                        }
                        
                        Text("\(Int(dataManager.usdzTransferProgress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    
                    // Size info
                    Text("\(dataManager.usdzTransferReceivedChunks)/\(dataManager.usdzTransferTotalChunks) chunks • \(dataManager.usdzTransferTotalSizeKB) KB")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.purple.opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.purple.opacity(0.5), lineWidth: 1)
                        )
                )
            }
            
            HStack(spacing: 16) {
                if showLocalExitConfirmation {
                    // Confirmation mode
                    VStack(spacing: 8) {
                        Text("Exit?")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    
                    Button {
                        dlog("❌ [StatusView] Exiting app now")
                        exit(0)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 60, height: 60)
                            Image(systemName: "checkmark")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        withAnimation {
                            showLocalExitConfirmation = false
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.gray.opacity(0.5))
                                .frame(width: 60, height: 60)
                            Image(systemName: "xmark")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    // Normal mode
                    // Expand button
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            isMinimized = false
                            userInteracted = true  // Mark that user has interacted
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 60, height: 60)
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)

                    // Controller lock button (lock minimized controller bar to world space)
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            dataManager.statusFixedToWorld.toggle()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(dataManager.statusFixedToWorld ? Color.purple.opacity(0.8) : Color.gray.opacity(0.6))
                                .frame(width: 60, height: 60)
                            Image(systemName: dataManager.statusFixedToWorld ? "lock.fill" : "lock.open.fill")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)

                    // Recording button
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if recordingManager.isRecording {
                                recordingManager.stopRecordingManually()
                            } else {
                                recordingManager.startRecording()
                            }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(recordingManager.isRecording ? Color.red : Color.gray.opacity(0.6))
                                .frame(width: 60, height: 60)
                            if recordingManager.isRecording {
                                // Stop icon (square)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white)
                                    .frame(width: 22, height: 22)
                            } else {
                                // Record icon (circle)
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 24, height: 24)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    
                    // Video minimize/maximize button (only show if video streaming mode is enabled)
                    if showVideoStatus {
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                videoMinimized.toggle()
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(dataManager.videoEnabled && !videoMinimized ? Color.blue.opacity(0.8) : Color.gray.opacity(0.6))
                                    .frame(width: 60, height: 60)
                                Image(systemName: "video.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)

                        // Toggle world-fixed mode for the video panel
                        Button {
                            videoFixed.toggle()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(videoFixed ? Color.orange.opacity(0.8) : Color.gray.opacity(0.6))
                                    .frame(width: 60, height: 60)
                                Image(systemName: videoFixed ? "lock.fill" : "lock.open.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if onReset != nil {
                        // Mujoco Reset Button or Simulation reset button
                        Button {
                            dlog("🔄 [StatusView] Reset button tapped")
                            onReset?()
                            userInteracted = true
                            resetHighlight = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_600_000_000)
                                await MainActor.run { resetHighlight = false }
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(resetHighlight ? Color.green.opacity(0.8) : Color.gray.opacity(0.6))
                                    .frame(width: 60, height: 60)
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
//                        .opacity(dataManager.controlChannelReady ? 1.0 : 0.5)
                    }
                    
                    // Exit button
                    Button {
                        dlog("🔴 [StatusView] Exit button tapped (minimized)")
                        exit(0)
//                        withAnimation {
//                            showLocalExitConfirmation = true
//                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 60, height: 60)
                            Text("✕")
                                .font(.system(size: 27, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Storage location indicator (minimal line below buttons)
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 10))
                Text("Local")
                    .font(.system(size: 10))
            }
            .foregroundColor(.white.opacity(0.5))
        }
        .padding(30)
        .background(Color.black.opacity(0.6))
        .cornerRadius(36)
        .fixedSize()
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                // Minimize button
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        isMinimized = true
                        userInteracted = true  // Mark that user has interacted
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 60, height: 60)
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text("Go2 Teleop")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button {
                    dlog("🔴 [StatusView] Exit button tapped (expanded)")
                    exit(0)
//                    withAnimation {
//                        showLocalExitConfirmation = true
//                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 60, height: 60)
                        Text("✕")
                            .font(.system(size: 27, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
            }
        }
    }
    
    private var modeToggleSection: some View {
        HStack(spacing: 0) {
            ForEach(AppMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        // When switching to egorecord, save current video source and force UVC
                        if mode == .egorecord && appMode == .teleop {
                            teleopVideoSource = dataManager.videoSource.rawValue
                            dataManager.videoSource = .uvcCamera
                        }
                        // When switching back to teleop, restore the previous video source
                        else if mode == .teleop && appMode == .egorecord {
                            if let savedSource = VideoSource(rawValue: teleopVideoSource) {
                                dataManager.videoSource = savedSource
                            }
                        }
                        appMode = mode
                    }
                } label: {
                    Text(mode.displayName)
                        .foregroundColor(appMode == mode ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .font(.system(size: 20, weight: .bold))
                        .background(
                            appMode == mode 
                                ? (mode == .teleop ? Color.blue : Color.orange)
                                : Color.clear
                        )
                        .cornerRadius(16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.15))
        .cornerRadius(20)
    }

    private var networkInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Side-by-side layout: Local Network | Remote
            HStack(alignment: .top, spacing: 20) {
                // LEFT: Local Network (IP Addresses)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi")
                            .font(.system(size: 12))
                            .foregroundColor(.blue.opacity(0.8))
                        Text("Local Network")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    ForEach(ipAddresses, id: \.address) { ip in
                        HStack(spacing: 8) {
                            Text(ip.name)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(width: 45, alignment: .trailing)
                            Text(ip.address)
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                    }
                }
                
                // Vertical Divider
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 1, height: 60)
                
                // RIGHT: Remote (Room Code)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 12))
                            .foregroundColor(.cyan.opacity(0.8))
                        Text("Remote")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Text(signalingClient.roomCode)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            
            // Connection status cards - show when Python connected via either method
            HStack(spacing: 8) {
                // Python connection card (local gRPC)
                connectionStatusCard(
                    icon: "terminal.fill",
                    title: "Python",
                    status: pythonConnected ? pythonIP : "Waiting...",
                    isConnected: pythonConnected,
                    accentColor: .green
                )
                
                // WebRTC connection card (only if video mode)
                if showVideoStatus {
                    connectionStatusCard(
                        icon: "video.fill",
                        title: "WebRTC",
                        status: webrtcConnected ? (DataManager.shared.webRTCConnectionType.isEmpty ? "Connected" : "Connected (\(DataManager.shared.webRTCConnectionType))") : "Waiting...",
                        isConnected: webrtcConnected,
                        accentColor: .purple
                    )
                }
            }
        }
    }

    // New styled row for status items (Room Code, Status)
    private func statusRow(icon: String, label: String, value: String, valueColor: Color, iconColor: Color, showActivitySpinner: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(iconColor.opacity(0.9))
                .frame(width: 20)
            
            Text(label)
                .font(.subheadline) // Approx 15pt
                .foregroundColor(.white.opacity(0.7))
            
            Spacer()
            
            if showActivitySpinner {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 4)
            }
            
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    private func connectionStatusCard(icon: String, title: String, status: String, isConnected: Bool, accentColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(isConnected ? accentColor : .white.opacity(0.4))
                Text(title)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Circle()
                    .fill(isConnected ? accentColor : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
            
            Text(status)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(isConnected ? .white : .white.opacity(0.4))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isConnected ? accentColor.opacity(0.15) : Color.white.opacity(0.05))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isConnected ? accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
    
    private var egorecordInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Info description
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.5))
                
                Text("Records egocentric video and hand/head tracking. This mode requires:")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // Requirements list - horizontal layout
            HStack(spacing: 12) {
                requirementRow(number: "1", text: "Camera")
                requirementRow(number: "2", text: "Dev Strap")
                requirementRow(number: "3", text: "Cam Mount")
            }
            .padding(.leading, 26) // Align with text above
        }
    }
    
    private func requirementRow(number: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(number + ".")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
    }
    
    private var teleopInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Info description
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.5))
                
                Text("Requires a Python client to receive hand tracking data and stream back:")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // Capabilities list
            HStack(spacing: 16) {
                capabilityRow(icon: "video.fill", text: "Video")
                capabilityRow(icon: "waveform", text: "Audio")
                capabilityRow(icon: "cube.transparent", text: "Sim states")
            }
            .padding(.leading, 26) // Align with text above
        }
    }
    
    private func capabilityRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 14)
            Text(text)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
    }
    
    // MARK: - Version Incompatibility Warning
    
    private var versionWarningBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with warning icon
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.yellow)
                    .opacity(flashingOpacity)
                
                Text("Python Library Update Required")
                    .font(.callout)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            
            // Version info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Your version:")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Text(dataManager.pythonLibraryVersionString)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundColor(.red)
                }
                
                HStack {
                    Text("Minimum required:")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Text(DataManager.minimumPythonVersionString)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                }
            }
            .padding(8)
            .background(Color.black.opacity(0.3))
            .cornerRadius(6)
            
            // Upgrade instructions
            HStack(spacing: 4) {
                Text("Run:")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                Text("pip install --upgrade avp-stream")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.4))
                    .cornerRadius(4)
            }
            
            // Warning message
            Text("Hand tracking is blocked until you upgrade. Please update your Python library and restart.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                )
        )
    }

    private var streamDetailsSection: some View {
        HStack(spacing: 0) {
            // Video column
            VStack(spacing: 6) {
                // Title badge - show source type
                let isUVCMode = dataManager.videoSource == .uvcCamera
                let videoActive = isUVCMode ? uvcCameraManager.isCapturing : dataManager.videoEnabled
                
                Text(isUVCMode ? "USB Cam" : "Video")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(videoActive ? .white : .white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(videoActive ? 0.2 : 0.08))
                    .cornerRadius(8)
                
                if isUVCMode {
                    // UVC camera info
                    if uvcCameraManager.isCapturing {
                        if uvcCameraManager.stereoEnabled {
                            Text("Stereo")
                                .font(.caption)
                                .foregroundColor(.white)
                                .fontWeight(.medium)
                        } else {
                            Text("Mono")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        
                        if uvcCameraManager.frameWidth > 0 {
                            Text("\(uvcCameraManager.frameWidth)×\(uvcCameraManager.frameHeight)")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                                .monospacedDigit()
                        }
                        if uvcCameraManager.fps > 0 {
                            Text("\(uvcCameraManager.fps) fps")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                                .monospacedDigit()
                        }
                    } else if uvcCameraManager.selectedDevice != nil {
                        Text("Starting...")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    } else {
                        Text("No Device")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                } else if dataManager.videoEnabled {
                    // Network video info
                    if dataManager.stereoEnabled {
                        Text("Stereo")
                            .font(.caption)
                            .foregroundColor(.white)
                            .fontWeight(.medium)
                    } else {
                        Text("Mono")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    // Stats
                    if !dataManager.videoResolution.isEmpty && dataManager.videoResolution != "Waiting..." {
                        Text(dataManager.videoResolution)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                    if dataManager.videoFPS > 0 {
                        Text("\(dataManager.videoFPS) fps")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                } else {
                    Text("N/A")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            
            // Vertical divider
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 40)
            
            // Audio column
            VStack(spacing: 6) {
                // Title badge
                Text("Audio")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(dataManager.audioEnabled ? .white : .white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(dataManager.audioEnabled ? 0.2 : 0.08))
                    .cornerRadius(8)
                
                // Status
                if dataManager.audioEnabled {
                    if dataManager.stereoAudioEnabled {
                        Text("Stereo")
                            .font(.caption)
                            .foregroundColor(.white)
                            .fontWeight(.medium)
                    } else {
                        Text("Mono")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    // Stats
                    if dataManager.audioSampleRate > 0 {
                        Text("\(dataManager.audioSampleRate) Hz")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                } else {
                    Text("N/A")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            
            // Vertical divider
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 40)
            
            // Sim column
            VStack(spacing: 6) {
                let _ = mujocoStatusUpdateTrigger  // Force refresh
                
                // Determine if simulation is active (has received data)
                let simActive = mujocoManager?.simEnabled == true || (mujocoManager?.bodyCount ?? 0) > 0
                
                // Title badge
                Text("Sim")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(simActive ? .white : .white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(simActive ? 0.2 : 0.08))
                    .cornerRadius(8)
                
                if let mujoco = mujocoManager, simActive {
                    // Status
                    if mujoco.poseStreamingViaWebRTC {
                        Text("WebRTC")
                            .font(.caption)
                            .foregroundColor(.white)
                            .fontWeight(.medium)
                    } else {
                        Text("gRPC")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .fontWeight(.medium)
                    }
                    
                    // Body count
                    if mujoco.bodyCount > 0 {
                        Text("\(mujoco.bodyCount) bodies")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    // Update frequency
                    if mujoco.updateFrequency > 0 {
                        Text(String(format: "%.0f Hz", mujoco.updateFrequency))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                } else {
                    Text("N/A")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
    
    private var usdzTransferProgressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with icon and filename
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.purple)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading 3D Scene")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    
                    if !dataManager.usdzTransferFilename.isEmpty {
                        Text(dataManager.usdzTransferFilename)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                
                Spacer()
                
                // Percentage
                Text("\(Int(dataManager.usdzTransferProgress * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.purple)
            }
            
            // Progress bar
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 8)
                
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [Color.purple, Color.purple.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(dataManager.usdzTransferProgress), height: 8)
                        .animation(.easeInOut(duration: 0.2), value: dataManager.usdzTransferProgress)
                }
                .frame(height: 8)
            }
            
            // Stats
            HStack {
                Text("\(dataManager.usdzTransferReceivedChunks)/\(dataManager.usdzTransferTotalChunks) chunks")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
                
                Spacer()
                
                Text("\(dataManager.usdzTransferTotalSizeKB) KB")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.purple.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var expandedView: some View {
        HStack(alignment: .center, spacing: 0) {
            // Panel 1 (Left) - Main status panel
            leftColumnView
            
            // Panel 2 (Right) - Settings panel (switches between menu and content)
            if expandedPanel != .none {
                settingsPanelView
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: expandedPanel)
        .overlay(
            Group {
                if showLocalExitConfirmation {
                    ZStack {
                        Color.black.opacity(0.9)
                        
                        VStack(spacing: 20) {
                            Text("Are you sure you want to exit?")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            HStack(spacing: 20) {
                                Button {
                                    withAnimation {
                                        showLocalExitConfirmation = false
                                    }
                                } label: {
                                    Text("Cancel")
                                        .fontWeight(.medium)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.gray.opacity(0.5))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                
                                Button {
                                    dlog("❌ [StatusView] Exiting app now")
                                    exit(0)
                                } label: {
                                    Text("Exit")
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.red)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .cornerRadius(16)
                }
            }
        )
    }
    
    private var leftColumnView: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // Info sections
            if appMode == .teleop {
                teleopInfoSection
            } else if appMode == .egorecord {
                egorecordInfoSection
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // Mode toggle (between info sections and network info)
            HStack {
                Spacer()
                modeToggleSection
                Spacer()
            }
            
            // Network info only shown in Teleop mode
            if appMode == .teleop {
                // Version incompatibility warning (shown prominently when connected but incompatible)
                if dataManager.shouldShowVersionWarning {
                    versionWarningBanner
                }
                
                Divider()
                    .background(Color.white.opacity(0.2))
                
                networkInfoSection
                
                // Show detailed track information when connected (either WebRTC or UVC camera)
                let showStreamDetails = showVideoStatus && (webrtcConnected || (dataManager.videoSource == .uvcCamera && uvcCameraManager.isCapturing))
                if showStreamDetails {
                    Divider()
                        .background(Color.white.opacity(0.2))
                    
                    streamDetailsSection
                }
                
                // USDZ transfer progress (shown when loading 3D scene)
                if dataManager.usdzTransferInProgress {
                    Divider()
                        .background(Color.white.opacity(0.2))
                    
                    usdzTransferProgressSection
                }
            }
            
            // Show waiting message when no frames are available (only for video mode)
            // Don't show waiting for UVC if a camera is capturing
            let isUVCActive = dataManager.videoSource == .uvcCamera && uvcCameraManager.isCapturing
            if showVideoStatus && !hasFrames && !isUVCActive {
                Divider()
                    .background(Color.white.opacity(0.3))
                
                HStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.0)
                    Text(dataManager.videoSource == .uvcCamera ?
                         (uvcCameraManager.selectedDevice == nil ? "No USB camera detected" : "Waiting for camera...") :
                         dataManager.connectionStatus)
                        .foregroundColor(.white.opacity(0.9))
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(2)
                }
            }
            
            // Settings button - opens Layer 2 settings menu
            Divider()
                .background(Color.white.opacity(0.3))
            
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expandedPanel = expandedPanel == .none ? .settings : .none
                }
            } label: {
                HStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(expandedPanel != .none ? .blue : .white.opacity(0.9))
                        .frame(width: 24)
                    Text("Settings")
                        .font(.body)
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(expandedPanel != .none ? .blue : .white.opacity(0.5))
                }
                .foregroundColor(expandedPanel != .none ? .blue : .white.opacity(0.9))
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
                .background(expandedPanel != .none ? Color.blue.opacity(0.15) : Color.clear)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            
            // Egorecord mode: Start Recording button with requirement checks
            if appMode == .egorecord {
                Divider()
                    .background(Color.white.opacity(0.3))
                let hasCamera = uvcCameraManager.selectedDevice != nil
                if !hasCamera {
                    HStack(spacing: 6) {
                        Image(systemName: "video.slash.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                        Text("No USB camera - hand tracking only")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                    .padding(.vertical, 6)
                }
                
                // Start Recording button
                Button {
                    if !recordingManager.isRecording {
                        recordingManager.startRecording()
                        // Auto-minimize and hide video in egorecord mode
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            isMinimized = true
                            videoMinimized = true
                            userInteracted = true
                        }
                    } else {
                        recordingManager.stopRecordingManually()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: recordingManager.isRecording ? "stop.fill" : "record.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                        Text(recordingManager.isRecording ? "Stop Recording" : "Start Recording")
                            .font(.headline)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        recordingManager.isRecording 
                            ? Color.red
                            : Color.red.opacity(0.9)
                    )
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }

        }
        .padding(24)
        .frame(width: 400)
        .background(Color.black.opacity(0.7))
        .cornerRadius(16)
    }
    
    private func menuItem(icon: String, title: String, subtitle: String?, isExpanded: Bool, accentColor: Color, iconColor: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(iconColor ?? (isExpanded ? accentColor : .white.opacity(0.9)))
                    .frame(width: 24)
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(isExpanded ? accentColor : .white.opacity(0.6))
                }
                Image(systemName: isExpanded ? "chevron.right" : "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isExpanded ? accentColor : .white.opacity(0.5))
            }
            .foregroundColor(isExpanded ? accentColor : .white.opacity(0.9))
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background(isExpanded ? accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Settings Panel View (combines menu and content in one panel)
    
    private var settingsPanelView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Panel header
            HStack {
                // Back button (only shown when viewing specific settings)
                if expandedPanel != .settings {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            expandedPanel = .settings
                            previewZDistance = nil
                            previewActive = false
                            previewStatusPosition = nil
                            previewStatusActive = false
                            hidePreviewTask?.cancel()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 44, height: 44)
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
                
                Text(panelTitle)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Spacer()
                
                // Close button
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        expandedPanel = .none
                        previewZDistance = nil
                        previewActive = false
                        previewStatusPosition = nil
                        previewStatusActive = false
                        hidePreviewTask?.cancel()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 44, height: 44)
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // Panel content - either menu or specific settings
            if expandedPanel == .settings {
                settingsMenuContent
            } else {
                settingsDetailContent
            }
        }
        .padding(24)
        .frame(width: 340)
        .background(Color.black.opacity(0.7))
        .cornerRadius(16)
        .padding(.leading, 8)
    }
    
    // MARK: - Settings Menu Content
    
    private var settingsMenuContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Video Source menu item (only in video mode)
            if showVideoStatus {
                menuItem(
                    icon: dataManager.videoSource.icon,
                    title: "Video Source",
                    subtitle: dataManager.videoSource.rawValue,
                    isExpanded: false,
                    accentColor: .blue
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        expandedPanel = .videoSource
                    }
                }
                
                // Video Plane menu item
                menuItem(
                    icon: "rectangle.on.rectangle",
                    title: "Video Plane",
                    subtitle: String(format: "%.1fm, %d%%", -dataManager.videoPlaneZDistance, Int(dataManager.videoPlaneScale * 100)),
                    isExpanded: expandedPanel == .viewControls,
                    accentColor: .blue
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        expandedPanel = expandedPanel == .viewControls ? .settings : .viewControls
                    }
                }
                
                // Controller Position menu item
                menuItem(
                    icon: "arrow.up.and.down.and.arrow.left.and.right",
                    title: "Controller Position",
                    subtitle: nil,
                    isExpanded: expandedPanel == .statusPosition,
                    accentColor: .purple
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        expandedPanel = expandedPanel == .statusPosition ? .settings : .statusPosition
                    }
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Recording menu item
            menuItem(
                icon: recordingManager.isRecording ? "record.circle.fill" : "record.circle",
                title: "Recording",
                subtitle: recordingManager.isRecording 
                    ? recordingManager.formatDuration(recordingManager.recordingDuration) 
                    : "Local",
                isExpanded: false,
                accentColor: .red,
                iconColor: recordingManager.isRecording ? .red : nil
            ) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expandedPanel = .recording
                }
            }
            
            // Teleop-only menu items
            if appMode == .teleop {
                Divider()
                    .background(Color.white.opacity(0.2))
                
                // Visualizations
                let activeCount = [dataManager.upperLimbVisible, dataManager.showHeadBeam, dataManager.showHandJoints].filter { $0 }.count
                
                menuItem(
                    icon: "eye.fill",
                    title: "Visualizations",
                    subtitle: "\(activeCount)/3 active",
                    isExpanded: false,
                    accentColor: .cyan
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        expandedPanel = .visualizations
                    }
                }
                
                // Hand Tracking Config
                let predictionMs = Int(dataManager.handPredictionOffset * 1000)
                menuItem(
                    icon: dataManager.showHandJoints ? "hand.raised.fingers.spread.fill" : "hand.raised.fingers.spread",
                    title: "Hand Tracking",
                    subtitle: "\(predictionMs)ms prediction",
                    isExpanded: false,
                    accentColor: .orange,
                    iconColor: dataManager.showHandJoints ? .green : nil
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        expandedPanel = .handTracking
                    }
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            let offsetPercent = dataManager.stereoBaselineOffset * 100
            let offsetLabel = abs(offsetPercent) < 0.05 ? "Default" : String(format: "%+.1f%%", offsetPercent)
            
            menuItem(
                icon: "eyes",
                title: "Stereo Baseline",
                subtitle: offsetLabel,
                isExpanded: false,
                accentColor: .indigo
            ) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expandedPanel = .stereoBaseline
                }
            }
            
            // Marker Detection (Teleop mode only)
            if appMode == .teleop {
                let markerManager = MarkerDetectionManager.shared
                menuItem(
                    icon: markerManager.isEnabled ? "viewfinder.circle.fill" : "viewfinder.circle",
                    title: "Marker Detection",
                    subtitle: markerManager.isEnabled ? "\(markerManager.detectedMarkers.count) detected" : "Off",
                    isExpanded: false,
                    accentColor: .orange,
                    iconColor: markerManager.isEnabled ? .green : nil
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        expandedPanel = .markerDetection
                    }
                }
                
                // USDZ Cache (Teleop mode - for MuJoCo/Isaac sim scenes)
                let cacheManager = UsdzCacheManager.shared
                menuItem(
                    icon: "archivebox.fill",
                    title: "USDZ Cache",
                    subtitle: cacheManager.formattedCacheSize,
                    isExpanded: false,
                    accentColor: .purple
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        expandedPanel = .usdzCache
                    }
                }
                
                // Accessory Tracking (visionOS 26+ only)
                if #available(visionOS 26.0, *) {
                    let accessoryManager = AccessoryTrackingManager.shared
                    menuItem(
                        icon: accessoryManager.isEnabled ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                        title: "Stylus Tracking",
                        subtitle: accessoryManager.isEnabled ? (accessoryManager.stylusAnchorEntity != nil ? "Active" : "Searching") : "Off",
                        isExpanded: false,
                        accentColor: .cyan,
                        iconColor: accessoryManager.isEnabled ? .green : nil
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            expandedPanel = .accessoryTracking
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Settings Detail Content
    
    private var settingsDetailContent: some View {
        Group {
            switch expandedPanel {
            case .videoSource:
                videoSourcePanelContent
            case .viewControls:
                viewControlsPanelContent
            case .recording:
                recordingPanelContent
            case .statusPosition:
                statusPositionPanelContent
            case .positionLayout:
                positionLayoutPanelContent
            case .visualizations:
                visualizationsPanelContent
            case .handTracking:
                handTrackingPanelContent
            case .stereoBaseline:
                stereoBaselinePanelContent
            case .markerDetection:
                markerDetectionPanelContent
            case .usdzCache:
                usdzCachePanelContent
            case .accessoryTracking:
                if #available(visionOS 26.0, *) {
                    accessoryTrackingPanelContent
                } else {
                    EmptyView()
                }
            case .settings, .none:
                EmptyView()
            }
        }
    }
    
    private var panelTitle: String {
        switch expandedPanel {
        case .settings: return "Settings"
        case .videoSource: return "Video Source"
        case .viewControls: return "Video Plane"
        case .recording: return "Recording"
        case .statusPosition: return "Controller Position"
        case .positionLayout: return "Position & Layout"
        case .visualizations: return "Visualizations"
        case .handTracking: return "Hand Tracking"
        case .stereoBaseline: return "Stereo Baseline"
        case .markerDetection: return "Marker Detection"
        case .usdzCache: return "USDZ Cache"
        case .accessoryTracking: return "Accessory Tracking"
        case .none: return ""
        }
    }
    
    // MARK: - Right Panel Content Views
    
    private var videoSourcePanelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Network Stream option (disabled in Egorecord mode)
            let networkDisabled = appMode == .egorecord
            
            Button {
                if !networkDisabled {
                    withAnimation {
                        dataManager.videoSource = .network
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wifi")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Network Stream")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(networkDisabled ? "Not available in Egorecord" : "WebRTC from Python")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    if networkDisabled {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.3))
                    } else if dataManager.videoSource == .network {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(networkDisabled ? Color.white.opacity(0.05) : (dataManager.videoSource == .network ? Color.blue.opacity(0.3) : Color.white.opacity(0.1)))
                .cornerRadius(10)
                .foregroundColor(networkDisabled ? .white.opacity(0.4) : .white)
            }
            .buttonStyle(.plain)
            .disabled(networkDisabled)
            
            // USB Camera option
            Button {
                Task {
                    let granted = await uvcCameraManager.requestCameraAccess()
                    if granted {
                        await MainActor.run {
                            withAnimation {
                                dataManager.videoSource = .uvcCamera
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("USB Camera")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("UVC via Developer Strap")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    if dataManager.videoSource == .uvcCamera {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(dataManager.videoSource == .uvcCamera ? Color.blue.opacity(0.3) : Color.white.opacity(0.1))
                .cornerRadius(10)
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            
            // Available cameras section (show only when USB selected)
            if dataManager.videoSource == .uvcCamera && !uvcCameraManager.availableDevices.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.3))
                
                Text("Available Cameras")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.6))
                
                ForEach(uvcCameraManager.availableDevices.prefix(2)) { device in
                    Button {
                        uvcCameraManager.selectDevice(device)
                        Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await MainActor.run { uvcCameraManager.startCapture() }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 22)
                            Text(device.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Spacer()
                            if uvcCameraManager.selectedDevice?.id == device.id && uvcCameraManager.isCapturing {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(uvcCameraManager.selectedDevice?.id == device.id ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
                        .cornerRadius(10)
                        .foregroundColor(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
                
                // Stereo/Mono picker (show when camera is capturing)
                if uvcCameraManager.isCapturing {
                    Divider()
                        .background(Color.white.opacity(0.3))
                    
                    Text("Feed Type")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.6))
                    
                    HStack(spacing: 10) {
                        // Mono option
                        Button {
                            uvcCameraManager.setStereoMode(false)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "rectangle")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Mono")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(!uvcCameraManager.stereoEnabled ? .white : .white.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(!uvcCameraManager.stereoEnabled ? Color.cyan.opacity(0.4) : Color.white.opacity(0.1))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        
                        // Stereo option
                        Button {
                            uvcCameraManager.setStereoMode(true)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "rectangle.split.2x1")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Stereo")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(uvcCameraManager.stereoEnabled ? .white : .white.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(uvcCameraManager.stereoEnabled ? Color.cyan.opacity(0.4) : Color.white.opacity(0.1))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Text("Stereo: Side-by-side left/right feed")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }
    
    private var viewControlsPanelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Size control
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Size")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(Int(dataManager.videoPlaneScale * 100))%")
                        .font(.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                
                Slider(value: Binding(
                    get: { dataManager.videoPlaneScale },
                    set: { newValue in
                        dataManager.videoPlaneScale = newValue
                        previewActive = true
                        hidePreviewTask?.cancel()
                        hidePreviewTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if !Task.isCancelled { previewActive = false }
                        }
                    }
                ), in: 0.2...3.0, step: 0.1)
                .tint(.purple)
            }
            
            // Distance control
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Distance")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(String(format: "%.1f", -dataManager.videoPlaneZDistance))m")
                        .font(.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                
                Slider(value: Binding(
                    get: { -dataManager.videoPlaneZDistance },
                    set: { positiveValue in
                        let negativeValue = -positiveValue
                        dataManager.videoPlaneZDistance = negativeValue
                        previewZDistance = negativeValue
                        hidePreviewTask?.cancel()
                        hidePreviewTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if !Task.isCancelled { previewZDistance = nil }
                        }
                    }
                ), in: 1.0...25.0, step: 0.5)
                .tint(.blue)
            }
            
            // Height control
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Height")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(String(format: "%.2f", dataManager.videoPlaneYPosition))m")
                        .font(.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                
                Slider(value: Binding(
                    get: { dataManager.videoPlaneYPosition },
                    set: { newValue in
                        dataManager.videoPlaneYPosition = newValue
                        previewActive = true
                        hidePreviewTask?.cancel()
                        hidePreviewTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if !Task.isCancelled { previewActive = false }
                        }
                    }
                ), in: -3.0...3.0, step: 0.1)
                .tint(.green)
            }
            
            // Lock to world toggle
            HStack {
                Text("Lock To World")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Toggle("", isOn: $videoFixed)
                    .labelsHidden()
                    .tint(.orange)
            }
            
            // Action buttons
            HStack(spacing: 8) {
                Button {
                    withAnimation { videoMinimized.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: videoMinimized ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(videoMinimized ? "Show" : "Hide")
                            .font(.caption2)
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                
                Button {
                    dataManager.videoPlaneScale = 0.8
                    dataManager.videoPlaneZDistance = -10.0
                    dataManager.videoPlaneYPosition = 0.0
                    dataManager.videoPlaneAutoPerpendicular = false
                    previewZDistance = -12.0
                    previewActive = true
                    hidePreviewTask?.cancel()
                    hidePreviewTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if !Task.isCancelled {
                            previewZDistance = nil
                            previewActive = false
                        }
                    }
                } label: {
                    Text("Reset")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var recordingPanelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if recordingManager.isRecording {
                // Active recording display
                VStack(alignment: .leading, spacing: 12) {
                    // Recording indicator header
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .shadow(color: .red.opacity(0.6), radius: 4)
                        
                        Text("Recording")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                        
                        Spacer()
                        
                        if recordingManager.isAutoRecording {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                                Text("Auto")
                                    .font(.caption2)
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(6)
                        }
                    }
                    
                    // Stats row
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Duration")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                            Text(recordingManager.formatDuration(recordingManager.recordingDuration))
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .monospacedDigit()
                        }
                        
                        Divider()
                            .frame(height: 36)
                            .background(Color.white.opacity(0.2))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Frames")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                            Text("\(recordingManager.frameCount)")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .monospacedDigit()
                        }
                        
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(10)
                    
                    // Stop button
                    Button { recordingManager.stopRecordingManually() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("Stop Recording")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            } else if recordingManager.isSaving {
                HStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saving Recording")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                        Text("Please wait...")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.white.opacity(0.1))
                .cornerRadius(12)
            } else {
                // Recording configuration
                VStack(alignment: .leading, spacing: 16) {
                    // Auto-recording toggle with description
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $recordingManager.autoRecordingEnabled) {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(recordingManager.autoRecordingEnabled ? Color.orange.opacity(0.2) : Color.white.opacity(0.1))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: recordingManager.autoRecordingEnabled ? "record.circle.fill" : "record.circle")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(recordingManager.autoRecordingEnabled ? .orange : .white.opacity(0.5))
                                }
                                
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Auto-Record")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                    Text("Automatically start when video frames arrive")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(2)
                                }
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .orange))
                    }
                    .padding(12)
                    .background(recordingManager.autoRecordingEnabled ? Color.orange.opacity(0.1) : Color.white.opacity(0.05))
                    .cornerRadius(12)
                    
                    // Storage Location Section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.6))
                            Text("Storage Location")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.white.opacity(0.6))
                                .textCase(.uppercase)
                                .tracking(0.5)
                        }
                        
                        // Storage options
                        VStack(spacing: 8) {
                            storageOptionRow(
                                icon: "internaldrive",
                                label: "Local Storage",
                                description: "Save to device, transfer via Files app",
                                isSelected: recordingManager.storageLocation == .local,
                                color: .green
                            ) {
                                recordingManager.storageLocation = .local
                            }
                        }
                    }
                }
            }
        }
    }
    
    // Helper for storage option rows with descriptions
    private func storageOptionRow(icon: String, label: String, description: String, isSelected: Bool, color: Color, showWarning: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? color.opacity(0.2) : Color.white.opacity(0.08))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? color : .white.opacity(0.5))
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(isSelected ? .white : .white.opacity(0.8))
                        if showWarning {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                    }
                    Text(description)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? color.opacity(0.12) : Color.white.opacity(0.04))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? color.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    // Legacy helper for backwards compatibility
    private func storageOptionButton(icon: String, label: String, isSelected: Bool, color: Color, showWarning: Bool = false, action: @escaping () -> Void) -> some View {
        storageOptionRow(icon: icon, label: label, description: "", isSelected: isSelected, color: color, showWarning: showWarning, action: action)
    }
    
    private var statusPositionPanelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Lock To World")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Toggle("", isOn: $dataManager.statusFixedToWorld)
                    .labelsHidden()
                    .tint(.orange)
            }
            
            // X position control
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("X (Left-Right)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(String(format: "%.2f", dataManager.statusMinimizedXPosition))m")
                        .font(.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                
                Slider(value: Binding(
                    get: { dataManager.statusMinimizedXPosition },
                    set: { newValue in
                        dataManager.statusMinimizedXPosition = newValue
                        previewStatusPosition = (x: newValue, y: dataManager.statusMinimizedYPosition)
                        previewStatusActive = true
                        hidePreviewTask?.cancel()
                        hidePreviewTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if !Task.isCancelled {
                                previewStatusPosition = nil
                                previewStatusActive = false
                            }
                        }
                    }
                ), in: -0.5...0.5, step: 0.05)
                .tint(.purple)
            }
            
            // Y position control
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Y (Up-Down)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(String(format: "%.2f", dataManager.statusMinimizedYPosition))m")
                        .font(.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                
                Slider(value: Binding(
                    get: { dataManager.statusMinimizedYPosition },
                    set: { newValue in
                        dataManager.statusMinimizedYPosition = newValue
                        previewStatusPosition = (x: dataManager.statusMinimizedXPosition, y: newValue)
                        previewStatusActive = true
                        hidePreviewTask?.cancel()
                        hidePreviewTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if !Task.isCancelled {
                                previewStatusPosition = nil
                                previewStatusActive = false
                            }
                        }
                    }
                ), in: -0.5...0.5, step: 0.05)
                .tint(.purple)
            }
            
            Button {
                dataManager.statusMinimizedXPosition = 0.0
                dataManager.statusMinimizedYPosition = -0.3
                previewStatusPosition = (x: 0.0, y: -0.3)
                previewStatusActive = true
                hidePreviewTask?.cancel()
                hidePreviewTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !Task.isCancelled {
                        previewStatusPosition = nil
                        previewStatusActive = false
                    }
                }
            } label: {
                Text("Reset")
                    .font(.caption2)
                    .foregroundColor(.purple)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Position & Layout Panel (Combined)
    
    private var positionLayoutPanelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section 1: Video Plane Position
            VStack(alignment: .leading, spacing: 10) {
                // Section header
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.blue)
                    Text("Video Plane")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                
                // Size control
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Size")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                        Text("\(Int(dataManager.videoPlaneScale * 100))%")
                            .font(.caption)
                            .foregroundColor(.white)
                            .monospacedDigit()
                    }
                    
                    Slider(value: Binding(
                        get: { dataManager.videoPlaneScale },
                        set: { newValue in
                            dataManager.videoPlaneScale = newValue
                            previewActive = true
                            hidePreviewTask?.cancel()
                            hidePreviewTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                if !Task.isCancelled { previewActive = false }
                            }
                        }
                    ), in: 0.5...2.0, step: 0.1)
                    .tint(.purple)
                }
                
                // Distance control
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Distance")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                        Text("\(String(format: "%.1f", -dataManager.videoPlaneZDistance))m")
                            .font(.caption)
                                .foregroundColor(.white)
                                .monospacedDigit()
                        }
                        
                        Slider(value: Binding(
                            get: { -dataManager.videoPlaneZDistance },
                            set: { positiveValue in
                                let negativeValue = -positiveValue
                                dataManager.videoPlaneZDistance = negativeValue
                                previewZDistance = negativeValue
                                hidePreviewTask?.cancel()
                                hidePreviewTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                                    if !Task.isCancelled { previewZDistance = nil }
                                }
                            }
                        ), in: 2.0...20.0, step: 0.5)
                        .tint(.blue)
                    }
                    
                    // Height control
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Height")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                            Spacer()
                            Text("\(String(format: "%.2f", dataManager.videoPlaneYPosition))m")
                                .font(.caption)
                                .foregroundColor(.white)
                                .monospacedDigit()
                        }
                        
                        Slider(value: Binding(
                            get: { dataManager.videoPlaneYPosition },
                            set: { newValue in
                                dataManager.videoPlaneYPosition = newValue
                                previewActive = true
                                hidePreviewTask?.cancel()
                                hidePreviewTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                                    if !Task.isCancelled { previewActive = false }
                                }
                            }
                        ), in: -2.0...2.0, step: 0.1)
                        .tint(.green)
                    }
                    
                    // Lock to world toggle
                    HStack {
                        Text("Lock To World")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Toggle("", isOn: $videoFixed)
                            .labelsHidden()
                            .tint(.orange)
                    }
                    
                    // Action buttons
                    HStack(spacing: 8) {
                        Button {
                            withAnimation { videoMinimized.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: videoMinimized ? "eye.fill" : "eye.slash.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text(videoMinimized ? "Show" : "Hide")
                                    .font(.caption2)
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            dataManager.videoPlaneZDistance = -10.0
                            dataManager.videoPlaneYPosition = 0.0
                            dataManager.videoPlaneAutoPerpendicular = false
                            previewZDistance = -10.0
                            previewActive = true
                            hidePreviewTask?.cancel()
                            hidePreviewTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                if !Task.isCancelled {
                                    previewZDistance = nil
                                    previewActive = false
                                }
                            }
                        } label: {
                            Text("Reset")
                                .font(.caption2)
                                .foregroundColor(.blue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.15))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)
                
                // Section 2: Controller Position
                VStack(alignment: .leading, spacing: 10) {
                    // Section header
                    HStack(spacing: 8) {
                        Image(systemName: "move.3d")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.purple)
                        Text("Controller")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    
                    Text("Adjust where the minimized control buttons appear in your view.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                    
                    // X position control
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("X (Left-Right)")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                            Spacer()
                            Text("\(String(format: "%.2f", dataManager.statusMinimizedXPosition))m")
                                .font(.caption)
                                .foregroundColor(.white)
                                .monospacedDigit()
                        }
                        
                        Slider(value: Binding(
                            get: { dataManager.statusMinimizedXPosition },
                            set: { newValue in
                                dataManager.statusMinimizedXPosition = newValue
                                previewStatusPosition = (x: newValue, y: dataManager.statusMinimizedYPosition)
                                previewStatusActive = true
                                hidePreviewTask?.cancel()
                                hidePreviewTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                                    if !Task.isCancelled {
                                        previewStatusPosition = nil
                                        previewStatusActive = false
                                    }
                                }
                            }
                        ), in: -0.5...0.5, step: 0.05)
                        .tint(.purple)
                    }
                    
                    // Y position control
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Y (Up-Down)")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                            Spacer()
                            Text("\(String(format: "%.2f", dataManager.statusMinimizedYPosition))m")
                                .font(.caption)
                                .foregroundColor(.white)
                                .monospacedDigit()
                        }
                        
                        Slider(value: Binding(
                            get: { dataManager.statusMinimizedYPosition },
                            set: { newValue in
                                dataManager.statusMinimizedYPosition = newValue
                                previewStatusPosition = (x: dataManager.statusMinimizedXPosition, y: newValue)
                                previewStatusActive = true
                                hidePreviewTask?.cancel()
                                hidePreviewTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                                    if !Task.isCancelled {
                                        previewStatusPosition = nil
                                        previewStatusActive = false
                                    }
                                }
                            }
                        ), in: -0.5...0.5, step: 0.05)
                        .tint(.purple)
                    }
                    
                    Button {
                        dataManager.statusMinimizedXPosition = 0.0
                        dataManager.statusMinimizedYPosition = -0.3
                        previewStatusPosition = (x: 0.0, y: -0.3)
                        previewStatusActive = true
                        hidePreviewTask?.cancel()
                        hidePreviewTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if !Task.isCancelled {
                                previewStatusPosition = nil
                                previewStatusActive = false
                            }
                        }
                    } label: {
                        Text("Reset")
                            .font(.caption2)
                            .foregroundColor(.purple)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(10)
            }
    }
    
    // MARK: - Visualizations Panel
    
    private var visualizationsPanelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Description
            Text("Control what visual elements are rendered in the immersive space.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Show Hands toggle
            visualizationToggleRow(
                icon: dataManager.upperLimbVisible ? "hand.raised.fill" : "hand.raised.slash.fill",
                title: "Hands Over AR",
                description: "When enabled, your real hands appear on top of all AR content (video, 3D models). When disabled, hands are hidden behind AR objects.",
                isOn: $dataManager.upperLimbVisible,
                accentColor: .cyan
            )
            
            Divider()
                .background(Color.white.opacity(0.15))
            
            // Head Beam toggle
            visualizationToggleRow(
                icon: dataManager.showHeadBeam ? "rays" : "circle.dashed",
                title: "Head Gaze Ray",
                description: "Projects a ray from your head showing where you're looking. Helpful for debugging head tracking or aiming at objects.",
                isOn: $dataManager.showHeadBeam,
                accentColor: .yellow
            )
            
            Divider()
                .background(Color.white.opacity(0.15))
            
            // Hand Joints toggle
            visualizationToggleRow(
                icon: dataManager.showHandJoints ? "circle.grid.3x3.fill" : "circle.grid.3x3",
                title: "Hand Tracking",
                description: "Shows small spheres at each of the 27 tracked hand joints. Useful for debugging finger tracking accuracy.",
                isOn: $dataManager.showHandJoints,
                accentColor: .orange
            )
            
            // Hand Joints Opacity slider (always shown, disabled when hand tracking is off)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(dataManager.showHandJoints ? .orange.opacity(0.7) : .white.opacity(0.3))
                        .frame(width: 28)
                    
                    Text("Skeleton Opacity")
                        .font(.subheadline)
                        .foregroundColor(dataManager.showHandJoints ? .white.opacity(0.9) : .white.opacity(0.4))
                    
                    Spacer()
                    
                    Text("\(Int(dataManager.handJointsOpacity * 100))%")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(dataManager.showHandJoints ? .orange : .white.opacity(0.3))
                        .frame(width: 50, alignment: .trailing)
                }
                
                Slider(
                    value: Binding(
                        get: { Double(dataManager.handJointsOpacity) },
                        set: { dataManager.handJointsOpacity = Float($0) }
                    ),
                    in: 0.1...1.0,
                    step: 0.05
                )
                .tint(dataManager.showHandJoints ? .orange : .gray)
                .disabled(!dataManager.showHandJoints)
                .frame(height: 30)
                .padding(.leading, 36)
            }
            .padding(.top, 8)
            .opacity(dataManager.showHandJoints ? 1.0 : 0.5)
        }
    }
    
    private func visualizationToggleRow(icon: String, title: String, description: String, isOn: Binding<Bool>, accentColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isOn.wrappedValue ? accentColor : .white.opacity(0.4))
                    .frame(width: 28)
                
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Spacer()
                
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .tint(accentColor)
            }
            
            Text(description)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Hand Tracking Panel
    
    private var handTrackingPanelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Description
            Text("Configure hand tracking settings. Enable skeleton overlay and adjust prediction to reduce perceived latency.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Enable Skeleton Overlay toggle
            Toggle(isOn: $dataManager.showHandJoints) {
                HStack(spacing: 10) {
                    Image(systemName: dataManager.showHandJoints ? "hand.raised.fingers.spread.fill" : "hand.raised.fingers.spread")
                        .font(.system(size: 18))
                        .foregroundColor(dataManager.showHandJoints ? .orange : .white.opacity(0.6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Skeleton Overlay")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                        Text("Visualize 27 hand joints as spheres with bone connections")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .tint(.orange)
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Prediction offset section
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 18))
                        .foregroundColor(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prediction Offset")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                        Text("Query predicted hand poses ahead of time")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Text("\(Int(dataManager.handPredictionOffset * 1000)) ms")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.cyan)
                        .monospacedDigit()
                }
                
                Slider(
                    value: $dataManager.handPredictionOffset,
                    in: 0.0...0.1,
                    step: 0.005
                )
                .tint(.cyan)
                
                // Explanation
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundColor(.cyan.opacity(0.8))
                        Text("How it works")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    Text("Uses ARKit's handAnchors(at:) API to query predicted hand poses at a future timestamp. This compensates for system latency, making the skeleton feel more responsive.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                        .lineSpacing(2)
                    
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("0 ms")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.white.opacity(0.7))
                            Text("No prediction")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.4))
                        }
                        Spacer()
                        VStack(alignment: .center, spacing: 2) {
                            Text("33 ms")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.cyan)
                            Text("Recommended")
                                .font(.caption2)
                                .foregroundColor(.cyan.opacity(0.7))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("100 ms")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                            Text("May overshoot")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
                .padding(12)
                .background(Color.cyan.opacity(0.1))
                .cornerRadius(10)
            }
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Opacity slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 16))
                        .foregroundColor(.orange.opacity(0.8))
                    Text("Skeleton Opacity")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(Int(dataManager.handJointsOpacity * 100))%")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                }
                
                Slider(
                    value: $dataManager.handJointsOpacity,
                    in: 0.1...1.0,
                    step: 0.05
                )
                .tint(.orange)
            }
        }
    }
    
    // MARK: - Stereo Baseline Panel
    
    private var stereoBaselinePanelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Description
            Text("Adjust stereo baseline to match your IPD. This works by asymmetrically cropping the left and right views.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Baseline offset slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Baseline Adjustment")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    Spacer()
                    let offsetPercent = dataManager.stereoBaselineOffset * 100
                    Text(abs(offsetPercent) < 0.05 ? "Default" : String(format: "%+.1f%%", offsetPercent))
                        .font(.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                
                Slider(value: $dataManager.stereoBaselineOffset, in: -0.20...0.20, step: 0.001)
                    .tint(.indigo)
                
                // Explanation
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("← Narrower")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                        Text("For wider IPD")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Wider →")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.cyan)
                        Text("For narrower IPD")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            
            // Baseline Reset button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    dataManager.stereoBaselineOffset = 0.0
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .bold))
                    Text("Reset to Default")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.15))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(abs(dataManager.stereoBaselineOffset) < 0.0005)
            .opacity(abs(dataManager.stereoBaselineOffset) < 0.0005 ? 0.5 : 1.0)
        }
    }
    
    // MARK: - Marker Detection Panel
    
    @ObservedObject private var markerDetectionManager = MarkerDetectionManager.shared
    
    private var markerDetectionPanelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Description
            Text("Detect ArUco markers and stream their world poses to Python. Enable to track printed markers with your Vision Pro camera.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Enable toggle
            Toggle(isOn: $markerDetectionManager.isEnabled) {
                HStack(spacing: 8) {
                    Image(systemName: markerDetectionManager.isEnabled ? "viewfinder.circle.fill" : "viewfinder.circle")
                        .font(.system(size: 16))
                        .foregroundColor(markerDetectionManager.isEnabled ? .green : .white.opacity(0.6))
                    Text("Enable Detection")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
            }
            .tint(.green)
            
            // Status
            if markerDetectionManager.isEnabled {
                HStack(spacing: 8) {
                    Circle()
                        .fill(markerDetectionManager.detectedMarkers.isEmpty ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(markerDetectionManager.statusMessage)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)
            }
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Marker size slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Expected Marker Size")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.0f cm", markerDetectionManager.markerSizeMeters * 100))
                        .font(.caption)
                        .foregroundColor(.orange)
                        .monospacedDigit()
                }
                
                Slider(value: $markerDetectionManager.markerSizeMeters, in: 0.02...0.50, step: 0.01)
                    .tint(.orange)
                
                Text("Set this to match your printed marker's physical size for best tracking accuracy.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
            
            // Detected markers list with estimated size
            if !markerDetectionManager.detectedMarkers.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.2))
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Detected Markers")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.7))
                    
                    ForEach(Array(markerDetectionManager.detectedMarkers.keys.sorted()), id: \.self) { markerId in
                        if let marker = markerDetectionManager.detectedMarkers[markerId] {
                            HStack(spacing: 12) {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: 14))
                                    .foregroundColor(.orange)
                                Text("ID \(markerId)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                                Spacer()
                                Text(String(format: "~%.1f cm", marker.estimatedSizeMeters * 100))
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Custom Images section
            customImagesSection
        }
    }
    
    // MARK: - USDZ Cache Panel Content
    
    private var usdzCachePanelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            let cacheManager = UsdzCacheManager.shared
            
            // Description
            Text("Cached USDZ scenes are reused when connecting to the same MuJoCo/Isaac sim scene, speeding up reconnection.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Cache stats
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cached Files")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                    Text("\(cacheManager.getCachedFiles().count)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Total Size")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                    Text(cacheManager.formattedCacheSize)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.purple)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.1))
            .cornerRadius(8)
            
            // Cached files list
            let cachedFiles = cacheManager.getCachedFiles()
            if !cachedFiles.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.2))
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cached Scenes")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.7))
                    
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(cachedFiles, id: \.cacheKey) { fileInfo in
                                HStack(spacing: 12) {
                                    Image(systemName: "cube.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.purple)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(fileInfo.filename)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        
                                        let sizeStr = fileInfo.size > 1024 * 1024 
                                            ? String(format: "%.1f MB", Double(fileInfo.size) / 1024 / 1024)
                                            : String(format: "%.0f KB", Double(fileInfo.size) / 1024)
                                        Text(sizeStr)
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                    
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Clear cache button
            Button {
                cacheManager.clearCache()
            } label: {
                HStack {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14))
                    Text("Clear All Cache")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(cachedFiles.isEmpty ? Color.white.opacity(0.1) : Color.red.opacity(0.3))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(cachedFiles.isEmpty)
            .opacity(cachedFiles.isEmpty ? 0.5 : 1.0)
            
            Text("Clearing the cache will force re-download of scenes on next connection.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
        }
    }
    
    // MARK: - Accessory Tracking Panel Content (visionOS 26+)
    
    @available(visionOS 26.0, *)
    private var accessoryTrackingPanelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            let accessoryManager = AccessoryTrackingManager.shared
            
            // Description
            Text("Track spatial stylus (Apple Pencil Pro) and visualize its pose in 3D.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Enable toggle
            Toggle(isOn: Binding(
                get: { accessoryManager.isEnabled },
                set: { accessoryManager.isEnabled = $0 }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: accessoryManager.isEnabled ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                        .font(.system(size: 16))
                        .foregroundColor(accessoryManager.isEnabled ? .green : .white.opacity(0.6))
                    Text("Enable Tracking")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
            }
            .tint(.green)
            
            // Status
            HStack(spacing: 8) {
                Circle()
                    .fill(accessoryManager.isTrackingActive ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(accessoryManager.statusMessage)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                
                // Refresh button
                Button {
                    accessoryManager.refreshStyluses()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.1))
            .cornerRadius(8)
            
            // Available styluses for selection
            if !accessoryManager.availableStyluses.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.2))
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Styluses")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.7))
                    
                    ForEach(accessoryManager.availableStyluses) { stylus in
                        Button {
                            accessoryManager.toggleStylus(id: stylus.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: stylus.isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(stylus.isSelected ? .cyan : .white.opacity(0.4))
                                Image(systemName: "pencil.tip")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.7))
                                Text(stylus.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(stylus.isSelected ? Color.cyan.opacity(0.15) : Color.white.opacity(0.05))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // Currently tracking
            if accessoryManager.stylusAnchorEntity != nil {
                Divider()
                    .background(Color.white.opacity(0.2))
                
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Stylus anchor active")
                        .font(.caption)
                        .foregroundColor(.white)
                    Spacer()
                    Text("Tracking")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.05))
                .cornerRadius(6)
            }
            
            // Note
            Divider()
                .background(Color.white.opacity(0.2))
            
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                Text("visionOS 26.0+ and Apple Pencil Pro required")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
    
    // MARK: - Custom Images Section
    
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var editingCustomImageId: String? = nil
    @State private var editingCustomImageName: String = ""
    @State private var editingCustomImageWidth: Float = 0.1
    
    @ViewBuilder
    private var customImagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with add buttons
            HStack {
                Text("Custom Images")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.7))
                
                Spacer()
                
                // Add from Photos
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 12))
                        Text("Photos")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.3))
                    .cornerRadius(6)
                    .foregroundColor(.blue)
                }
                .onChange(of: selectedPhotoItem) { oldItem, newItem in
                    Task {
                        if let item = newItem,
                           let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            await MainActor.run {
                                let name = "Image \(CustomImageStorage.shared.registrations.count + 1)"
                                _ = CustomImageStorage.shared.registerImage(image, name: name)
                            }
                        }
                        selectedPhotoItem = nil
                    }
                }
                
                // Add from Files
                Button {
                    showingFileImporter = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12))
                        Text("Files")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.3))
                    .cornerRadius(6)
                    .foregroundColor(.purple)
                }
            }
            
            // Registered images list
            let registrations = CustomImageStorage.shared.registrations
            if registrations.isEmpty {
                Text("No custom images registered. Add images to track any picture in your environment.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.vertical, 8)
            } else {
                ForEach(registrations) { registration in
                    customImageRow(registration: registration)
                }
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first,
                   url.startAccessingSecurityScopedResource(),
                   let data = try? Data(contentsOf: url),
                   let image = UIImage(data: data) {
                    let name = url.deletingPathExtension().lastPathComponent
                    _ = CustomImageStorage.shared.registerImage(image, name: name)
                    url.stopAccessingSecurityScopedResource()
                }
            case .failure(let error):
                dlog("❌ [StatusView] File import failed: \(error)")
            }
        }
    }
    
    @ViewBuilder
    private func customImageRow(registration: CustomImageRegistration) -> some View {
        let isTracked = markerDetectionManager.trackedCustomImages[registration.id] != nil ||
                        markerDetectionManager.fixedCustomImages[registration.id] != nil
        
        HStack(spacing: 10) {
            // Thumbnail
            if let thumbnail = CustomImageStorage.shared.loadThumbnail(for: registration, size: CGSize(width: 40, height: 40)) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isTracked ? Color.green : Color.white.opacity(0.2), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    )
            }
            
            // Name and size (editable)
            VStack(alignment: .leading, spacing: 2) {
                Text(registration.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Text(String(format: "%.0f cm", registration.physicalWidthMeters * 100))
                        .font(.caption2)
                        .foregroundColor(.cyan)
                    
                    if isTracked {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Tracking")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }
            
            Spacer()
            
            // Edit button
            Button {
                editingCustomImageId = registration.id
                editingCustomImageName = registration.name
                editingCustomImageWidth = registration.physicalWidthMeters
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            
            // Delete button
            Button {
                CustomImageStorage.shared.unregisterImage(id: registration.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
        .sheet(isPresented: Binding(
            get: { editingCustomImageId == registration.id },
            set: { if !$0 { editingCustomImageId = nil } }
        )) {
            customImageEditSheet(registration: registration)
        }
    }
    
    @ViewBuilder
    private func customImageEditSheet(registration: CustomImageRegistration) -> some View {
        NavigationView {
            Form {
                Section("Image Name") {
                    TextField("Name", text: $editingCustomImageName)
                }
                
                Section("Physical Width") {
                    HStack {
                        Slider(value: $editingCustomImageWidth, in: 0.02...0.50, step: 0.01)
                        Text(String(format: "%.0f cm", editingCustomImageWidth * 100))
                            .frame(width: 60)
                            .monospacedDigit()
                    }
                    Text("Enter the real-world width of this image for accurate tracking.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Edit Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        editingCustomImageId = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        CustomImageStorage.shared.updateRegistration(
                            id: registration.id,
                            name: editingCustomImageName,
                            physicalWidth: editingCustomImageWidth
                        )
                        editingCustomImageId = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
}

/// Preview view that looks exactly like the minimized status but with 50% opacity
struct StatusPreviewView: View {
    let showVideoStatus: Bool
    let videoFixed: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            // Expand button (non-functional in preview)
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 60, height: 60)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }
            
            // Recording button (non-functional in preview)
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.6))
                    .frame(width: 60, height: 60)
                Circle()
                    .fill(Color.white)
                    .frame(width: 24, height: 24)
            }
            
            // Video minimize/maximize button (only show if video streaming mode is enabled)
            if showVideoStatus {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.8))
                        .frame(width: 60, height: 60)
                    Image(systemName: "video.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                }
            
                ZStack {
                    Circle()
                        .fill(videoFixed ? Color.orange.opacity(0.8) : Color.white.opacity(0.3))
                        .frame(width: 60, height: 60)
                    Image(systemName: videoFixed ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            
            // Close button (non-functional in preview)
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 60, height: 60)
                Text("✕")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding(30)
        .background(Color.black.opacity(0.6))
        .cornerRadius(36)
        .fixedSize()
        .opacity(0.5)  // 50% transparent
    }
}

// MARK: - Debug Info Row Helper

struct DebugInfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.caption2)
                .foregroundColor(.white)
                .fontWeight(.medium)
        }
    }
}

/// Creates a floating status entity that follows the head
func createStatusEntity() -> Entity {
    let statusEntity = Entity()
    statusEntity.name = "statusDisplay"
    return statusEntity
}
