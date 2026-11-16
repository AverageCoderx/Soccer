import KickMetricsCore
import SwiftData
import SwiftUI

/// Accuracy checks: drop tests (scale against gravity) and radar comparisons.
/// The app makes no accuracy claim beyond what these show.
struct ValidationView: View {
    @Query(sort: \ShotRecord.date, order: .reverse) private var records: [ShotRecord]
    @State private var selected: ShotRecord?

    private var drops: [ShotRecord] {
        records.filter { $0.kind == .dropTest && $0.isMeasured && $0.measuredGravity != nil }
    }

    private var radarShots: [ShotRecord] {
        records.filter { $0.kind == .shot && $0.isMeasured && $0.referenceMPH != nil && $0.maxSpeed != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    dropCard
                    radarCard
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Validate")
            .sheet(item: $selected) { record in
                NavigationStack { ResultView(record: record) }
            }
        }
    }

    // MARK: Drop tests

    private var dropCard: some View {
        Card {
            Text("Drop test (scale check)").font(.headline)
            Text("Tripod side-on, 4–8 m away. On Measure, choose Drop test. Hold the ball still at head height, tap it, press Start, then let go without pushing. The app measures the fall's acceleration using only the ball's size as a ruler. It should be 9.81 m/s². Any difference is the app's distance scale error, which applies to speeds too.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if drops.isEmpty {
                Text("No drop tests yet.").foregroundStyle(.secondary)
            } else {
                let errors = drops.compactMap { $0.measuredGravity.map { $0 / 9.81 - 1 } }
                let mean = errors.reduce(0, +) / Double(errors.count)
                let sd = errors.count > 1
                    ? (errors.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(errors.count - 1)).squareRoot()
                    : 0
                HStack {
                    Text("Average scale error").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.1f%%", mean * 100)).font(.title3.weight(.bold)).monospacedDigit()
                }
                if errors.count > 1 {
                    Text(String(format: "%d drops · spread ±%.1f%% · average uncertain by ±%.1f%%",
                                errors.count, sd * 100, sd / Double(errors.count).squareRoot() * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Do a few more drops for a reliable average.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(drops) { r in
                    Button { selected = r } label: {
                        HStack {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            Spacer()
                            Text(String(format: "%.2f ± %.2f m/s²", r.measuredGravity ?? 0, r.gravitySigma ?? 0))
                                .font(.caption.monospacedDigit())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Radar

    private var radarCard: some View {
        Card {
            Text("Radar comparison").font(.headline)
            Text("Put the radar behind the ball, aimed straight along the shot; radar guns read low when off to the side. After each shot, enter the radar's reading on the result screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let samples = radarShots.compactMap { r -> ValidationSample? in
                guard let ref = r.referenceMPH, let max = r.maxSpeed else { return nil }
                return ValidationSample(reference: ref, measured: max.mph)
            }
            if let summary = ValidationSummary(samples) {
                statRow("Shots compared", "\(summary.count)")
                statRow("Average difference (bias)", String(format: "%+.2f mph", summary.meanError))
                statRow("Typical error (mean absolute)", String(format: "%.2f mph · %.1f%%", summary.meanAbsoluteError, summary.meanAbsolutePercentError))
                statRow("RMS error", String(format: "%.2f mph", summary.rootMeanSquareError))
                statRow("Worst", String(format: "%.1f%%", summary.maxAbsolutePercentError))
                if summary.count >= 2 {
                    statRow("95% limits of agreement", String(format: "%+.1f to %+.1f mph",
                                                            summary.limitsOfAgreement.lowerBound, summary.limitsOfAgreement.upperBound))
                }
                Text(summary.count < 10
                     ? "Fewer than 10 comparisons: too few to judge accuracy yet."
                     : (summary.meanAbsolutePercentError < 5 ? "Mean error is under 5% in these conditions." : "Mean error is 5% or more in these conditions."))
                    .font(.caption.weight(.semibold))
                ForEach(radarShots) { r in
                    Button { selected = r } label: {
                        HStack {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            Spacer()
                            Text(String(format: "app %.1f · radar %.1f mph", r.maxSpeed?.mph ?? 0, r.referenceMPH ?? 0))
                                .font(.caption.monospacedDigit())
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No radar readings entered yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }
}
