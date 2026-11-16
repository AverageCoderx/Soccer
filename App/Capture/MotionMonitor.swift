import CoreMotion
import KickMetricsCore

/// Reads the motion sensor: which way is down (for the physics) and whether
/// the phone is steady (a moving camera invalidates the measurement).
final class MotionMonitor {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var latestGravity: CMAcceleration?
    private var recentRotation: [Double] = []

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let r = motion.rotationRate
            let magnitude = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
            self.lock.lock()
            self.latestGravity = motion.gravity
            self.recentRotation.append(magnitude)
            if self.recentRotation.count > 30 { self.recentRotation.removeFirst(self.recentRotation.count - 30) }
            self.lock.unlock()
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Gravity in the camera frame of the back camera's native (landscape)
    /// buffer, m/s²: +x right, +y down, +z forward.
    ///
    /// Core Motion reports gravity in the device frame (portrait: +x right,
    /// +y towards the top, +z out of the screen). The back camera's native
    /// buffer is upright when the phone is in landscape with its top to the
    /// left, so image-right is device −y, image-down is device −x, and the
    /// camera looks along device −z.
    var cameraGravity: Vec3? {
        lock.lock()
        defer { lock.unlock() }
        guard let g = latestGravity else { return nil }
        return Vec3(-g.y, -g.x, -g.z) * 9.80665
    }

    /// Mean rotation rate over the last second, rad/s.
    var recentRotationRate: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !recentRotation.isEmpty else { return nil }
        return recentRotation.reduce(0, +) / Double(recentRotation.count)
    }
}
