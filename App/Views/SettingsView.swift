import KickMetricsCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.ballSize) private var ballSize = BallSizeOption.size5.rawValue
    @AppStorage(SettingsKey.measuredCircumferenceCM) private var circumference: Double = 0
    @AppStorage(SettingsKey.frameRate) private var frameRate: Double = 240
    @AppStorage(SettingsKey.primaryUnit) private var unitRaw = SpeedUnit.mph.rawValue
    @State private var circumferenceText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Ball size", selection: $ballSize) {
                        ForEach(BallSizeOption.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    HStack {
                        Text("Measured circumference")
                        Spacer()
                        TextField("optional", text: $circumferenceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .onSubmit(saveCircumference)
                        Text("cm").foregroundStyle(.secondary)
                    }
                    Button("Save circumference", action: saveCircumference)
                    if circumference > 0 {
                        Button("Clear measured circumference", role: .destructive) {
                            circumference = 0
                            circumferenceText = ""
                        }
                    }
                } header: {
                    Text("Ball")
                } footer: {
                    let spec = AppSettings.ballSpec()
                    Text(String(format: "Using %@: diameter %.1f cm ± %.1f%%. The ball's size is the app's ruler, so every 1%% error in it is 1%% in speed. A tape around the widest part gives the most accurate value.",
                                spec.name, spec.diameter * 100, spec.diameterRelativeSigma * 100))
                }

                Section {
                    Picker("Frame rate", selection: $frameRate) {
                        Text("240 fps (best)").tag(240.0)
                        Text("120 fps").tag(120.0)
                        Text("60 fps").tag(60.0)
                    }
                    Picker("Speed unit", selection: $unitRaw) {
                        ForEach(SpeedUnit.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } header: {
                    Text("Recording")
                }

                Section("How to get a good measurement") {
                    tip("Tripod", "Put the phone on a tripod in landscape, level, roughly side-on to the shot, 4–10 m from the ball.")
                    tip("Kick across the frame", "The shot should travel mostly across the picture. Shots aimed at the camera can't be measured precisely and are reported as unavailable.")
                    tip("Light", "Daylight is best. The app uses a very fast shutter to freeze the ball, which needs light.")
                    tip("Lock the ball", "Tap the ball on screen before pressing Start, and keep it still until the kick.")
                }

                Section("About these numbers") {
                    Text("Speeds come from fitting a physics model (gravity and air drag) to the ball's tracked path, with distance worked out from the ball's known size. Each result carries a ± uncertainty. When a shot can't be measured reliably, the app says so instead of showing a number. Accuracy hasn't yet been validated against a radar; use the Validate tab to check it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                circumferenceText = circumference > 0 ? String(format: "%.1f", circumference) : ""
            }
        }
    }

    private func saveCircumference() {
        let value = Double(circumferenceText.replacingOccurrences(of: ",", with: ".")) ?? 0
        circumference = (40...80).contains(value) ? value : 0
        if circumference == 0 { circumferenceText = "" }
    }

    private func tip(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
