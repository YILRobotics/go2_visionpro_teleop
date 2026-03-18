import SwiftUI

@main
struct Go2TeleopVisionApp: App {
    @StateObject private var viewModel = TeleopViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 1100, minHeight: 720)
        }
    }
}
