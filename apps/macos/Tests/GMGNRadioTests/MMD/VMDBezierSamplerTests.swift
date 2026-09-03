import Testing
@testable import GMGNRadio

@Test
func vmdBezierSamplerReturnsTheEndpointsExactly() {
    let curve = VMDBezierControlPoints(32, 8, 96, 120)

    #expect(VMDBezierSampler.value(at: 0, controlPoints: curve) == 0)
    #expect(VMDBezierSampler.value(at: 1, controlPoints: curve) == 1)
}

@Test
func vmdBezierSamplerSolvesCurveXBeforeReturningY() {
    let cssEase = VMDBezierControlPoints(
        normalizedX1: 0.25,
        normalizedY1: 0.1,
        normalizedX2: 0.25,
        normalizedY2: 1
    )

    let value = VMDBezierSampler.value(at: 0.5, controlPoints: cssEase)

    #expect(abs(value - 0.8024) < 0.001)
}
