import SoccerTrackerCore
import SwiftData
import SwiftUI

/// Main screen: camera preview, setup checklist, START/STOP.
struct CaptureView: View {
    @StateObject private var camera = CameraController()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.frameRate) private var frameRateSetting: Double = 240

    @State private var mode: CaptureMode = .shot
    @State private var analyzing = false
    @State private var progress: Double = 0
    @State private var finishedRecord: ShotRecord?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch camera.phase {
            case .unauthorized:
                permissionView
            case let .failed(message):
                messageView(title: "Camera unavailable", message: message)
            default:
                cameraLayout
            }
            if analyzing { analyzingOverlay }
        }
        .onAppear {
            camera.onRecordingFinished = handleRecording
            camera.start(frameRate: AppSettings.frameRate())
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                camera.start(frameRate: AppSettings.frameRate())
            } else if newPhase == .background {
                camera.stop()
            }
        }
        .onChange(of: frameRateSetting) { _, newValue in
            camera.clearBall()
            camera.start(frameRate: AppSettings.frameRate())
        }
        .sheet(item: $finishedRecord) { record in
            NavigationStack { ResultView(record: record) }
        }
        .alert("Couldn't analyse the shot", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Layout

    private var cameraLayout: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack(alignment: .top) {
                CameraPreviewView(session: camera.session, ball: camera.lockedBall,
                                  bufferSize: camera.bufferSize) { point in
                    guard camera.phase == .previewing else { return }
                    camera.lockBall(atDevicePoint: point)
                }
                .ignoresSafeArea()

                statusBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                if landscape {
                    HStack(alignment: .bottom) {
                        checklist.frame(maxWidth: 300)
                        Spacer()
                        controls.frame(maxWidth: 260)
                    }
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                } else {
                    VStack(spacing: 12) {
                        Spacer()
                        checklist
                        controls
                    }
                    .padding(16)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(camera.phase == .recording ? Theme.bad : Theme.good)
                .frame(width: 10, height: 10)
            Text(camera.phase == .recording ? String(format: "REC %.1f s", camera.recordingSeconds) : "LIVE")
                .font(.caption.monospacedDigit().weight(.bold))
            Text(camera.formatDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if camera.lockedBall != nil {
                Text(String(format: "Tracking %.0f%%", camera.ballConfidence * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(camera.ballConfidence > 0.5 ? Theme.good : Theme.warn)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(camera.statusText)
                .font(.subheadline.weight(.semibold))
            ForEach(camera.checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Theme.color(check.level)).frame(width: 8, height: 8)
                    Text(check.title).font(.caption.weight(.semibold)).frame(width: 62, alignment: .leading)
                    Text(check.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Mode", selection: $mode) {
                ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(camera.phase != .previewing)

            Button(action: toggleRecording) {
                Text(camera.phase == .recording ? "STOP" : "START RECORDING")
                    .font(.title3.weight(.heavy))
                    .tracking(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(camera.phase == .recording ? Theme.bad : Theme.accent,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(.white)
            }
            .disabled(!canToggle)
            .opacity(canToggle ? 1 : 0.4)

            if camera.lockedBall != nil, camera.phase == .previewing {
                Button("Unlock ball") { camera.clearBall() }
                    .font(.caption)
            }
        }
    }

    private var canToggle: Bool {
        switch camera.phase {
        case .recording: return true
        case .previewing: return camera.lockedBall != nil && !analyzing
        default: return false
        }
    }

    private var analyzingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView(value: progress)
                .frame(width: 220)
            Text("Measuring the shot…")
                .font(.headline)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(Theme.accent)
            Text("Camera access needed").font(.title2.weight(.bold))
            Text("Soccer Tracker measures shots with the camera. Video stays on this iPhone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private func messageView(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.title2.weight(.bold))
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(32)
    }

    // MARK: Actions

    private func toggleRecording() {
        if camera.phase == .recording {
            camera.stopRecording()
        } else {
            camera.startRecording(mode: mode)
        }
    }

    private func handleRecording(_ result: Result<CameraController.FinishedRecording, Error>) {
        switch result {
        case let .failure(error):
            errorMessage = error.localizedDescription
        case let .success(recording):
            analyze(recording)
        }
    }

    private func analyze(_ recording: CameraController.FinishedRecording) {
        analyzing = true
        progress = 0
        let ball = AppSettings.ballSpec()
        let progressBinding = $progress
        Task.detached(priority: .userInitiated) {
            do {
                // Heavy work off the main thread.
                let output = try await ClipAnalyzer.analyze(clip: recording.clipURL, metadata: recording.metadata, ball: ball) { value in
                    DispatchQueue.main.async { progressBinding.wrappedValue = value }
                }
                try await MainActor.run {
                    let record = try save(output, recording: recording, ball: ball)
                    analyzing = false
                    finishedRecord = record
                }
            } catch {
                await MainActor.run {
                    analyzing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func save(_ output: ClipAnalyzer.Output, recording: CameraController.FinishedRecording, ball: BallSpec) throws -> ShotRecord {
        let kind: ShotRecord.Kind = recording.metadata.mode == .shot ? .shot : .dropTest
        let record = ShotRecord(kind: kind, frameRate: recording.metadata.requestedFrameRate, ballName: ball.name)
        record.clipFileName = recording.clipURL.lastPathComponent
        let reportName = recording.clipURL.deletingPathExtension().lastPathComponent + ".json"
        try DebugReport.encode(output.report).write(to: Storage.shotsDirectory.appendingPathComponent(reportName))
        record.reportFileName = reportName

        if let shot = output.shot {
            record.isMeasured = shot.isMeasured
            record.unavailableReasons = shot.unavailableReasons.map(\.explanation)
            record.warnings = shot.warnings.map(\.explanation)
            if let speed = shot.speed {
                record.maxSpeedMPS = speed.maxSpeed.metersPerSecond
                record.maxSpeedSigma = speed.maxSpeed.uncertainty
                record.averageSpeedMPS = speed.averageSpeed.metersPerSecond
                record.averageSpeedSigma = speed.averageSpeed.uncertainty
                record.confidenceRaw = speed.confidence.rawValue
            }
            record.outOfPlaneAngle = shot.diagnostics?.outOfPlaneAngleDegrees
            record.distanceMeters = shot.diagnostics?.meanDistance
        } else {
            let measured = output.drop != nil && output.dropReasons.isEmpty
            record.isMeasured = measured
            record.unavailableReasons = output.dropReasons.map(\.explanation)
            if measured, let drop = output.drop {
                record.measuredGravity = drop.measuredGravity
                record.gravitySigma = drop.uncertainty
            }
        }
        modelContext.insert(record)
        try modelContext.save()
        return record
    }
}
