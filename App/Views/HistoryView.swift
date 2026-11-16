import Charts
import KickMetricsCore
import SwiftData
import SwiftUI

struct HistoryView: View {
    enum Range: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", all = "All"
        var id: String { rawValue }
        var start: Date? {
            switch self {
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: .now)
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: .now)
            case .all: return nil
            }
        }
    }

    @Query(sort: \ShotRecord.date, order: .reverse) private var records: [ShotRecord]
    @AppStorage(SettingsKey.primaryUnit) private var unitRaw = SpeedUnit.mph.rawValue
    @State private var range: Range = .all
    @State private var selected: ShotRecord?

    private var unit: SpeedUnit { SpeedUnit(rawValue: unitRaw) ?? .mph }

    private var shots: [ShotRecord] {
        records.filter { r in r.kind == .shot && (range.start.map { r.date >= $0 } ?? true) }
    }

    private var measured: [ShotRecord] { shots.filter { $0.isMeasured && $0.maxSpeed != nil } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if shots.isEmpty {
                        Card {
                            Text("No shots yet").font(.headline)
                            Text("Shots you measure appear here, with your personal best and progress over time.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        summary
                        if measured.count >= 2 { chart }
                        list
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("History")
            .sheet(item: $selected) { record in
                NavigationStack { ResultView(record: record) }
            }
        }
    }

    private var summary: some View {
        let speeds = measured.compactMap(\.maxSpeed)
        let best = speeds.max { $0.metersPerSecond < $1.metersPerSecond }
        let average = speeds.isEmpty ? nil : speeds.map(\.metersPerSecond).reduce(0, +) / Double(speeds.count)
        return HStack(spacing: 12) {
            stat("Personal best", best.map { String(format: "%.1f", $0.value(in: unit)) } ?? "—", unit.label)
            stat("Average", average.map { String(format: "%.1f", SpeedEstimate(metersPerSecond: $0, uncertainty: 0).value(in: unit)) } ?? "—", unit.label)
            stat("Measured", "\(measured.count)", "of \(shots.count)")
        }
    }

    private func stat(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.heavy)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var chart: some View {
        Card {
            Text("Top speed over time").font(.headline)
            Chart(measured.reversed()) { r in
                if let s = r.maxSpeed {
                    RuleMark(x: .value("Date", r.date),
                             yStart: .value("Low", s.value(in: unit) - s.uncertainty(in: unit)),
                             yEnd: .value("High", s.value(in: unit) + s.uncertainty(in: unit)))
                        .foregroundStyle(Theme.accent.opacity(0.35))
                    PointMark(x: .value("Date", r.date), y: .value(unit.label, s.value(in: unit)))
                        .foregroundStyle(Theme.accent)
                }
            }
            .chartYAxisLabel(unit.label)
            .frame(height: 200)
            Text("Bars show each shot's ± uncertainty.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(shots) { r in
                Button { selected = r } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                            Text("\(Int(r.frameRate)) fps · \(r.ballName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let s = r.maxSpeed, r.isMeasured {
                            Text(String(format: "%.1f ± %.1f %@", s.value(in: unit), s.uncertainty(in: unit), unit.label))
                                .font(.headline.monospacedDigit())
                            Circle().fill(Theme.color(r.confidence)).frame(width: 8, height: 8)
                        } else {
                            Text("Not measured").font(.subheadline).foregroundStyle(Theme.warn)
                        }
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
