import SwiftData
import SwiftUI

@main
struct SoccerTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(for: ShotRecord.self)
    }
}
