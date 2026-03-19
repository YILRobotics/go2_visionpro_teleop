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
    @State private var didAutoLaunch = false

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .task {
                guard !didAutoLaunch else { return }
                didAutoLaunch = true
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
