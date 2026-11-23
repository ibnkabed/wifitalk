import SwiftUI

@main
struct WiFiTalkApp: App {
    @StateObject private var model = AppModel()

    init() {
        FirebaseHybrid.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environment(\.layoutDirection, Lang.isArabic ? .rightToLeft : .leftToRight)
                .tint(Color(red: 0.08, green: 0.58, blue: 0.72))
        }
    }
}
