import Foundation

public struct FrameRateReport: Equatable, Sendable {
    public let sampleCount: Int
    public let measuredDuration: Double
    public let averageFramesPerSecond: Double
    public let p95FrameTimeMilliseconds: Double
    public let p95FramesPerSecond: Double

    public init(
        sampleCount: Int,
        measuredDuration: Double,
        averageFramesPerSecond: Double,
        p95FrameTimeMilliseconds: Double,
        p95FramesPerSecond: Double
    ) {
        self.sampleCount = sampleCount
        self.measuredDuration = measuredDuration
        self.averageFramesPerSecond = averageFramesPerSecond
        self.p95FrameTimeMilliseconds = p95FrameTimeMilliseconds
        self.p95FramesPerSecond = p95FramesPerSecond
    }
}

public struct FrameRateSampler: Sendable {
    public let reportingInterval: Double
    public let maximumFrameInterval: Double

    private var previousTimestamp: Double?
    private var acceptedDuration = 0.0
    private var frameIntervals: [Double] = []

    public init(
        reportingInterval: Double = 30 * 60,
        maximumFrameInterval: Double = 0.25
    ) {
        precondition(
            reportingInterval > 0 && reportingInterval.isFinite,
            "Reporting interval must be positive and finite"
        )
        precondition(
            maximumFrameInterval > 0 && maximumFrameInterval.isFinite,
            "Maximum frame interval must be positive and finite"
        )
        self.reportingInterval = reportingInterval
        self.maximumFrameInterval = maximumFrameInterval
    }

    public mutating func recordFrame(at timestamp: Double) -> FrameRateReport? {
        guard timestamp.isFinite else { return nil }
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return nil
        }
        self.previousTimestamp = timestamp

        let interval = timestamp - previousTimestamp
        guard interval > 0, interval <= maximumFrameInterval else {
            return nil
        }
        frameIntervals.append(interval)
        acceptedDuration += interval
        guard acceptedDuration + 0.000_000_1 >= reportingInterval else {
            return nil
        }

        let report = makeReport()
        acceptedDuration = 0
        frameIntervals.removeAll(keepingCapacity: true)
        return report
    }

    public mutating func reset() {
        previousTimestamp = nil
        acceptedDuration = 0
        frameIntervals.removeAll(keepingCapacity: true)
    }

    private func makeReport() -> FrameRateReport {
        let sorted = frameIntervals.sorted()
        let percentileIndex = min(
            max(Int(ceil(Double(sorted.count) * 0.95)) - 1, 0),
            max(sorted.count - 1, 0)
        )
        let p95Interval = sorted[percentileIndex]
        return FrameRateReport(
            sampleCount: frameIntervals.count,
            measuredDuration: acceptedDuration,
            averageFramesPerSecond: Double(frameIntervals.count)
                / acceptedDuration,
            p95FrameTimeMilliseconds: p95Interval * 1_000,
            p95FramesPerSecond: 1 / p95Interval
        )
    }
}
