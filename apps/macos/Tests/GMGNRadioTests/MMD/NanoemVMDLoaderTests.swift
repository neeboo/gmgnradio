import Foundation
import Testing
@testable import GMGNRadio

@Test
func nanoemLoaderParsesBoneMorphTimingAndShiftJISNames() throws {
    let document = try NanoemVMDLoader.load(data: VMDTestFixture.minimalMotion())

    #expect(document.targetModelName == "自作モデル")
    #expect(document.boneKeyframes.count == 2)
    #expect(document.boneKeyframes[1].boneName == "上半身")
    #expect(document.boneKeyframes[1].frameIndex == 30)
    #expect(document.boneKeyframes[1].time == 1)
    #expect(document.boneKeyframes[1].translation.z == 3)
    #expect(document.morphKeyframes.count == 1)
    #expect(document.morphKeyframes[0].morphName == "笑い")
    #expect(document.morphKeyframes[0].time == 0.5)
    #expect(document.morphKeyframes[0].weight == 0.75)
    #expect(document.duration == 1)
}

@Test
func nanoemLoaderPreservesAllFourBoneBezierChannels() throws {
    let document = try NanoemVMDLoader.load(data: VMDTestFixture.minimalMotion())
    let interpolation = document.boneKeyframes[1].interpolation

    #expect(interpolation.translationX == VMDBezierControlPoints(32, 8, 96, 120))
    #expect(interpolation.translationY == VMDBezierControlPoints(32, 8, 96, 120))
    #expect(interpolation.translationZ == VMDBezierControlPoints(32, 8, 96, 120))
    #expect(interpolation.rotation == VMDBezierControlPoints(32, 8, 96, 120))
}

@Test
func nanoemLoaderRejectsMalformedData() {
    #expect(throws: VMDLoaderError.self) {
        try NanoemVMDLoader.load(data: VMDTestFixture.malformedMotion())
    }
}
