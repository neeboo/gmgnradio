import Testing
@testable import WorldRuntime

@Test("Frame sampler reports p95 frame time for one visible window")
func frameSamplerReportsP95FrameTime() throws {
    var sampler = FrameRateSampler(
        reportingInterval: 1.75,
        maximumFrameInterval: 0.25
    )
    var timestamp = 0.0
    #expect(sampler.recordFrame(at: timestamp) == nil)

    for frame in 0 ..< 100 {
        timestamp += frame < 94 ? 1.0 / 60.0 : 1.0 / 30.0
        if let report = sampler.recordFrame(at: timestamp) {
            #expect(report.sampleCount >= 99)
            #expect(report.averageFramesPerSecond > 50)
            #expect(report.p95FrameTimeMilliseconds > 30)
            #expect(report.p95FramesPerSecond < 31)
            return
        }
    }

    Issue.record("Expected a report after the configured interval")
}

@Test("Frame sampler excludes an occlusion-sized gap")
func frameSamplerExcludesLongGap() throws {
    var sampler = FrameRateSampler(
        reportingInterval: 0.07,
        maximumFrameInterval: 0.1
    )
    #expect(sampler.recordFrame(at: 0) == nil)
    #expect(sampler.recordFrame(at: 0.02) == nil)
    #expect(sampler.recordFrame(at: 1.02) == nil)
    #expect(sampler.recordFrame(at: 1.04) == nil)
    #expect(sampler.recordFrame(at: 1.06) == nil)
    let possibleReport = sampler.recordFrame(at: 1.08)
    let report = try #require(possibleReport)

    #expect(report.sampleCount == 4)
    #expect(report.p95FrameTimeMilliseconds < 21)
}

@Test("Frame sampler reset starts a new measurement window")
func frameSamplerResetStartsNewWindow() {
    var sampler = FrameRateSampler(
        reportingInterval: 0.03,
        maximumFrameInterval: 0.1
    )
    _ = sampler.recordFrame(at: 0)
    _ = sampler.recordFrame(at: 0.02)
    sampler.reset()

    #expect(sampler.recordFrame(at: 10) == nil)
    #expect(sampler.recordFrame(at: 10.02) == nil)
    #expect(sampler.recordFrame(at: 10.04)?.sampleCount == 2)
}
