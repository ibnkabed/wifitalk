import SwiftUI

@main
struct WiFiTalkApp: App {
    @StateObject private var model = AppModel()

    init() {
        TestHooks.seedDemoSnippets()
        FirebaseHybrid.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environment(\.layoutDirection, .leftToRight)
                .tint(Color(red: 0.08, green: 0.58, blue: 0.72))
        }
    }
}
