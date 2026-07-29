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

@Test
func agentVisualLanguageOverridesTheRoleAndDrivesIntensity() {
    let track = MusicCandidate(
        id: "track",
        canonicalID: nil,
        providerID: .netease,
        source: .streaming,
        title: "Track",
        artist: "Artist",
        album: nil,
        duration: 240,
        isPlayable: true,
        matchScore: 1,
        userAffinity: 1,
        energy: 0.5,
        moodTags: [],
        genres: [],
        releaseYear: nil
    )
    let slot = ProgramSlot(
        track: track,
        role: .opener,
        hostHint: ProgramHostHint(
            shouldTalkBefore: true,
            maxSentenceCount: 1,
            selectionReason: "测试",
            currentTrack: TrackReference(
                id: track.id,
                title: track.title,
                artist: track.artist
            ),
            nextTrack: nil,
            facts: [],
            transitionIntent: nil
        ),
        visualDirection: AgentVisualDirection(
            mood: "高能霓虹脉冲",
            palette: "蓝紫",
            motion: "快速扩散",
            intensity: 0.7
        )
    )

    let cue = ProgramVisualDirector().cue(for: slot)

    #expect(cue.mood == .pulse)
    #expect(cue.intensity == 0.7)
}
