import AppKit
import CoreGraphics
import Testing
@testable import GMGNRadio

@Test
func sameSeedAndTimeProduceSameMotionFrame() {
    let first = OrbMotionModel.frame(
        for: .idle,
        time: 12.5,
        seed: 42,
        audio: .silent
    )
    let second = OrbMotionModel.frame(
        for: .idle,
        time: 12.5,
        seed: 42,
        audio: .silent
    )

    #expect(first == second)
}

@Test(arguments: [
    (DJState.idle, Float(0.14), Float(0.24)),
    (DJState.listening, Float(0.64), Float(0.82)),
    (DJState.thinking, Float(0.46), Float(0.66)),
    (DJState.speaking, Float(0.80), Float(1.00)),
    (DJState.playing, Float(0.42), Float(0.84))
])
func stateEnergyStaysInsideDesignedRange(
    state: DJState,
    minimum: Float,
    maximum: Float
) {
    let frame = OrbMotionModel.frame(
        for: state,
        time: 8.75,
        seed: 7,
        audio: .silent
    )

    #expect(frame.energy >= minimum)
    #expect(frame.energy <= maximum)
}

@Test
func privacyOffIsVisuallyQuiet() {
    let frame = OrbMotionModel.frame(
        for: .privacyOff,
        time: 99,
        seed: 11,
        audio: .silent
    )

    #expect(frame.energy <= 0.05)
    #expect(frame.opacity <= 0.30)
    #expect(frame.particleAmount == 0)
}

@Test
func playingMotionRespondsToSharedAudioFeatures() {
    let silent = OrbMotionModel.frame(
        for: .playing,
        time: 4,
        seed: 9,
        audio: .silent
    )
    let active = OrbMotionModel.frame(
        for: .playing,
        time: 4,
        seed: 9,
        audio: VisualAudioFeatures(low: 1, mid: 0.6, high: 0.3)
    )

    #expect(active.energy > silent.energy)
    #expect(active.deformation > silent.deformation)
}

@Test
func speakingCanReverseImmediatelyIntoListening() {
    var model = OrbMotionModel(initial: .speaking, seed: 17, time: 0)
    let beforeInterruption = model.frame(at: 0.18, audio: .silent)

    model.transition(to: .listening, at: 0.18, audio: .silent)
    let atInterruption = model.frame(at: 0.18, audio: .silent)
    let afterInterruption = model.frame(at: 0.50, audio: .silent)

    #expect(atInterruption == beforeInterruption)
    #expect(afterInterruption.energy < atInterruption.energy)
    #expect(afterInterruption.listeningRing > atInterruption.listeningRing)
}

@Test
func immersiveExitReversesTheEntryTimeline() {
    let entering = ImmersiveTransition(
        direction: .entering,
        startedAt: 10,
        duration: 0.8
    )
    let exiting = ImmersiveTransition(
        direction: .exiting,
        startedAt: 10,
        duration: 0.8
    )

    #expect(entering.progress(at: 10) == 0)
    #expect(entering.progress(at: 10.8) == 1)
    #expect(exiting.progress(at: 10) == 1)
    #expect(exiting.progress(at: 10.8) == 0)
}

@Test
func immersiveOriginStartsAtOrbCenterOnItsDisplay() {
    let origin = ImmersiveSceneGeometry.normalizedOrigin(
        orbCenter: CGPoint(x: 1680, y: 270),
        screenFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    )

    #expect(origin.x == 0.125)
    #expect(origin.y == 0.25)
}

@Test
@MainActor
func immersiveVisualsStayBehindWorkingWindows() {
    #expect(
        ImmersivePresentationPolicy.windowLevel.rawValue
            < NSWindow.Level.normal.rawValue
    )
    #expect(ImmersivePresentationPolicy.ignoresMouseEvents)
}
