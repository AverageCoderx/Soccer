import Foundation

public struct BallDetectorConfiguration: Sendable, Equatable {
    /// Motion is found on a downsampled copy of the frame (speed), then the ball
    /// is measured at full resolution.
    public var downsampleFactor: Int = 4
    /// Frame-differencing lag. At 240 fps a fast ball moves about one radius per
    /// frame, so differencing against ~2 frames back separates its old and new
    /// positions better than the immediately previous frame.
    public var motionLag: Double = 0.008
    public var minMotionThreshold: Int = 12
    public var maxMotionSeeds: Int = 12
    public var minConfidence: Double = 0.25
    /// Candidates closer than this (× radius) are duplicates; the more confident one is kept.
    public var duplicateDistance: Double = 0.5
    public var refiner = BallRefinerConfiguration()

    public init() {}
}

/// Finds ball candidates in each frame of a static (tripod) camera.
///
/// Seeds come from three places: the ball's known resting spot (set from the
/// user's tap), regions that changed since a frame a few ms earlier (moving
/// objects), and optional extra seeds (e.g. the tracker's predicted position).
/// Every seed is measured with `BallRefiner`, which only succeeds where there
/// really is a round outline of about the right size. Deciding which candidate
/// is *the* ball is left to `ShotTracker`.
///
/// This is a classical detector suited to a fixed camera. A learned detector
/// (e.g. Core ML) can be added later by producing seeds the same way.
public struct BallDetector: Sendable {
    public var configuration: BallDetectorConfiguration
    /// Resting ball: position and semi-minor axis, pixels.
    public var restBall: RefinedBall?

    private var history: [(time: Double, image: GrayImage)] = []

    public init(configuration: BallDetectorConfiguration = BallDetectorConfiguration(), restBall: RefinedBall? = nil) {
        self.configuration = configuration
        self.restBall = restBall
    }

    public mutating func detect(_ image: GrayImage, timestamp: Double, extraSeeds: [ImagePoint] = []) -> FrameCandidates {
        let c = configuration
        let small = image.downsampled(by: c.downsampleFactor)
        let typicalRadius = restBall?.semiMinor

        var seeds: [(u: Double, v: Double, r: Double)] = []
        if let rest = restBall {
            seeds.append((rest.centerU, rest.centerV, rest.semiMinor))
        }
        // Three-frame differencing: the ball's *current* position is where this
        // frame differs from both a frame `lag` ago and one `2·lag` ago; the
        // places it used to be differ from only one of them.
        let refA = history.last(where: { $0.time <= timestamp - c.motionLag })
        let refB = history.last(where: { $0.time <= timestamp - 2 * c.motionLag })
        let references = [refA, refB].compactMap { $0?.image }
        if !references.isEmpty {
            for s in MotionSeeder.seeds(current: small, references: references, factor: c.downsampleFactor,
                                        expectedRadius: typicalRadius, minThreshold: c.minMotionThreshold,
                                        maxSeeds: c.maxMotionSeeds) {
                seeds.append((s.u, s.v, typicalRadius ?? s.radius))
            }
        }
        if let r = typicalRadius {
            for s in extraSeeds { seeds.append((s.u, s.v, r)) }
        }

        var found: [RefinedBall] = []
        for seed in seeds {
            if let ball = BallRefiner.refine(image: image, seedU: seed.u, seedV: seed.v,
                                             expectedRadius: seed.r, configuration: c.refiner),
               ball.confidence >= c.minConfidence {
                found.append(ball)
            }
        }
        var kept: [RefinedBall] = []
        for ball in found.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = kept.contains {
                hypot($0.centerU - ball.centerU, $0.centerV - ball.centerV) < c.duplicateDistance * max($0.semiMinor, ball.semiMinor)
            }
            if !duplicate { kept.append(ball) }
        }

        history.append((timestamp, small))
        let horizon = timestamp - 3 * c.motionLag - 0.05
        history.removeAll { $0.time < horizon }
        if history.count > 16 { history.removeFirst(history.count - 16) }

        return FrameCandidates(timestamp: timestamp, candidates: kept.map { $0.observation(timestamp: timestamp) })
    }
}

/// Regions of a downsampled frame that changed relative to every reference frame.
public enum MotionSeeder {
    public struct Seed: Sendable, Equatable {
        public var u: Double
        public var v: Double
        public var radius: Double
        public var area: Int
    }

    public static func seeds(
        current: GrayImage, references: [GrayImage], factor: Int, expectedRadius: Double?,
        minThreshold: Int, maxSeeds: Int
    ) -> [Seed] {
        guard !references.isEmpty,
              references.allSatisfy({ $0.width == current.width && $0.height == current.height }) else { return [] }
        let w = current.width, h = current.height
        let count = w * h
        // Per pixel, the smallest difference to any reference (= logical AND of the change masks).
        var diff = [UInt8](repeating: 255, count: count)
        for reference in references {
            current.pixels.withUnsafeBufferPointer { a in
                reference.pixels.withUnsafeBufferPointer { b in
                    for i in 0..<count {
                        let d = UInt8(abs(Int(a[i]) - Int(b[i])))
                        if d < diff[i] { diff[i] = d }
                    }
                }
            }
        }
        var histogram = [Int](repeating: 0, count: 256)
        for d in diff { histogram[Int(d)] += 1 }
        // Noise level from the median absolute difference (most of a static
        // scene doesn't change).
        var cumulative = 0
        var median = 0
        for (value, n) in histogram.enumerated() {
            cumulative += n
            if cumulative * 2 >= count {
                median = value
                break
            }
        }
        let threshold = UInt8(min(200, max(minThreshold, 4 * median + 4)))

        // 4-connected components of the changed mask.
        var label = [Int32](repeating: 0, count: count)
        var stack: [Int] = []
        var seeds: [Seed] = []
        let maxExtent = expectedRadius.map { Int(4 * $0 / Double(factor)) + 2 } ?? (160 / factor)
        var nextLabel: Int32 = 1
        for start in 0..<count where diff[start] >= threshold && label[start] == 0 {
            var n = 0, sx = 0, sy = 0
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            stack.append(start)
            label[start] = nextLabel
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                n += 1
                sx += x
                sy += y
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, diff[i - 1] >= threshold, label[i - 1] == 0 { label[i - 1] = nextLabel; stack.append(i - 1) }
                if x < w - 1, diff[i + 1] >= threshold, label[i + 1] == 0 { label[i + 1] = nextLabel; stack.append(i + 1) }
                if y > 0, diff[i - w] >= threshold, label[i - w] == 0 { label[i - w] = nextLabel; stack.append(i - w) }
                if y < h - 1, diff[i + w] >= threshold, label[i + w] == 0 { label[i + w] = nextLabel; stack.append(i + w) }
            }
            nextLabel += 1
            guard n >= 2 else { continue }
            let extent = max(maxX - minX, maxY - minY) + 1
            // Very large regions are people or camera shake, not a ball.
            guard extent <= maxExtent else { continue }
            let f = Double(factor)
            seeds.append(Seed(u: (Double(sx) / Double(n) + 0.5) * f, v: (Double(sy) / Double(n) + 0.5) * f,
                              radius: max(3, (Double(n) / .pi).squareRoot() * f), area: n))
        }
        return Array(seeds.sorted { $0.area > $1.area }.prefix(maxSeeds))
    }
}

/// Finds the ball near a point the user tapped, trying several sizes.
public enum BallLocator {
    public static func locate(
        in image: GrayImage, near tap: ImagePoint,
        configuration: BallRefinerConfiguration = BallRefinerConfiguration()
    ) -> RefinedBall? {
        var found: [RefinedBall] = []
        for radius in [5.0, 8, 12, 18, 26, 38, 55, 80] {
            guard let ball = BallRefiner.refine(image: image, seedU: tap.u, seedV: tap.v,
                                                expectedRadius: radius, configuration: configuration) else { continue }
            // The tap should be on (or very near) the ball.
            guard hypot(ball.centerU - tap.u, ball.centerV - tap.v) <= max(ball.semiMinor * 1.2, 12),
                  ball.confidence >= 0.3 else { continue }
            found.append(ball)
        }
        // Dark panels on the ball are round too, but they lie inside its outline:
        // take the largest outline that is nearly as clean as the best one.
        guard let bestConfidence = found.map(\.confidence).max() else { return nil }
        return found
            .filter { $0.confidence >= 0.6 * bestConfidence }
            .max { $0.semiMinor < $1.semiMinor }
    }
}
