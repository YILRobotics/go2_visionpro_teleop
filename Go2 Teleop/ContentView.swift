import SwiftUI

func dlog(_ msg: @autoclosure () -> String) {
    #if DEBUG
    print(msg())
    #endif
}

struct ContentView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    @ObservedObject private var signalingClient = SignalingClient.shared

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Go2 Teleop")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.white)

                Text("Vision Pro Teleoperation")
                    .font(.title)
                    .foregroundColor(.white.opacity(0.75))
            }

            Text("Local recording mode")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))

            Button {
                proceedToImmersiveSpace()
            } label: {
                Text("START")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                    .frame(width: 220, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.blue)
                    )
            }
            .buttonStyle(.plain)

            if signalingClient.isConnected, !signalingClient.roomCode.isEmpty {
                Text("Room Code: \(signalingClient.roomCode)")
                    .font(.callout.monospaced())
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func proceedToImmersiveSpace() {
        Task {
            signalingClient.connect()
            DataManager.shared.crossNetworkRoomCode = signalingClient.roomCode

            await openImmersiveSpace(id: "combinedStreamSpace")
            dismissWindow()
        }
    }
}
