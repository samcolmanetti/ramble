import Foundation

/// Running level statistics over a stream of audio buffers.
///
/// Everything is in dBFS: 0 dB is full scale, and quieter is more negative.
/// `-100` stands in for digital silence so the numbers stay printable.
public struct LevelStats {
    public var peak: Float = -100
    public var frames: [Float] = []

    public init() {}

    public mutating func add(rms: Float, peak samplePeak: Float) {
        frames.append(rms)
        peak = max(peak, samplePeak)
    }

    public var mean: Float {
        guard !frames.isEmpty else { return -100 }
        // Average in the linear domain, not the log domain — averaging dB values
        // directly under-weights the loud parts, which is where the speech is.
        let linear = frames.map { powf(10, $0 / 20) }
        return LevelStats.dbfs(linear.reduce(0, +) / Float(linear.count))
    }

    /// Level exceeded by all but the loudest 5% — a robust "how loud is the
    /// speech" figure that a single click or bump can't skew.
    public var p95: Float { percentile(0.95) }
    /// Level exceeded by 90% of frames — a decent noise-floor estimate, since
    /// most of any recording is between words.
    public var p10: Float { percentile(0.10) }

    public func percentile(_ p: Float) -> Float {
        guard !frames.isEmpty else { return -100 }
        let sorted = frames.sorted()
        let index = min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * p)))
        return sorted[index]
    }

    public static func dbfs(_ amplitude: Float) -> Float {
        amplitude <= 0.0000001 ? -100 : max(-100, 20 * log10f(amplitude))
    }

    /// Compute RMS and peak for one buffer of mono samples.
    public static func measure(_ samples: UnsafePointer<Float>, count: Int) -> (rms: Float, peak: Float) {
        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0 ..< count {
            let s = samples[i]
            sumSquares += s * s
            peak = max(peak, abs(s))
        }
        let rms = count > 0 ? sqrtf(sumSquares / Float(count)) : 0
        return (dbfs(rms), dbfs(peak))
    }

    /// A 30-column bar for a live terminal readout, spanning -60…0 dBFS.
    public static func bar(_ db: Float, width: Int = 30) -> String {
        let fraction = max(0, min(1, (db + 60) / 60))
        let filled = Int(fraction * Float(width))
        return String(repeating: "█", count: filled)
            + String(repeating: "·", count: width - filled)
    }
}
