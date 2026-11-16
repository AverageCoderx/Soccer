import KickMetricsCore
import SwiftData
import SwiftUI

struct ResultView: View {
    @Bindable var record: ShotRecord
    @AppStorage(SettingsKey.primaryUnit) private var unitRaw = SpeedUnit.mph.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var referenceText = ""
    @State private var confirmDelete = false

    private var unit: SpeedUnit { SpeedUnit(rawValue: unitRaw) ?? .mph }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if record.kind == .shot { shotResult } else { dropResult }
                if !record.warnings.isEmpty { warningsCard }
                if record.kind == .shot, record.isMeasured { referenceCard }
                detailsCard
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(record.kind == .shot ? "Shot" : "Drop test")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            if let ref = record.referenceMPH {
                referenceText = String(format: "%.1f", unit == .mph ? ref : ref * 1.609344)
            }
        }
        .confirmationDialog("Delete this shot and its recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        }
    }

    // MARK: Shot

    @ViewBuilder private var shotResult: some View {
        if record.isMeasured, let max = record.maxSpeed {
            Card {
                HStack {
                    Badge(text: "Measured", color: Theme.accent)
                    Spacer()
                    if let c = record.confidence { Badge(text: c.label, color: Theme.color(c)) }
                }
                Text("Top speed").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", max.value(in: unit)))
                        .font(.system(size: 72, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text(unit.label).font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(String(format: "± %.1f %@", max.uncertainty(in: unit), unit.label))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                let other: SpeedUnit = unit == .mph ? .kmh : .mph
                Text(String(format: "%.1f ± %.1f %@", max.value(in: other), max.uncertainty(in: other), other.label))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Card {
                row("Average over measured flight", record.averageSpeed.map { String(format: "%.1f ± %.1f %@", $0.value(in: unit), $0.uncertainty(in: unit), unit.label) } ?? "—")
                if let d = record.distanceMeters { row("Ball distance from camera", String(format: "%.1f m", d)) }
                if let a = record.outOfPlaneAngle { row("Angle toward/away from camera", String(format: "%.0f°", a)) }
                Text("± is one standard uncertainty (about 68% confidence). It includes pixel noise and the ball's size tolerance. The app hasn't yet been checked against a radar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            unavailableCard
        }
    }

    // MARK: Drop test

    @ViewBuilder private var dropResult: some View {
        if record.isMeasured, let g = record.measuredGravity, let s = record.gravitySigma {
            let error = (g / 9.81 - 1) * 100
            Card {
                Badge(text: "Scale check", color: Theme.accent)
                Text("Measured gravity").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.2f", g))
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("m/s²").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(String(format: "± %.2f m/s² · true value 9.81", s)).font(.headline).foregroundStyle(.secondary)
                Text(String(format: "Scale error %+.1f%% ± %.1f%%", error, s / 9.81 * 100))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(abs(error) <= 2 * s / 9.81 * 100 + 1 ? Theme.good : Theme.warn)
                Text("Speeds are scaled the same way as this measurement, so a scale error of +3% means speeds read about 3% high. Repeat a few drops and look at the average on the Validate tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            unavailableCard
        }
    }

    private var unavailableCard: some View {
        Card {
            Badge(text: "Not measured", color: Theme.warn)
            Text("This one couldn't be measured reliably, so no number is shown.")
                .font(.headline)
            ForEach(record.unavailableReasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if record.unavailableReasons.isEmpty {
                Text("No reason was recorded.").foregroundStyle(.secondary)
            }
        }
    }

    private var warningsCard: some View {
        Card {
            Text("Notes").font(.headline)
            ForEach(record.warnings, id: \.self) { w in
                Label(w, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Reference (radar)

    private var referenceCard: some View {
        Card {
            Text("Radar reading (optional)").font(.headline)
            Text("If a radar gun measured this shot, enter its reading. It's used on the Validate tab to work out the app's real accuracy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Reading", text: $referenceText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Text(unit.label).foregroundStyle(.secondary)
                Button("Save") { saveReference() }
                    .buttonStyle(.borderedProminent)
                    .disabled(Double(referenceText.replacingOccurrences(of: ",", with: ".")) == nil)
            }
            if let ref = record.referenceMPH, let max = record.maxSpeed {
                let error = (max.mph - ref) / ref * 100
                Text(String(format: "App vs radar: %+.1f%%", error))
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func saveReference() {
        guard let value = Double(referenceText.replacingOccurrences(of: ",", with: ".")), value > 0 else { return }
        record.referenceMPH = unit == .mph ? value : value / 1.609344
        try? modelContext.save()
    }

    // MARK: Details

    private var detailsCard: some View {
        Card {
            row("Recorded", record.date.formatted(date: .abbreviated, time: .shortened))
            row("Frame rate", "\(Int(record.frameRate)) fps")
            row("Ball", record.ballName)
            if let url = record.reportURL {
                NavigationLink {
                    DebugView(reportURL: url)
                } label: {
                    Label("Tracking details", systemImage: "waveform.path.ecg")
                }
            }
            HStack {
                if let url = record.reportURL, FileManager.default.fileExists(atPath: url.path) {
                    ShareLink(item: url) { Label("Share report", systemImage: "square.and.arrow.up") }
                }
                Spacer()
                if let url = record.clipURL, FileManager.default.fileExists(atPath: url.path) {
                    ShareLink(item: url) { Label("Share clip", systemImage: "film") }
                }
            }
            .font(.subheadline)
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .font(.subheadline)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func delete() {
        if let url = record.clipURL { try? FileManager.default.removeItem(at: url) }
        if let url = record.reportURL { try? FileManager.default.removeItem(at: url) }
        modelContext.delete(record)
        try? modelContext.save()
        dismiss()
    }
}
