import Foundation
import SwiftUI
#if canImport(Darwin)
import Darwin
#endif

@MainActor
final class TeleopViewModel: ObservableObject {
    @Published var websocketURLString: String = "ws://127.0.0.1:8765/ws" {
        didSet { UserDefaults.standard.set(websocketURLString, forKey: Self.websocketURLKey) }
    }
    @Published var snapshotURLString: String = "http://127.0.0.1:8080/snapshot.jpg" {
        didSet { UserDefaults.standard.set(snapshotURLString, forKey: Self.snapshotURLKey) }
    }
    @Published var handSendRateHz: Double = 30.0
    @Published var snapshotRateHz: Double = 15.0
    @Published var roomCode: String = ""
    @Published var isRoomCodeLocked: Bool = false {
        didSet {
            UserDefaults.standard.set(isRoomCodeLocked, forKey: Self.roomCodeLockedKey)
            if isRoomCodeLocked {
                UserDefaults.standard.set(roomCode, forKey: Self.roomCodeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.roomCodeKey)
            }
        }
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isStarting: Bool = false
    @Published private(set) var statusText: String = "Idle"
    @Published private(set) var errorText: String?
    @Published private(set) var latestSample: HandSample = .invalid
    @Published private(set) var cameraImage: PlatformImage?
    @Published private(set) var packetCount: Int = 0
    @Published private(set) var localIPAddresses: [(name: String, address: String)] = []
    @Published private(set) var backendReachable: Bool = false

    let handTrackingService = HandTrackingService()

    private let socketClient = TeleopSocketClient()
    private var sendLoopTask: Task<Void, Never>?
    private var snapshotLoopTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    private static let websocketURLKey = "go2teleop.websocketURL"
    private static let snapshotURLKey = "go2teleop.snapshotURL"
    private static let roomCodeKey = "go2teleop.roomCode"
    private static let roomCodeLockedKey = "go2teleop.roomCodeLocked"

    init() {
        loadPersistedSettings()
        refreshLocalNetworkInfo()
        startBackgroundMonitoring()
    }

    func start() async {
        guard !isRunning, !isStarting else { return }

        guard let wsURL = URL(string: websocketURLString) else {
            errorText = "Invalid websocket URL."
            return
        }
        guard let snapshotURL = URL(string: snapshotURLString) else {
            errorText = "Invalid snapshot URL."
            return
        }
        if let endpointValidationError = validateEndpointHosts(wsURL: wsURL, snapshotURL: snapshotURL) {
            errorText = endpointValidationError
            statusText = "Idle"
            return
        }

        isStarting = true
        errorText = nil
        packetCount = 0
        statusText = "Connecting..."

        do {
            try await socketClient.connect(to: wsURL)
        } catch {
            errorText = "WebSocket connect failed: \(error.localizedDescription)"
            statusText = "Disconnected"
            isStarting = false
            return
        }

        handTrackingService.start()
        isRunning = true
        statusText = "Connected"
        isStarting = false

        startSendLoop()
        startSnapshotLoop(snapshotURL: snapshotURL)
    }

    func stop() {
        guard isRunning || isStarting else { return }

        sendLoopTask?.cancel()
        sendLoopTask = nil
        snapshotLoopTask?.cancel()
        snapshotLoopTask = nil

        Task {
            await socketClient.disconnect()
        }
        handTrackingService.stop()

        isRunning = false
        isStarting = false
        statusText = "Idle"
    }

    func generateRoomCode() {
        let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ"
        let numbers = "0123456789"
        let letterPart = String((0..<4).map { _ in letters.randomElement() ?? "A" })
        let numberPart = String((0..<4).map { _ in numbers.randomElement() ?? "0" })
        roomCode = "\(letterPart)-\(numberPart)"
        if isRoomCodeLocked {
            UserDefaults.standard.set(roomCode, forKey: Self.roomCodeKey)
        }
    }

    private func startSendLoop() {
        sendLoopTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0

            while !Task.isCancelled {
                let sample = handTrackingService.latestSample
                latestSample = sample
                if sample.isTracked {
                    do {
                        try await socketClient.send(TeleopOutboundPacket(sample: sample))
                        packetCount += 1
                        consecutiveFailures = 0
                    } catch {
                        consecutiveFailures += 1
                        if consecutiveFailures >= 3 {
                            await handleTransportFailure(message: "WebSocket send failed: \(error.localizedDescription)")
                            return
                        }
                    }
                }

                let periodNs = UInt64(1_000_000_000.0 / max(handSendRateHz, 1.0))
                try? await Task.sleep(nanoseconds: periodNs)
            }
        }
    }

    private func startSnapshotLoop(snapshotURL: URL) {
        snapshotLoopTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0

            while !Task.isCancelled {
                do {
                    let (data, response) = try await URLSession.shared.data(from: snapshotURL)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse)
                    }
                    if let image = decodePlatformImage(from: data) {
                        cameraImage = image
                        backendReachable = true
                        consecutiveFailures = 0
                    } else {
                        consecutiveFailures += 1
                    }
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 10 {
                        errorText = "Camera snapshot fetch failing (\(consecutiveFailures) consecutive errors)."
                    }
                }

                let periodNs = UInt64(1_000_000_000.0 / max(snapshotRateHz, 1.0))
                try? await Task.sleep(nanoseconds: periodNs)
            }
        }
    }

    private func handleTransportFailure(message: String) async {
        errorText = message
        sendLoopTask?.cancel()
        sendLoopTask = nil
        snapshotLoopTask?.cancel()
        snapshotLoopTask = nil
        await socketClient.disconnect()
        handTrackingService.stop()
        isRunning = false
        isStarting = false
        statusText = "Disconnected"
    }

    private func loadPersistedSettings() {
        if let ws = UserDefaults.standard.string(forKey: Self.websocketURLKey), !ws.isEmpty {
            websocketURLString = ws
        }
        if let snapshot = UserDefaults.standard.string(forKey: Self.snapshotURLKey), !snapshot.isEmpty {
            snapshotURLString = snapshot
        }

        isRoomCodeLocked = UserDefaults.standard.bool(forKey: Self.roomCodeLockedKey)
        if isRoomCodeLocked,
           let savedRoomCode = UserDefaults.standard.string(forKey: Self.roomCodeKey),
           !savedRoomCode.isEmpty {
            roomCode = savedRoomCode
        } else {
            generateRoomCode()
        }
    }

    private func startBackgroundMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                refreshLocalNetworkInfo()
                if !isRunning && !isStarting {
                    await refreshBackendReachability()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refreshBackendReachability() async {
        guard let snapshotURL = URL(string: snapshotURLString) else {
            backendReachable = false
            return
        }

        var request = URLRequest(url: snapshotURL)
        request.timeoutInterval = 1.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                backendReachable = (200..<300).contains(http.statusCode) || http.statusCode == 503
            } else {
                backendReachable = false
            }
        } catch {
            backendReachable = false
        }
    }

    private func refreshLocalNetworkInfo() {
        localIPAddresses = getIPAddresses()
    }

    private func validateEndpointHosts(wsURL: URL, snapshotURL: URL) -> String? {
        guard let wsHost = wsURL.host, let snapshotHost = snapshotURL.host else {
            return "WebSocket and snapshot URLs must include a host IP."
        }

        #if targetEnvironment(simulator)
        let allowLoopbackHosts = true
        #else
        let allowLoopbackHosts = false
        #endif

        if !allowLoopbackHosts {
            let blockedHosts: Set<String> = ["127.0.0.1", "localhost", "0.0.0.0", "::1", "::"]
            if blockedHosts.contains(wsHost.lowercased()) || blockedHosts.contains(snapshotHost.lowercased()) {
                return "On Vision Pro, use your Mac's LAN IP in both URLs (for example 192.168.x.x), not localhost/127.0.0.1/0.0.0.0."
            }
        }

        return nil
    }
}

private func getIPAddresses() -> [(name: String, address: String)] {
    var addresses: [(name: String, address: String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&ifaddr) == 0, let start = ifaddr else {
        return addresses
    }
    defer { freeifaddrs(ifaddr) }

    var ptr: UnsafeMutablePointer<ifaddrs>? = start
    while let interface = ptr?.pointee {
        defer { ptr = interface.ifa_next }

        guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
            continue
        }

        let name = String(cString: interface.ifa_name)
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

        guard result == 0 else { continue }

        let address = String(cString: host)
        if address != "127.0.0.1" {
            addresses.append((name, address))
        }
    }
    return addresses
}
