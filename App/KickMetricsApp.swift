import SwiftData
import SwiftUI

@main
struct KickMetricsApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(for: ShotRecord.self)
    }
}
