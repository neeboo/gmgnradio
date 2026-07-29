import Testing
@testable import GMGNRadio

@Test
func programRolesProduceACompleteRestrainedVisualArc() {
    let director = ProgramVisualDirector()

    let opener = director.cue(for: .opener)
    let build = director.cue(for: .build)
    let peak = director.cue(for: .peak)
    let cooldown = director.cue(for: .cooldown)
    let closer = director.cue(for: .closer)

    #expect(opener.mood == .afterglow)
    #expect(build.mood == .liquid)
    #expect(peak.mood == .pulse)
    #expect(cooldown.mood == .liquid)
    #expect(closer.mood == .afterglow)

    #expect(opener.intensity < build.intensity)
    #expect(build.intensity < peak.intensity)
    #expect(cooldown.intensity < peak.intensity)
    #expect(closer.intensity < cooldown.intensity)
}

@Test
func semanticMoodOverridesTheRoleDefaultAndSelectsItsPreset() {
    let cue = ProgramVisualDirector().cue(
        for: .opener,
        mood: .pulse
    )

    #expect(cue.mood == .pulse)
    #expect(cue.frame == StageVisualPresetFrame.forMood(.pulse))
}

@Test
func requestedIntensityIsClampedToTheSafeVisualRange() {
    let director = ProgramVisualDirector()

    let tooLow = director.cue(for: .build, intensity: -4)
    let tooHigh = director.cue(for: .peak, intensity: 9)

    #expect(tooLow.intensity == ProgramVisualDirector.minimumIntensity)
    #expect(tooHigh.intensity == ProgramVisualDirector.maximumIntensity)
}

@Test
func transitionTimingKeepsPeaksResponsiveAndProgramEdgesGentle() {
    let director = ProgramVisualDirector()

    let opener = director.cue(for: .opener)
    let build = director.cue(for: .build)
    let peak = director.cue(for: .peak)
    let cooldown = director.cue(for: .cooldown)
    let closer = director.cue(for: .closer)

    #expect(peak.transitionDuration < build.transitionDuration)
    #expect(build.transitionDuration < opener.transitionDuration)
    #expect(cooldown.transitionDuration > build.transitionDuration)
    #expect(closer.transitionDuration > cooldown.transitionDuration)
}
