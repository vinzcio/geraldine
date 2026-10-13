import Foundation

enum ChartInspection {
    static func timestamp(fraction: Double, in timeline: TimelineWindow) -> TimeInterval? {
        guard fraction.isFinite else { return nil }
        return timeline.start + min(max(fraction, 0), 1) * timeline.duration
    }

    /// Only select within a continuous run. A cursor in an unrecorded interval
    /// must not borrow an old measurement from either side of the gap.
    static func sample(at timestamp: TimeInterval, samples: [MetricSample],
                       timeline: TimelineWindow, gapThreshold: TimeInterval) -> MetricSample? {
        guard timestamp.isFinite, timeline.contains(timestamp) else { return nil }
        for segment in timeline.segments(samples, gapThreshold: gapThreshold) {
            guard let first = segment.first, let last = segment.last,
                  timestamp >= first.timestamp, timestamp <= last.timestamp else { continue }
            return segment.min { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) }
        }
        return nil
    }
}
