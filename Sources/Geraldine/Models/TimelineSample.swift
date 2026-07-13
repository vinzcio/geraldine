import Foundation

/// A single value measured at a specific instant. Live charts use timestamps so their
/// horizontal position represents elapsed time rather than the number of samples kept.
protocol TimelineSample {
    var timestamp: TimeInterval { get }
}

struct MetricSample: Codable, Equatable, Identifiable, TimelineSample {
    var timestamp: TimeInterval
    var value: Double

    var id: TimeInterval { timestamp }
    var date: Date { Date(timeIntervalSinceReferenceDate: timestamp) }

    init(timestamp: TimeInterval, value: Double) {
        self.timestamp = timestamp
        self.value = value.isFinite ? value : 0
    }
}

/// Maps a fixed duration ending at `end` onto a chart's horizontal axis.
struct TimelineWindow: Equatable {
    var end: TimeInterval
    var duration: TimeInterval

    init(end: TimeInterval, duration: TimeInterval) {
        self.end = end
        self.duration = max(duration, 0.001)
    }

    var start: TimeInterval { end - duration }

    func contains(_ timestamp: TimeInterval) -> Bool {
        timestamp >= start && timestamp <= end
    }

    func fraction(for timestamp: TimeInterval) -> Double {
        min(max((timestamp - start) / duration, 0), 1)
    }

    func visible<S: TimelineSample>(_ samples: [S]) -> [S] {
        samples.filter { contains($0.timestamp) }
    }

    /// Breaks the line when the monitor did not record data for long enough that a
    /// continuous connection would imply measurements we never took.
    func segments<S: TimelineSample>(_ samples: [S], gapThreshold: TimeInterval) -> [[S]] {
        let visibleSamples = visible(samples)
        guard !visibleSamples.isEmpty else { return [] }

        var result: [[S]] = []
        var current: [S] = []
        var previousTimestamp: TimeInterval?

        for sample in visibleSamples {
            if let previousTimestamp, sample.timestamp - previousTimestamp > gapThreshold {
                if !current.isEmpty { result.append(current) }
                current.removeAll(keepingCapacity: true)
            }
            current.append(sample)
            previousTimestamp = sample.timestamp
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Reduces rendering work without changing the retained duration. Selected samples
    /// keep their real timestamps, so downsampling cannot stretch a partial history.
    func downsample<S>(_ samples: [S], maximumCount: Int?) -> [S] {
        guard let maximumCount, maximumCount > 1, samples.count > maximumCount else { return samples }
        let step = Double(samples.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            samples[min(samples.count - 1, Int((Double(index) * step).rounded()))]
        }
    }
}
