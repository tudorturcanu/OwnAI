import SwiftUI

@main
struct LocalAIWatchApp: App {
    @State private var connectivityClient = WatchConnectivityClient()

    var body: some Scene {
        WindowGroup {
            WatchAppView()
                .environment(connectivityClient)
        }
    }
}
