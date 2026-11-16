import KickMetricsCore
import SwiftUI

/// Per-frame tracking details for one analysis: what the detector saw, what
/// the tracker accepted, and how the physics fit went.
struct DebugView: View {
    let reportURL: URL
    @State private var report: DebugReport?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let report {
                content(report)
            } else if loadFailed {
                Text("The tracking report couldn't be read.").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Tracking details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: reportURL) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task {
            let url = reportURL
            let loaded = await Task.detached { DebugReport.load(from: url) }.value
            report = loaded
            loadFailed = loaded == nil
        }
    }

    private func content(_ r: DebugReport) -> some View {
        List {
            Section("Outcome") {
                row("Result", r.outcome)
                ForEach(r.unavailableReasons, id: \.self) { Text($0).font(.caption) }
                ForEach(r.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                if let s = r.maxSpeed {
                    row("Top speed", String(format: "%.2f ± %.2f m/s", s.metersPerSecond, s.uncertainty))
                }
                if let g = r.measuredGravity, let s = r.gravityUncertainty {
                    row("Measured gravity", String(format: "%.3f ± %.3f m/s²", g, s))
                }
                if let d = r.gravityDirectionErrorDegrees {
                    row("Fall direction vs sensor", String(format: "%.1f°", d))
                }
            }
            if let b = r.breakdown {
                Section("Uncertainty (1σ)") {
                    row("Pixel noise", pct(b.statistical))
                    row("Ball size tolerance", pct(b.ballSize))
                    row("Edge measurement bias", pct(b.radiusBias))
                    row("Focal length", pct(b.focalLength))
                    row("Rolling shutter", pct(b.rollingShutter))
                    row("Total", pct(b.total))
                }
            }
            if let f = r.fit {
                Section("Physics fit") {
                    row("Frames used / rejected", "\(f.observationCount) / \(f.rejectedCount)")
                    row("Flight time fitted", String(format: "%.0f ms", f.duration * 1000))
                    row("Fit quality (χ²/dof)", String(format: "%.2f", f.reducedChiSquare))
                    row("RMS centre residual", String(format: "%.2f px", f.rmsCenterResidualPixels))
                    row("RMS size residual", String(format: "%.2f px", f.rmsRadiusResidualPixels))
                    row("Drag coefficient", String(format: "%.2f", f.fittedDragCoefficient))
                    row("Extra acceleration", String(format: "%.1f, %.1f, %.1f m/s²", f.fittedExtraAcceleration.x,
                                                      f.fittedExtraAcceleration.y, f.fittedExtraAcceleration.z))
                    row("Mean distance", String(format: "%.2f m", f.meanDistance))
                    row("Mean ball radius", String(format: "%.1f px", f.meanApparentRadiusPixels))
                    row("Angle toward camera", String(format: "%.0f°", f.outOfPlaneAngleDegrees))
                    if r.outcome != "measured" {
                        row("Fit speed (not a measurement)", String(format: "%.1f m/s ± %.0f%%", f.fitMaxSpeed, f.fitRelativeUncertainty * 100))
                    }
                }
            }
            Section("Camera") {
                let m = r.metadata
                row("Frames", "\(m.width)×\(m.height), \(m.frameCount) recorded")
                row("Dropped / encoder skipped", "\(m.droppedFrames) / \(m.encoderSkippedFrames)")
                row("Shutter / ISO", String(format: "1/%.0f s · ISO %.0f", 1 / max(m.exposureDurationSeconds, 1e-6), m.iso))
                row("Focal length", String(format: "%.1f px (%@)", m.intrinsics.focalLength, m.intrinsicsSource))
                row("Principal point", String(format: "%.1f, %.1f", m.intrinsics.cx, m.intrinsics.cy))
                row("Gravity (camera)", String(format: "%.2f, %.2f, %.2f%@", m.gravity.x, m.gravity.y, m.gravity.z, m.gravityMeasured ? "" : " (assumed)"))
                row("Ball left spot at", m.kickTime.map { String(format: "%.3f s", $0) } ?? "not seen live")
                row("Rest ball re-found", r.restLocated ? "yes" : "no (used tap)")
                row("Analysed", String(format: "%.3f – %.3f s", r.analyzedFrom, r.analyzedTo))
            }
            Section("Tracked ball (\(r.track.count) frames)") {
                ForEach(Array(r.track.enumerated()), id: \.offset) { _, point in
                    let o = point.observation
                    HStack {
                        Text(String(format: "%.4f", o.timestamp)).frame(width: 64, alignment: .leading)
                        Text(point.phase == .rest ? "rest" : "flight")
                            .foregroundStyle(point.phase == .rest ? Color.secondary : Theme.accent)
                            .frame(width: 44, alignment: .leading)
                        Text(String(format: "%.1f, %.1f", o.centerU, o.centerV))
                        Spacer()
                        Text(String(format: "r %.1f · %.0f%%", o.semiMinor, o.confidence * 100))
                    }
                    .font(.caption2.monospacedDigit())
                }
            }
            Section("Detector candidates per frame") {
                let counts = r.frames.map(\.candidates.count)
                row("Frames analysed", "\(counts.count)")
                row("Frames with no candidate", "\(counts.filter { $0 == 0 }.count)")
                row("Most candidates in a frame", "\(counts.max() ?? 0)")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func pct(_ v: Double) -> String { String(format: "%.2f%%", v * 100) }
}
