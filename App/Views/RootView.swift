import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem { Label("Measure", systemImage: "scope") }
            HistoryView()
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
            ValidationView()
                .tabItem { Label("Validate", systemImage: "checkmark.seal") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
