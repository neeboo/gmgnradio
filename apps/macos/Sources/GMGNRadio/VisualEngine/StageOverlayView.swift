import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StageOverlayView: View {
    @ObservedObject var presentation: StagePresentationModel
    @ObservedObject var overlayState: StageOverlayState
    @ObservedObject var lyrics: StageLyricsStore
    @ObservedObject var videos: StageVideoPlaybackStore
    let audioFeatures: VisualAudioFeatureStore
    let playbackPosition: @MainActor () -> TimeInterval

    var body: some View {
        ZStack {
            StageLyricsView(
                lyrics: lyrics,
                overlayState: overlayState,
                audioFeatures: audioFeatures,
                playbackPosition: playbackPosition
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading) {
                if !presentation.programTitle.isEmpty {
                    Text(presentation.programTitle)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(
                            Color(red: 0.42, green: 0.88, blue: 1)
                        )
                        .shadow(
                            color: Color(red: 0.06, green: 0.62, blue: 1)
                                .opacity(0.55),
                            radius: 8
                        )
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 34)
            .padding(.leading, 36)
            .allowsHitTesting(false)

            VStack {
                Spacer()
                if let cue = presentation.currentCue {
                    Text(cue.text)
                        .font(.system(
                            size: 17 + CGFloat(cue.emphasis) * 4,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(
                            Color(red: 0.84, green: 0.96, blue: 1)
                        )
                        .lineLimit(3)
                        .lineSpacing(5)
                        .minimumScaleFactor(0.76)
                        .multilineTextAlignment(.center)
                        .frame(
                            maxWidth: overlayState.isProgramRailVisible
                                ? 640
                                : 860
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .id(cue.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .shadow(
                            color: Color(red: 0.02, green: 0.42, blue: 1)
                                .opacity(0.72),
                            radius: 12
                        )
                        .shadow(color: .black.opacity(0.92), radius: 4)
                        .padding(.bottom, 38)
                        .offset(x: overlayState.isProgramRailVisible ? -154 : 0)
                        .opacity(overlayState.isProgramRailVisible ? 0.72 : 1)
                }
            }

            if let prompt = videos.pendingBoundVideo {
                VStack {
                    HStack {
                        Spacer()
                        StageBoundVideoPromptView(
                            prompt: prompt,
                            onPlay: videos.playPendingBoundVideo,
                            onClose: {
                                videos.dismissBoundVideoPrompt(id: prompt.id)
                            }
                        )
                    }
                    Spacer()
                }
                .padding(.top, 28)
                .padding(.trailing, 32)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: prompt.id) {
                    try? await Task.sleep(for: .seconds(3))
                    videos.dismissBoundVideoPrompt(id: prompt.id)
                }
            }
        }
        .animation(.easeOut(duration: 0.28), value: presentation.currentCue?.id)
        .animation(
            .easeOut(duration: 0.22),
            value: overlayState.isProgramRailVisible
        )
    }
}

private struct StageBoundVideoPromptView: View {
    let prompt: StageBoundVideoPrompt
    let onPlay: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 12) {
                Image(systemName: "video.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.cyan.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(Color.cyan.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("这首歌有专属画面")
                        .font(.system(
                            size: 13,
                            weight: .semibold,
                            design: .rounded
                        ))
                    Text(prompt.asset.displayName)
                        .font(.system(
                            size: 11,
                            weight: .medium,
                            design: .rounded
                        ))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button("播放", action: onPlay)
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan.opacity(0.72))
                    .controlSize(.small)
            }
            .padding(.leading, 10)
            .padding(.trailing, 28)
            .frame(width: 330, height: 58)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.46))
            .accessibilityLabel("忽略绑定视频")
            .padding(7)
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 330, height: 58)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.cyan.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.44), radius: 18, y: 8)
    }
}

@MainActor
private struct StageLyricsView: View {
    @ObservedObject var lyrics: StageLyricsStore
    @ObservedObject var overlayState: StageOverlayState
    let audioFeatures: VisualAudioFeatureStore
    let playbackPosition: @MainActor () -> TimeInterval

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval:
                    StageLyricRenderPolicy.minimumFrameInterval
            )
        ) { context in
            let playbackTime = playbackPosition()
            let resolvedMode = StageLyricModeDirector.resolve(
                configuredMode: lyrics.visualMode,
                trackID: lyrics.trackID,
                lines: lyrics.lines,
                playbackTime: playbackTime
            )
            let audioMotion = StageLyricAudioMotion(
                features: audioFeatures.current,
                animationTime: context.date.timeIntervalSinceReferenceDate,
                mode: resolvedMode
            )
            switch resolvedMode {
            case .automatic:
                EmptyView()
            case .flowingLine:
                StageFlowingLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    animationTime: context.date.timeIntervalSinceReferenceDate,
                    audio: audioMotion
                )
            case .depthStack:
                StageDepthLyricsFrame(
                    scene: StageLyricSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .cloudSteps:
                StageCloudStepsLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .chorusChat:
                StageChorusChatLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .cinematicSplit:
                StageCinematicSplitLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    playbackTime: playbackTime,
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .orbitArc:
                StageOrbitLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    animationTime:
                        context.date.timeIntervalSinceReferenceDate,
                    audio: audioMotion
                )
            case .posterRail:
                StagePosterRailLyricsFrame(
                    lines: lyrics.lines,
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .editorialField:
                StageEditorialLyricsFrame(
                    lines: lyrics.lines,
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    playbackTime: playbackTime,
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .pendulumWheel:
                StagePendulumLyricsFrame(
                    lines: lyrics.lines,
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    animationTime:
                        context.date.timeIntervalSinceReferenceDate,
                    audio: audioMotion
                )
            case .dioramaStage:
                StageDioramaLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    animationTime:
                        context.date.timeIntervalSinceReferenceDate,
                    audio: audioMotion
                )
            case .foldingVerse:
                StageFoldingVerseLyricsFrame(
                    scene: StageLyricFoldSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible
                )
            }
        }
        .animation(
            .easeOut(duration: 0.22),
            value: overlayState.isProgramRailVisible
        )
        .environment(
            \.stageFoliaTheme,
            lyrics.activeTheme ?? .gmgnDefaultDark
        )
        .allowsHitTesting(false)
    }
}

private struct StageFlowingLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let animationTime: TimeInterval
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let fontSize = resolvedFontSize(
                    text: line.text,
                    availableWidth: proxy.size.width
                )
                let railOffset = isProgramRailVisible ? -150.0 : 0
                let breathingY = sin(animationTime * 0.72) * 2.2
                    + audio.beatLift * 0.18

                VStack(spacing: 22) {
                    if let previousLine = scene.previousLine {
                        contextualLine(
                            previousLine.text,
                            fontSize: fontSize,
                            alignment: .leading,
                            isUpcoming: false
                        )
                    }

                    HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.015) {
                        ForEach(scene.glyphs) { glyph in
                            StageFlowingLyricGlyph(
                                glyph: glyph,
                                fontSize: fontSize,
                                isChorus: scene.isChorus
                            )
                        }
                    }
                    .compositingGroup()
                    .shadow(
                        color: scene.isChorus
                            ? theme.secondaryColor.opacity(0.3)
                            : theme.accentColor.opacity(0.22),
                        radius: scene.isChorus ? 22 : 14
                    )
                    .shadow(color: .black.opacity(0.78), radius: 3)
                    .frame(maxWidth: proxy.size.width * 0.82)
                    .offset(y: breathingY)

                    if let translation = scene.translation {
                        Text(translation)
                            .font(.system(
                                size: max(16, fontSize * 0.22),
                                weight: .medium,
                                design: .rounded
                            ))
                            .tracking(0.7)
                            .foregroundStyle(theme.primaryColor.opacity(0.66))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: 720)
                            .shadow(color: .black.opacity(0.9), radius: 5)
                    }

                    if let nextLine = scene.nextLine {
                        contextualLine(
                            nextLine.text,
                            fontSize: fontSize,
                            alignment: .trailing,
                            isUpcoming: true
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(x: railOffset, y: -8)
                .scaleEffect(audio.expansion)
                .id(line.id)
                .transition(
                    .opacity.combined(
                        with: .scale(scale: 0.94, anchor: .center)
                    )
                )
                .animation(
                    .spring(response: 0.44, dampingFraction: 0.84),
                    value: line.id
                )
            }
        }
    }

    private func resolvedFontSize(
        text: String,
        availableWidth: CGFloat
    ) -> CGFloat {
        CGFloat(StageLyricTypography.fontSize(
            text: text,
            availableWidth: Double(availableWidth)
        ))
    }

    private func contextualLine(
        _ text: String,
        fontSize: CGFloat,
        alignment: Alignment,
        isUpcoming: Bool
    ) -> some View {
        Text(text)
            .font(.system(
                size: min(max(fontSize * 0.28, 15), 24),
                weight: .semibold,
                design: .rounded
            ))
            .tracking(0.5)
            .foregroundStyle(
                theme.primaryColor.opacity(isUpcoming ? 0.28 : 0.18)
            )
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: 680, alignment: alignment)
            .blur(radius: isUpcoming ? 0.9 : 1.5)
            .offset(x: isUpcoming ? 42 : -42)
    }
}

private struct StageFoldingVerseLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFoldSceneModel
    let isProgramRailVisible: Bool

    var body: some View {
        GeometryReader { proxy in
            let progress = eased(scene.transitionProgress)
            let direction: CGFloat = scene.foldDirection == .left
                ? -1
                : 1
            let railOffset = isProgramRailVisible ? -138.0 : 0

            ZStack {
                if !scene.previousLines.isEmpty {
                    lyricGroup(
                        lines: scene.previousLines,
                        activeLineID: nil,
                        availableWidth: proxy.size.width * 0.58,
                        historical: true
                    )
                    .rotationEffect(
                        .degrees(direction * 90 * progress),
                        anchor: scene.foldDirection == .left
                            ? .leading
                            : .trailing
                    )
                    .rotation3DEffect(
                        .degrees(direction * 7 * progress),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: scene.foldDirection == .left
                            ? .leading
                            : .trailing,
                        perspective: 0.72
                    )
                    .offset(
                        x: direction * proxy.size.width * 0.29 * progress,
                        y: -proxy.size.height * 0.07 * progress
                    )
                    .scaleEffect(1 - progress * 0.18)
                    .opacity(1 - progress * 0.5)
                }

                lyricGroup(
                    lines: scene.currentLines,
                    activeLineID: scene.activeLineID,
                    availableWidth: proxy.size.width * 0.68,
                    historical: false
                )
                .offset(
                    x: direction * proxy.size.width * 0.035
                        * (1 - progress),
                    y: proxy.size.height * 0.68 * (1 - progress)
                )
                .scaleEffect(
                    0.92 + progress * 0.08,
                    anchor: .bottom
                )
                .opacity(0.16 + progress * 0.84)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: railOffset, y: -8)
            .clipped()
        }
    }

    private func lyricGroup(
        lines: [StageLyricLine],
        activeLineID: String?,
        availableWidth: CGFloat,
        historical: Bool
    ) -> some View {
        let activeIndex = activeLineID.flatMap { id in
            lines.firstIndex(where: { $0.id == id })
        }

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.element.id) {
                index,
                line in
                let state = lineState(
                    index: index,
                    activeIndex: activeIndex,
                    historical: historical
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.text)
                        .font(.system(
                            size: fontSize(
                                for: line.text,
                                availableWidth: availableWidth
                            ),
                            weight: state.isActive ? .black : .bold,
                            design: .rounded
                        ))
                        .tracking(state.isActive ? -1.2 : -0.6)
                        .foregroundStyle(state.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.56)
                        .shadow(
                            color: state.isActive
                                ? theme.accentColor.opacity(0.32)
                                : .black.opacity(0.72),
                            radius: state.isActive ? 18 : 4
                        )

                    if state.isActive,
                        let translation = line.translation,
                        !translation.isEmpty
                    {
                        Text(translation)
                            .font(.system(
                                size: 16,
                                weight: .semibold,
                                design: .rounded
                            ))
                            .foregroundStyle(
                                theme.primaryColor.opacity(0.58)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: availableWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: availableWidth, alignment: .leading)
        .compositingGroup()
    }

    private func lineState(
        index: Int,
        activeIndex: Int?,
        historical: Bool
    ) -> FoldingVerseLineState {
        if historical {
            return FoldingVerseLineState(
                color: theme.primaryColor.opacity(0.5),
                isActive: false
            )
        }
        guard let activeIndex else {
            return FoldingVerseLineState(
                color: theme.primaryColor.opacity(0.26),
                isActive: false
            )
        }
        if index == activeIndex {
            return FoldingVerseLineState(
                color: theme.accentColor,
                isActive: true
            )
        }
        return FoldingVerseLineState(
            color: theme.primaryColor.opacity(
                index < activeIndex ? 0.82 : 0.22
            ),
            isActive: false
        )
    }

    private func fontSize(
        for text: String,
        availableWidth: CGFloat
    ) -> CGFloat {
        let fitted = CGFloat(StageLyricTypography.fontSize(
            text: text,
            availableWidth: Double(availableWidth)
        ))
        return min(max(fitted * 0.72, 28), 72)
    }

    private func eased(_ progress: Double) -> CGFloat {
        let value = min(max(progress, 0), 1)
        return CGFloat(value * value * (3 - 2 * value))
    }
}

private struct FoldingVerseLineState {
    let color: Color
    let isActive: Bool
}

private struct StageFlowingLyricGlyph: View {
    @Environment(\.stageFoliaTheme) private var theme

    let glyph: StageLyricGlyphFrame
    let fontSize: CGFloat
    var isChorus = false

    var body: some View {
        let style = visualStyle
        ZStack {
            if StageLyricRenderPolicy.shouldRenderDynamicGlow(
                for: glyph.phase
            ) {
                Text(glyph.text)
                    .foregroundStyle(style.glowColor)
                    .blur(radius: style.glowRadius)
                    .opacity(style.glowOpacity)
            }

            Text(glyph.text)
                .foregroundStyle(style.bodyColor)
        }
        .font(.system(
            size: fontSize,
            weight: .bold,
            design: .rounded
        ))
        .tracking(fontSize * -0.018)
        .fixedSize()
        .blur(radius: style.blurRadius)
        .scaleEffect(style.scale * glyph.restingScale)
        .rotationEffect(.degrees(glyph.rotation * style.motionAmount))
        .offset(
            x: glyph.xOffset * style.motionAmount,
            y: glyph.yOffset * style.motionAmount + style.lift
        )
        .opacity(style.opacity)
    }

    private var visualStyle: StageFlowingGlyphStyle {
        switch glyph.phase {
        case .waiting:
            return StageFlowingGlyphStyle(
                bodyColor:
                    theme.primaryColor.opacity(0.26),
                glowColor: Color.clear,
                glowRadius: 0,
                glowOpacity: 0,
                opacity: 0.72,
                scale: 0.98,
                lift: 3,
                motionAmount: 0.08,
                blurRadius: 0.55
            )
        case .active:
            let pulse = 1.04 + sin(glyph.progress * .pi) * 0.035
            return StageFlowingGlyphStyle(
                bodyColor:
                    theme.semanticColor(for: glyph.text)
                        ?? (isChorus
                            ? theme.secondaryColor
                            : theme.primaryColor),
                glowColor:
                    isChorus
                        ? theme.secondaryColor
                        : theme.accentColor,
                glowRadius: 10 + sin(glyph.progress * .pi) * 8,
                glowOpacity: 0.7,
                opacity: 1,
                scale: pulse,
                lift: -2 - sin(glyph.progress * .pi) * 4,
                motionAmount: 0.18,
                blurRadius: 0
            )
        case .passed:
            return StageFlowingGlyphStyle(
                bodyColor:
                    isChorus
                        ? theme.secondaryColor.opacity(0.88)
                        : theme.accentColor.opacity(0.88),
                glowColor: Color.clear,
                glowRadius: 0,
                glowOpacity: 0,
                opacity: 0.96,
                scale: 1,
                lift: 0,
                motionAmount: 0.04,
                blurRadius: 0
            )
        }
    }
}

private struct StageFlowingGlyphStyle {
    let bodyColor: Color
    let glowColor: Color
    let glowRadius: Double
    let glowOpacity: Double
    let opacity: Double
    let scale: Double
    let lift: Double
    let motionAmount: Double
    let blurRadius: Double
}

private struct StageCinematicSplitLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFlowSceneModel
    let playbackTime: TimeInterval
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let layout = StageTiltLayoutModel(line: line)
                let fontSize = CGFloat(StageLyricTypography.fontSize(
                    text: line.text,
                    availableWidth: Double(proxy.size.width * 0.76)
                ))
                VStack(alignment: .leading, spacing: fontSize * 0.08) {
                    ForEach(layout.segments) { segment in
                        if playbackTime >= segment.revealAt {
                            Text(segment.text)
                                .font(.system(
                                    size: segment.isTilted
                                        ? fontSize * 1.14
                                        : fontSize,
                                    weight: segment.isTilted
                                        ? .light
                                        : .bold,
                                    design: .rounded
                                ))
                                .italic(segment.isTilted)
                                .foregroundStyle(
                                    segment.isTilted
                                        ? LinearGradient(
                                            colors: [
                                                theme.secondaryColor,
                                                theme.accentColor,
                                                theme.primaryColor,
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                        : LinearGradient(
                                            colors: [
                                                theme.primaryColor,
                                                theme.primaryColor.opacity(0.76),
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                )
                                .shadow(
                                    color: segment.isTilted
                                        ? theme.accentColor.opacity(0.32)
                                        : .black.opacity(0.72),
                                    radius: segment.isTilted ? 18 : 5
                                )
                                .offset(
                                    x: proxy.size.width * segment.xOffset,
                                    y: audio.beatLift
                                        * (segment.isTilted ? 0.22 : 0.08)
                                )
                                .rotationEffect(
                                    .degrees(segment.isTilted ? -7 : 0),
                                    anchor: .leading
                                )
                                .scaleEffect(
                                    segment.isTilted
                                        ? 1 + audio.mid * 0.045
                                        : 1,
                                    anchor: .leading
                                )
                                .transition(
                                    .opacity.combined(
                                        with: .offset(
                                            x: segment.isTilted ? 34 : -22,
                                            y: 0
                                        )
                                    )
                                )
                                .id(segment.id)
                        }
                    }

                    if let translation = scene.translation {
                        Text(translation)
                            .font(.system(
                                size: max(15, fontSize * 0.2),
                                weight: .medium,
                                design: .rounded
                            ))
                            .foregroundStyle(theme.primaryColor.opacity(0.56))
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
                .animation(
                    .spring(response: 0.55, dampingFraction: 0.82),
                    value: layout.segments.filter {
                        playbackTime >= $0.revealAt
                    }.count
                )
                .frame(
                    maxWidth: proxy.size.width * 0.78,
                    maxHeight: .infinity,
                    alignment: .leading
                )
                .padding(.leading, max(62, proxy.size.width * 0.08))
                .offset(
                    x: isProgramRailVisible ? -104 : 0,
                    y: -14
                )
                .rotation3DEffect(
                    .degrees(-4),
                    axis: (x: 0.02, y: 1, z: 0),
                    anchor: .leading,
                    perspective: 0.76
                )
                .id(line.id)
                .transition(
                    .opacity.combined(
                        with: .move(edge: .leading)
                    )
                )
            }
        }
    }
}

private struct StageOrbitLyricsFrame: View {
    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let animationTime: TimeInterval
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let count = max(scene.glyphs.count, 1)
                let fontSize = min(
                    72,
                    max(26, proxy.size.width * 0.7 / CGFloat(count))
                )
                ZStack {
                    ForEach(
                        Array(scene.glyphs.enumerated()),
                        id: \.element.id
                    ) { index, glyph in
                        let unit = count == 1
                            ? 0.5
                            : Double(index) / Double(count - 1)
                        let angle = (unit - 0.5) * 1.58
                        StageFlowingLyricGlyph(
                            glyph: glyph,
                            fontSize: fontSize,
                            isChorus: scene.isChorus
                        )
                        .rotation3DEffect(
                            .degrees((unit - 0.5) * -34),
                            axis: (x: 0.12, y: 1, z: 0),
                            perspective: 0.7
                        )
                        .offset(
                            x: sin(angle)
                                * min(430, proxy.size.width * 0.38)
                                * audio.expansion,
                            y: cos(angle) * -92
                                + sin(animationTime * 0.55 + unit * 4) * 4
                                + audio.beatLift * (0.12 + unit * 0.1)
                        )
                    }

                    if let translation = scene.translation {
                        Text(translation)
                            .font(.system(
                                size: 17,
                                weight: .medium,
                                design: .rounded
                            ))
                            .foregroundStyle(.white.opacity(0.58))
                            .offset(y: 78)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(x: isProgramRailVisible ? -150 : 0, y: -18)
                .id(line.id)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }
}

private struct StagePosterRailLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let lines: [StageLyricLine]
    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let rail = StageMonetRailModel(
                    lines: lines,
                    activeLineID: line.id
                )
                let fontSize = CGFloat(StageLyricTypography.fontSize(
                    text: line.text,
                    availableWidth: Double(proxy.size.width * 0.58)
                ))

                HStack(spacing: 28) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.9),
                                    theme.secondaryColor.opacity(0.4),
                                    .clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: 3 + audio.high * 2,
                            height: min(520, proxy.size.height * 0.7)
                                * audio.expansion
                        )

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(rail.entries) { entry in
                            monetRailEntry(
                                entry,
                                fontSize: fontSize,
                                maxWidth: proxy.size.width * 0.62
                            )
                            .offset(
                                x: CGFloat(abs(entry.offset)) * 18
                                    + (entry.offset > 0 ? 12 : 0)
                            )
                            .blur(
                                radius: entry.status == .active
                                    ? 0
                                    : Double(abs(entry.offset)) * 0.34
                            )
                            .transition(
                                .opacity.combined(
                                    with: .offset(
                                        x: 0,
                                        y: entry.offset > 0 ? 24 : -24
                                    )
                                )
                            )
                        }
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .leading
                )
                .padding(.leading, max(60, proxy.size.width * 0.075))
                .offset(x: isProgramRailVisible ? -96 : 0)
                .id(line.id)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func monetRailEntry(
        _ entry: StageMonetRailEntry,
        fontSize: CGFloat,
        maxWidth: CGFloat
    ) -> some View {
        if entry.status == .active {
            VStack(alignment: .leading, spacing: 10) {
                HStack(
                    alignment: .firstTextBaseline,
                    spacing: fontSize * 0.012
                ) {
                    ForEach(scene.glyphs) { glyph in
                        StageFlowingLyricGlyph(
                            glyph: glyph,
                            fontSize: fontSize,
                            isChorus: scene.isChorus
                        )
                    }
                }
                .fixedSize()
                .scaleEffect(
                    x: audio.expansion,
                    y: 1 + audio.mid * 0.025,
                    anchor: .leading
                )

                if let translation = scene.translation {
                    Text(translation)
                        .font(.system(
                            size: max(15, fontSize * 0.2),
                            weight: .medium,
                            design: .rounded
                        ))
                        .foregroundStyle(theme.primaryColor.opacity(0.54))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.vertical, 10)
            .shadow(
                color: theme.accentColor.opacity(0.18 + audio.glow * 0.18),
                radius: 22
            )
        } else {
            Text(entry.line.text)
                .font(.system(
                    size: min(max(fontSize * 0.34, 17), 28),
                    weight: entry.status == .passed ? .medium : .semibold,
                    design: .rounded
                ))
                .foregroundStyle(
                    entry.status == .passed
                        ? theme.secondaryColor.opacity(
                            0.16 + 0.05 / Double(abs(entry.offset))
                        )
                        : theme.primaryColor.opacity(
                            0.34 - Double(abs(entry.offset) - 1) * 0.07
                        )
                )
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: maxWidth * 0.82, alignment: .leading)
        }
    }
}

private struct StageEditorialLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let lines: [StageLyricLine]
    let scene: StageLyricFlowSceneModel
    let playbackTime: TimeInterval
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let activeLine = scene.activeLine {
                let fontSize = CGFloat(StageLyricTypography.fontSize(
                    text: activeLine.text,
                    availableWidth: Double(proxy.size.width * 0.62)
                ))
                let article = StageFumeArticleModel(
                    lines: lines,
                    activeLineID: activeLine.id
                )

                ZStack {
                    ForEach(article.blocks, id: \.lineID) { block in
                        if block.lineID != activeLine.id {
                            articleContextBlock(
                                block,
                                cameraTarget: article.cameraTarget,
                                canvasSize: proxy.size
                            )
                        }
                    }

                    VStack(spacing: 16) {
                        HStack(
                            alignment: .firstTextBaseline,
                            spacing: fontSize * 0.012
                        ) {
                            ForEach(scene.glyphs) { glyph in
                                StageFlowingLyricGlyph(
                                    glyph: glyph,
                                    fontSize: fontSize,
                                    isChorus: scene.isChorus
                                )
                            }
                        }
                        .fixedSize()
                        .frame(maxWidth: proxy.size.width * 0.64)

                        if let translation = scene.translation {
                            Text(translation)
                                .font(.system(
                                    size: max(15, fontSize * 0.19),
                                    weight: .medium,
                                    design: .rounded
                                ))
                                .foregroundStyle(
                                    theme.primaryColor.opacity(0.58)
                                )
                                .lineLimit(2)
                                .frame(maxWidth: 680)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 26)
                    .background {
                        RoundedRectangle(cornerRadius: 34)
                            .fill(.black.opacity(0.16))
                            .overlay {
                                RoundedRectangle(cornerRadius: 34)
                                    .stroke(.white.opacity(0.08), lineWidth: 1)
                            }
                    }
                    .shadow(
                        color: scene.isChorus
                            ? theme.secondaryColor.opacity(0.2)
                            : theme.accentColor.opacity(0.18),
                        radius: 32
                    )
                    .position(
                        x: proxy.size.width * 0.5
                            + (isProgramRailVisible ? -140 : 0),
                        y: proxy.size.height * 0.5 + audio.beatLift * 0.2
                    )
                    .scaleEffect(audio.expansion)
                    .id(activeLine.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
    }

    private func articleContextBlock(
        _ block: StageFumeArticleBlock,
        cameraTarget: SIMD2<Double>,
        canvasSize: CGSize
    ) -> some View {
        let distance = abs(block.position.y - cameraTarget.y)
        let isLeading = block.position.x < 0.5
        let fontSize = 17 + max(0, 1 - distance * 4) * 8
        let opacity = max(0.07, 0.34 - distance * 0.72)
        let x = canvasSize.width
            * (0.5 + (block.position.x - cameraTarget.x) * 1.45)
        let y = canvasSize.height
            * (0.5 + (block.position.y - cameraTarget.y) * 2.25)

        return Text(block.text)
            .font(.system(
                size: fontSize,
                weight: .semibold,
                design: .rounded
            ))
            .foregroundStyle(theme.primaryColor.opacity(opacity))
            .lineLimit(3)
            .multilineTextAlignment(isLeading ? .leading : .trailing)
            .frame(
                width: canvasSize.width * min(block.width, 0.42),
                alignment: isLeading ? .leading : .trailing
            )
            .position(x: x, y: y)
            .blur(radius: min(distance * 3.2, 2.2))
    }
}

private struct StageCloudStepsLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let count = max(scene.glyphs.count, 1)
                let layout = StagePartitaLayoutModel(
                    glyphIDs: scene.glyphs.map(\.id),
                    lineID: line.id,
                    isChorus: scene.isChorus
                )
                let fontSize = min(
                    68,
                    max(25, proxy.size.width * 0.7 / CGFloat(count))
                )

                ZStack {
                    ForEach(
                        Array(layout.placements.enumerated()),
                        id: \.element.glyphID
                    ) { index, placement in
                        let glyph = scene.glyphs[index]
                        let x = proxy.size.width * (0.5 + placement.x)
                            + (isProgramRailVisible ? -140 : 0)
                        let y = proxy.size.height * (0.5 + placement.y)

                        StageFlowingLyricGlyph(
                            glyph: glyph,
                            fontSize: fontSize,
                            isChorus: scene.isChorus
                        )
                        .rotation3DEffect(
                            .degrees(placement.rotationDegrees * 0.72),
                            axis: (x: 0.08, y: 1, z: 0),
                            perspective: 0.72
                        )
                        .rotationEffect(
                            .degrees(placement.rotationDegrees * 0.28)
                        )
                        .scaleEffect(
                            placement.scale
                                * (1 + audio.sceneEnergy * 0.025)
                        )
                        .position(x: x, y: y)
                    }

                    if let translation = scene.translation {
                        Text(translation)
                            .font(.system(
                                size: 15,
                                weight: .medium,
                                design: .rounded
                            ))
                            .tracking(0.8)
                            .foregroundStyle(
                                theme.primaryColor.opacity(0.48)
                            )
                            .lineLimit(2)
                            .frame(width: min(520, proxy.size.width * 0.5))
                            .position(
                                x: proxy.size.width * 0.5
                                    + (isProgramRailVisible ? -140 : 0),
                                y: proxy.size.height * 0.84
                            )
                    }
                }
                .scaleEffect(audio.expansion)
                .id(line.id)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

private struct StageChorusChatLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let fontSize = CGFloat(StageLyricTypography.fontSize(
                    text: line.text,
                    availableWidth: Double(proxy.size.width * 0.5)
                ))
                let conversation = StageCappellaConversationModel(
                    previousLineID: scene.previousLine?.id,
                    activeLineID: line.id,
                    nextLineID: scene.nextLine?.id,
                    isChorus: scene.isChorus
                )
                VStack(spacing: 18) {
                    if let previous = scene.previousLine {
                        contextBubble(
                            previous.text,
                            voice: conversation.previousVoice,
                            isTrailing: true
                        )
                    }

                    HStack(spacing: 12) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.accentColor,
                                        theme.secondaryColor,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(
                                    systemName:
                                        conversation.activeVoice.symbolName
                                )
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(theme.primaryColor)
                            }
                            .shadow(
                                color: theme.accentColor.opacity(audio.glow),
                                radius: 10 + audio.high * 10
                            )

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(
                                alignment: .firstTextBaseline,
                                spacing: fontSize * 0.012
                            ) {
                                ForEach(scene.glyphs) { glyph in
                                    StageFlowingLyricGlyph(
                                        glyph: glyph,
                                        fontSize: fontSize,
                                        isChorus: scene.isChorus
                                    )
                                }
                            }
                            .fixedSize()

                            if let translation = scene.translation {
                                Text(translation)
                                    .font(.system(
                                        size: max(14, fontSize * 0.19),
                                        weight: .medium,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(
                                        theme.primaryColor.opacity(0.56)
                                    )
                                    .lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .background {
                            UnevenRoundedRectangle(
                                topLeadingRadius: 8,
                                bottomLeadingRadius: 30,
                                bottomTrailingRadius: 30,
                                topTrailingRadius: 30
                            )
                            .fill(.black.opacity(0.32))
                            .overlay {
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 8,
                                    bottomLeadingRadius: 30,
                                    bottomTrailingRadius: 30,
                                    topTrailingRadius: 30
                                )
                                .stroke(
                                    scene.isChorus
                                        ? theme.secondaryColor.opacity(0.46)
                                        : theme.accentColor.opacity(0.34),
                                    lineWidth: 1
                                )
                            }
                        }
                    }
                    .scaleEffect(audio.expansion, anchor: .leading)
                    .offset(y: audio.beatLift * 0.18)

                    if let next = scene.nextLine {
                        contextBubble(
                            next.text,
                            voice: conversation.nextVoice,
                            isTrailing: false
                        )
                    }
                }
                .frame(maxWidth: min(860, proxy.size.width * 0.72))
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
                .offset(x: isProgramRailVisible ? -140 : 0)
                .id(line.id)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private func contextBubble(
        _ text: String,
        voice: StageCappellaVoice,
        isTrailing: Bool
    ) -> some View {
        HStack(spacing: 9) {
            if isTrailing {
                Spacer(minLength: 40)
            }
            Circle()
                .fill(theme.secondaryColor.opacity(0.12))
                .frame(width: 27, height: 27)
                .overlay {
                    Image(systemName: voice.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            theme.secondaryColor.opacity(0.72)
                        )
                }
            Text(text)
                .font(.system(
                    size: 18,
                    weight: .medium,
                    design: .rounded
                ))
                .foregroundStyle(theme.primaryColor.opacity(0.36))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background {
                    Capsule()
                        .fill(theme.primaryColor.opacity(0.045))
                        .overlay {
                            Capsule()
                                .stroke(
                                    theme.primaryColor.opacity(0.08),
                                    lineWidth: 0.8
                                )
                        }
                }
            if !isTrailing {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StagePendulumLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let lines: [StageLyricLine]
    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let animationTime: TimeInterval
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let wheel = StagePendoloWheelModel(
                    lines: lines,
                    activeLineID: line.id
                )
                let radius = min(proxy.size.width, proxy.size.height) * 0.48
                    * audio.expansion
                let center = CGPoint(
                    x: proxy.size.width * 0.04
                        + (isProgramRailVisible ? -140 : 0),
                    y: proxy.size.height * 0.5
                )

                ZStack {
                    Circle()
                        .trim(from: 0, to: 0.5)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    theme.secondaryColor.opacity(0.1),
                                    theme.accentColor.opacity(0.58),
                                    theme.primaryColor.opacity(0.18),
                                    theme.secondaryColor.opacity(0.1),
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(
                                lineWidth: 1.2 + audio.high * 1.4,
                                lineCap: .round
                            )
                        )
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)
                        .rotationEffect(.degrees(-90))

                    Circle()
                        .trim(from: 0.04, to: 0.46)
                        .stroke(
                            theme.primaryColor.opacity(
                                0.035 + audio.glow * 0.08
                            ),
                            lineWidth: 20 + audio.low * 10
                        )
                        .frame(
                            width: radius * 1.88,
                            height: radius * 1.88
                        )
                        .position(center)
                        .rotationEffect(.degrees(-90))

                    ForEach(wheel.items) { item in
                        let point = CGPoint(
                            x: center.x + item.x * radius,
                            y: center.y + item.y * radius
                        )

                        pendoloLine(
                            item,
                            activeLine: line,
                            maxWidth: proxy.size.width * 0.56
                        )
                        .rotationEffect(
                            .degrees(item.angleDegrees * 0.16),
                            anchor: .leading
                        )
                        .scaleEffect(item.scale, anchor: .leading)
                        .opacity(item.opacity)
                        .position(point)
                    }

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    theme.primaryColor.opacity(0.8),
                                    theme.accentColor.opacity(0.46),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 34
                            )
                        )
                        .frame(
                            width: 28 + audio.beat * 14,
                            height: 28 + audio.beat * 14
                        )
                        .position(
                            x: center.x,
                            y: center.y
                        )
                        .shadow(
                            color: theme.accentColor.opacity(audio.glow),
                            radius: 12 + audio.high * 10
                        )
                }
                .id(line.id)
                .transition(.opacity)
                .animation(
                    .spring(response: 0.72, dampingFraction: 0.86),
                    value: line.id
                )
            }
        }
    }

    @ViewBuilder
    private func pendoloLine(
        _ item: StagePendoloWheelItem,
        activeLine: StageLyricLine,
        maxWidth: CGFloat
    ) -> some View {
        if item.isActive {
            let fontSize = CGFloat(StageLyricTypography.fontSize(
                text: activeLine.text,
                availableWidth: Double(maxWidth)
            ))
            HStack(
                alignment: .firstTextBaseline,
                spacing: fontSize * 0.012
            ) {
                ForEach(scene.glyphs) { glyph in
                    StageFlowingLyricGlyph(
                        glyph: glyph,
                        fontSize: fontSize,
                        isChorus: scene.isChorus
                    )
                }
            }
            .fixedSize()
            .shadow(
                color: theme.accentColor.opacity(0.22 + audio.glow * 0.2),
                radius: 18
            )
        } else {
            Text(item.line.text)
                .font(.system(
                    size: 24,
                    weight: .semibold,
                    design: .rounded
                ))
                .foregroundStyle(
                    item.angleDegrees < 0
                        ? theme.secondaryColor.opacity(0.68)
                        : theme.primaryColor.opacity(0.72)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.74)
                .frame(maxWidth: maxWidth * 0.72, alignment: .leading)
        }
    }
}

private struct StageDioramaLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let animationTime: TimeInterval
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let centerX = proxy.size.width * 0.5
                    + (isProgramRailVisible ? -140 : 0)
                ZStack {
                    particleField(size: proxy.size)

                    if let previous = scene.previousLine {
                        dioramaPanel(
                            previous.text,
                            width: min(520, proxy.size.width * 0.46),
                            opacity: 0.2
                        )
                        .rotation3DEffect(
                            .degrees(34),
                            axis: (x: 0.08, y: 1, z: 0),
                            perspective: 0.68
                        )
                        .position(
                            x: centerX - proxy.size.width * 0.27,
                            y: proxy.size.height * 0.3
                        )
                        .scaleEffect(0.76)
                    }

                    if let next = scene.nextLine {
                        dioramaPanel(
                            next.text,
                            width: min(520, proxy.size.width * 0.46),
                            opacity: 0.28
                        )
                        .rotation3DEffect(
                            .degrees(-38),
                            axis: (x: 0.06, y: 1, z: 0),
                            perspective: 0.68
                        )
                        .position(
                            x: centerX + proxy.size.width * 0.28,
                            y: proxy.size.height * 0.7
                        )
                        .scaleEffect(0.82)
                    }

                    activePanel(
                        line: line,
                        availableWidth: proxy.size.width * 0.6
                    )
                    .position(
                        x: centerX,
                        y: proxy.size.height * 0.5 + audio.beatLift * 0.22
                    )
                    .scaleEffect(audio.expansion)
                    .rotation3DEffect(
                        .degrees(sin(animationTime * 0.23) * 2.4),
                        axis: (x: 0.04, y: 1, z: 0),
                        perspective: 0.72
                    )
                }
                .id(line.id)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }

    private func activePanel(
        line: StageLyricLine,
        availableWidth: CGFloat
    ) -> some View {
        let fontSize = CGFloat(StageLyricTypography.fontSize(
            text: line.text,
            availableWidth: Double(availableWidth)
        ))
        return VStack(spacing: 14) {
            HStack(
                alignment: .firstTextBaseline,
                spacing: fontSize * 0.012
            ) {
                ForEach(scene.glyphs) { glyph in
                    StageFlowingLyricGlyph(
                        glyph: glyph,
                        fontSize: fontSize,
                        isChorus: scene.isChorus
                    )
                }
            }
            .fixedSize()

            if let translation = scene.translation {
                Text(translation)
                    .font(.system(
                        size: max(15, fontSize * 0.18),
                        weight: .medium,
                        design: .rounded
                    ))
                    .foregroundStyle(theme.primaryColor.opacity(0.54))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .background {
            RoundedRectangle(cornerRadius: 28)
                .fill(.black.opacity(0.26))
                .overlay {
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.5),
                                    theme.secondaryColor.opacity(0.24),
                                    theme.primaryColor.opacity(0.38),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
        .shadow(
            color: theme.accentColor.opacity(audio.glow * 0.7),
            radius: 26 + audio.high * 18
        )
    }

    private func dioramaPanel(
        _ text: String,
        width: CGFloat,
        opacity: Double
    ) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.primaryColor.opacity(opacity))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .padding(.vertical, 22)
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white.opacity(0.025))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(.white.opacity(0.07), lineWidth: 0.8)
                    }
            }
    }

    private func particleField(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let energy = max(audio.particleEnergy, 0.08)
            for index in 0 ..< 180 {
                let seed = Double(index) * 12.9898
                let unitX = abs(sin(seed * 0.71)) * canvasSize.width
                let unitY = abs(cos(seed * 1.17)) * canvasSize.height
                let drift = sin(animationTime * (0.16 + audio.mid * 0.2)
                    + seed) * (8 + energy * 24)
                let depth = 0.35 + abs(sin(seed * 0.33)) * 0.65
                let diameter = 0.7 + depth * (1.5 + audio.onset * 2.4)
                let point = CGRect(
                    x: unitX + drift,
                    y: unitY + cos(animationTime * 0.2 + seed) * 7,
                    width: diameter,
                    height: diameter
                )
                let color: Color = switch index % 3 {
                case 0:
                    theme.accentColor
                case 1:
                    theme.secondaryColor
                default:
                    theme.primaryColor
                }
                context.fill(
                    Path(ellipseIn: point),
                    with: .color(color.opacity(0.12 + energy * 0.28))
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .blur(radius: 0.2 + audio.low * 0.7)
    }
}

private struct StageDepthLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricSceneModel
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        ZStack {
            ForEach(scene.lines) { line in
                lyricLine(line)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            .easeOut(duration: 0.26),
            value: scene.lines.first(where: { $0.position == 0 })?.id
        )
    }

    private func lyricLine(_ line: StageLyricSceneLine) -> some View {
        let isCurrent = line.position == 0
        let railOffset = isProgramRailVisible ? -150.0 : 0
        let xOffset = railOffset + Double(line.position) * 92
        let yOffset = Double(line.position) * 96
            + (isCurrent ? audio.beatLift * 0.24 : 0)
        let glow = isCurrent
            ? theme.accentColor.opacity(0.5)
            : Color.black.opacity(0.72)

        return Text(line.text)
            .font(.system(
                size: isCurrent ? 38 : 24,
                weight: isCurrent ? .bold : .semibold,
                design: .rounded
            ))
            .tracking(isCurrent ? 0.4 : 0.1)
            .foregroundStyle(lyricGradient(isCurrent: isCurrent))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: isCurrent ? 760 : 620)
            .shadow(color: glow, radius: isCurrent ? 18 : 7)
            .shadow(color: .black.opacity(0.96), radius: 4)
            .opacity(line.opacity)
            .blur(radius: line.blurRadius)
            .scaleEffect(
                line.scale * (isCurrent ? audio.expansion : 1)
            )
            .rotation3DEffect(
                .degrees(Double(line.position) * -12),
                axis: (x: 0.08, y: 1, z: 0),
                perspective: 0.68
            )
            .offset(x: xOffset, y: yOffset)
            .zIndex(isCurrent ? 6 : 2)
    }

    private func lyricGradient(isCurrent: Bool) -> LinearGradient {
        LinearGradient(
            colors: isCurrent
                ? [
                    theme.primaryColor,
                    theme.accentColor,
                ]
                : [
                    theme.primaryColor.opacity(0.76),
                    theme.accentColor.opacity(0.5),
                ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

@MainActor
final class StageOverlayState: ObservableObject {
    @Published private(set) var isProgramRailVisible = false

    func setProgramRailVisible(_ isVisible: Bool) {
        isProgramRailVisible = isVisible
    }
}

enum StageVisualPickerMode: Equatable {
    case space
    case player

    static func resolve(isWorldPresentationRequested: Bool) -> Self {
        isWorldPresentationRequested ? .space : .player
    }
}

enum StageVisualPickerGroup: Equatable {
    case worldSelection
    case avatarPlacement
    case loadingStatus
    case lyricsEffects
    case pointCloud
    case particleSize
    case musicVideo

    static func visibleGroups(
        for mode: StageVisualPickerMode
    ) -> [Self] {
        switch mode {
        case .space:
            [.worldSelection, .avatarPlacement, .loadingStatus]
        case .player:
            [.lyricsEffects, .pointCloud, .particleSize, .musicVideo]
        }
    }
}

enum StageControlPanelTab: String, Hashable {
    case visuals, motions, activities

    static func available(for mode: StageVisualPickerMode) -> [Self] {
        mode == .space ? [.visuals, .motions, .activities] : [.visuals, .motions]
    }

    func resolved(for mode: StageVisualPickerMode) -> Self {
        Self.available(for: mode).contains(self) ? self : .visuals
    }

    func title(for mode: StageVisualPickerMode) -> String {
        switch self {
        case .visuals: mode == .space ? "空间" : "画面"
        case .motions: "角色动作"
        case .activities: "生活活动"
        }
    }
}

enum StageControlPanelLayout {
    static let maximumWidth: CGFloat = 590
    static let maximumHeight: CGFloat = 458
    static let settingsLeading: CGFloat = 229
    static let settingsWidth: CGFloat = 80
    static let transportWidth: CGFloat = 358
}

enum StageActivityAvailability {
    static func canRun(
        isWorldVisible: Bool,
        selectedWorldID: String?,
        activityWorldID: String?
    ) -> Bool {
        isWorldVisible && selectedWorldID != nil && selectedWorldID == activityWorldID
    }
}

@MainActor
struct StageVisualPickerView: View {
    @ObservedObject var lyrics: StageLyricsStore
    @ObservedObject var visualDirections: StageVisualDirectionStore
    @ObservedObject var videos: StageVideoPlaybackStore
    @Bindable var programStore: DJProgramStore
    @Bindable var spatialStage: SpatialStageStore
    @Bindable var marbleLibrary: MarbleWorldLibrary
    @Bindable var avatarRuntime: StageAvatarRuntimeStore = .shared
    @ObservedObject private var activities = LivingWorldActivityMenuStore.shared
    @State private var model = PresenceSettingsModel()
    @State private var tab: StageControlPanelTab = .visuals
    var onRunActivity: @MainActor (String) -> Void = { _ in }
    var onStopActivity: @MainActor () -> Void = {}
    var onManageAssets: @MainActor () -> Void = {}

    private let lyricColumns = [GridItem(.adaptive(minimum: 72), spacing: 6)]
    private let pointCloudColumns = [GridItem(.adaptive(minimum: 100), spacing: 6)]

    private var mode: StageVisualPickerMode {
        .resolve(isWorldPresentationRequested: spatialStage.isWorldPresentationRequested)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("设置分区", selection: $tab) {
                ForEach(StageControlPanelTab.available(for: mode), id: \.self) { item in
                    Text(item.title(for: mode)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab.resolved(for: mode) {
                    case .visuals: visualGroups
                    case .motions: motionGroup
                    case .activities: activityGroup
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .padding(7)
        .onChange(of: mode) { _, newMode in tab = tab.resolved(for: newMode) }
        .onChange(of: tab) { _, newTab in
            if newTab == .motions { model.load() }
        }
        .onChange(of: avatarRuntime.snapshot.avatar?.id) { _, _ in
            if tab == .motions { model.load() }
        }
    }

    private var visualGroups: some View {
        let groups = StageVisualPickerGroup.visibleGroups(for: mode)
        return VStack(alignment: .leading, spacing: 12) {
            if groups.contains(.worldSelection) { worldSelectionGroup }
            if groups.contains(.avatarPlacement) { avatarPlacementGroup }
            if groups.contains(.loadingStatus) { loadingStatusGroup }
            if groups.contains(.lyricsEffects) { lyricsEffectsGroup }
            if groups.contains(.pointCloud) { pointCloudGroup }
            if groups.contains(.particleSize) { particleSizeGroup }
            if groups.contains(.musicVideo) { musicVideoGroup }
        }
    }

    private var motionGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(avatarRuntime.snapshot.name ?? "尚未选择角色", systemImage: "person.crop.circle")
                Spacer()
                Button("刷新") { model.load() }
            }
            Text("选择已安装动作；自然待机可结束当前表演。")
                .foregroundStyle(.secondary)
            ForEach(model.motions, id: \.id) { motion in
                let compatibility = model.motionCompatibility(motion)
                Button {
                    model.activateMotion(motion)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: avatarRuntime.snapshot.motion?.id == motion.id
                            ? "checkmark.circle.fill" : "figure.dance")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(motion.name)
                            if case let .incompatible(reason) = compatibility {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(compatibility != .compatible || model.isWorking)
            }
            if model.motions.isEmpty { Text("暂无可用动作，请在资产管理中安装。") }
            if let message = model.message {
                Text(message).foregroundStyle(model.hasError ? Color.orange : Color.secondary)
            }
            Button("管理角色与动作…", action: onManageAssets)
        }
        .font(.system(size: 12))
    }

    private var activityGroup: some View {
        let canRun = StageActivityAvailability.canRun(
            isWorldVisible: spatialStage.isWorldVisible,
            selectedWorldID: spatialStage.selectedWorldID,
            activityWorldID: activities.worldID
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text("活动来自当前空间，角色会走到对应位置再开始。")
                .foregroundStyle(.secondary)
            if canRun {
                ForEach(activities.items) { item in
                    Button { onRunActivity(item.id) } label: {
                        HStack {
                            Image(systemName: activities.activeActivityID == item.id
                                ? "checkmark.circle.fill" : "play.circle")
                            Text(item.name)
                            Spacer()
                        }
                        .padding(10)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                if activities.items.isEmpty { Text("这个空间还没有配置生活活动。") }
                Button("停止活动", action: onStopActivity)
                    .disabled(activities.activeActivityID == nil)
                if let message = activities.message { Text(message).foregroundStyle(.secondary) }
            } else {
                Text(spatialStage.isWorldVisible
                    ? "这个空间还没有配置生活活动。" : "空间载入完成后可选择活动。")
            }
        }
        .font(.system(size: 12))
    }

    private var worldSelectionGroup: some View {
        Menu {
            Section("公开空间") {
                ForEach(marbleLibrary.publicExampleWorlds) { world in
                    Button {
                        enter(worldID: world.id)
                    } label: {
                        if marbleLibrary.selectedWorld?.id == world.id {
                            Label(world.name, systemImage: "checkmark")
                        } else {
                            Text(world.name)
                        }
                    }
                }
            }
            Section("生成场景") {
                ForEach(SpatialScenePreset.allCases) { preset in
                    Button {
                        activate(preset: preset)
                    } label: {
                        Label(preset.displayName, systemImage: preset.symbolName)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe.americas.fill")
                Text(
                    marbleLibrary.selectedWorld?.isPublicExample == true
                        ? marbleLibrary.selectedWorld?.name ?? "公开空间"
                        : "公开空间 · 无需生成"
                )
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.68))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity)
    }

    private var avatarPlacementGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerHeader("人物位置", symbol: "figure.stand")

            VStack(spacing: 5) {
                avatarPositionSlider(
                    axis: .x,
                    range: -2 ... 2,
                    accessibilityLabel: "人物左右位置"
                )
                avatarPositionSlider(
                    axis: .y,
                    range: -2 ... 2,
                    accessibilityLabel: "人物上下位置"
                )
                avatarPositionSlider(
                    axis: .z,
                    range: -3 ... 3,
                    accessibilityLabel: "人物前后位置"
                )
            }

            HStack {
                Text("人物位置会按当前空间保存")
                    .foregroundStyle(.white.opacity(0.36))
                Spacer()
                Button("重置") {
                    spatialStage.resetAvatarPosition()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.cyan.opacity(0.78))
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))

            HStack {
                Text("W/S 沿视线前后移动，A/D 左右移动")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("镜头复位") { spatialStage.resetCamera() }
            }
            .font(.system(size: 10))
        }
    }

    @ViewBuilder
    private var loadingStatusGroup: some View {
        if spatialStage.isWorldPresentationRequested,
            !spatialStage.isWorldVisible
        {
            Label("正在载入空间，完成后自动进入…", systemImage: "cube.transparent")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.cyan.opacity(0.72))
                .lineLimit(1)
        } else if let message = marbleLibrary.generationMessage {
            Label(message, systemImage: "sparkles")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.cyan.opacity(0.72))
                .lineLimit(1)
        } else if let message = marbleLibrary.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.orange.opacity(0.78))
                .lineLimit(1)
        }
    }

    private var lyricsEffectsGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerHeader("字幕特效", symbol: "captions.bubble")

            LazyVGrid(columns: lyricColumns, spacing: 6) {
                ForEach(StageLyricsVisualMode.allCases, id: \.self) { mode in
                    pickerButton(
                        title: mode.displayName,
                        symbol: mode.symbolName,
                        isSelected: lyrics.visualMode == mode
                    ) {
                        lyrics.setVisualMode(mode)
                    }
                }
            }
        }
    }

    private var pointCloudGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerHeader("3D 点阵", symbol: "circle.hexagongrid")

            LazyVGrid(columns: pointCloudColumns, spacing: 6) {
                ForEach(StagePointCloudChoice.allCases, id: \.self) {
                    choice in
                    pickerButton(
                        title: choice.title,
                        symbol: choice.symbolName,
                        isSelected:
                            visualDirections.currentPointCloudChoice == choice
                    ) {
                        visualDirections.selectPointCloud(choice)
                    }
                }
            }
        }
    }

    private var particleSizeGroup: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.grid.2x2.fill")
                .foregroundStyle(.white.opacity(0.46))
            Slider(
                value: Binding(
                    get: {
                        Double(visualDirections.particleSizeMultiplier)
                    },
                    set: {
                        visualDirections.setParticleSizeMultiplier(
                            Float($0)
                        )
                    }
                ),
                in: Double(StageParticleSizing.manualRange.lowerBound)
                    ... Double(StageParticleSizing.manualRange.upperBound)
            )
            .tint(.cyan.opacity(0.86))
            .accessibilityLabel("颗粒大小")
            Text(
                "\(Int(visualDirections.particleSizeMultiplier * 100))%"
            )
            .monospacedDigit()
            .frame(width: 38, alignment: .trailing)
            .foregroundStyle(.white.opacity(0.5))
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    private var musicVideoGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerHeader("MV 场景", symbol: "film.stack")

            HStack(spacing: 6) {
                pickerButton(
                    title: "导入 MP4",
                    symbol: "plus",
                    isSelected: false,
                    action: importMP4
                )
                ForEach(StageVideoPlaybackMode.allCases, id: \.self) {
                    mode in
                    pickerButton(
                        title: mode.displayName,
                        symbol: mode.symbolName,
                        isSelected: videos.isActive && videos.mode == mode
                    ) {
                        videos.setMode(mode)
                    }
                }
                pickerButton(
                    title: "关闭",
                    symbol: "xmark",
                    isSelected: !videos.isActive && !videos.assets.isEmpty
                ) {
                    videos.stop()
                }
            }

            if !videos.assets.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "sun.min")
                        .foregroundStyle(.white.opacity(0.46))
                    Slider(
                        value: Binding(
                            get: { Double(videos.brightness) },
                            set: { videos.setBrightness(Float($0)) }
                        ),
                        in: 0.15 ... 1
                    )
                    .tint(.cyan.opacity(0.86))
                    .accessibilityLabel("视频亮度")
                    Text("\(Int(videos.brightness * 100))%")
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .frame(height: 24)

                Menu {
                    ForEach(videos.assets) { asset in
                        Menu(asset.displayName) {
                            Button(
                                videos.isActive
                                    && videos.activeAssetID == asset.id
                                    ? "取消加载"
                                    : "加载"
                            ) {
                                videos.toggle(asset.id)
                            }

                            if let track = programStore.activeSlot?.track {
                                if videos.boundAsset(for: track.id)?.id == asset.id {
                                    Button("解除当前歌曲绑定") {
                                        videos.unbind(trackID: track.id)
                                    }
                                } else {
                                    Button("绑定到当前歌曲") {
                                        videos.bind(asset.id, to: track.id)
                                    }
                                }
                            }

                            Divider()
                            Button("移出素材库", role: .destructive) {
                                videos.remove(asset.id)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(
                            systemName: videos.isActive
                                ? "video.fill"
                                : "video.slash"
                        )
                        Text(videos.activeAsset?.displayName ?? "未加载视频")
                            .lineLimit(1)
                        Spacer()
                        Text(
                            videos.isActive
                                ? "已加载"
                                : "\(videos.assets.count) 段"
                        )
                            .foregroundStyle(.white.opacity(0.38))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.045), in: Capsule())
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    private func pickerHeader(
        _ title: String,
        symbol: String
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(.white.opacity(0.6))
    }

    private func avatarPositionSlider(
        axis: SpatialAvatarPositionAxis,
        range: ClosedRange<Double>,
        accessibilityLabel: String
    ) -> some View {
        let value = avatarPositionValue(for: axis)
        return HStack(spacing: 9) {
            Text(axis.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))
                .frame(width: 12)
            Slider(
                value: Binding(
                    get: { Double(avatarPositionValue(for: axis)) },
                    set: {
                        spatialStage.setAvatarPosition(
                            Float($0),
                            axis: axis
                        )
                    }
                ),
                in: range,
                step: 0.01
            )
            .tint(.cyan.opacity(0.86))
            .accessibilityLabel(accessibilityLabel)
            Text(value.formatted(.number.precision(.fractionLength(2))))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.48))
                .frame(width: 42, alignment: .trailing)
        }
        .frame(height: 20)
    }

    private func avatarPositionValue(
        for axis: SpatialAvatarPositionAxis
    ) -> Float {
        let position = spatialStage.avatarPlacement.position
        switch axis {
        case .x:
            return position.x
        case .y:
            return position.y
        case .z:
            return position.z
        }
    }

    private func pickerButton(
        title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(
                        size: 10,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .lineLimit(1)
            }
            .foregroundStyle(
                isSelected
                    ? Color(red: 0.48, green: 0.95, blue: 1)
                    : Color.white.opacity(0.62)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(
                        isSelected
                            ? Color.cyan.opacity(0.16)
                            : Color.white.opacity(0.045)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(
                        isSelected
                            ? Color.cyan.opacity(0.52)
                            : Color.white.opacity(0.07),
                        lineWidth: isSelected ? 1 : 0.8
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func activate(preset: SpatialScenePreset) {
        spatialStage.requestWorldPresentation()
        Task {
            await marbleLibrary.activate(preset: preset)
            if marbleLibrary.errorMessage != nil {
                spatialStage.exitWorld()
            }
        }
    }

    private func enter(worldID: String) {
        spatialStage.requestWorldPresentation()
        Task {
            guard await marbleLibrary.select(worldID: worldID) != nil else {
                spatialStage.exitWorld()
                return
            }
        }
    }

    private func importMP4() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "导入"
        panel.message = "选择要与 3D 点阵叠加的 MP4 片段"
        guard panel.runModal() == .OK else {
            return
        }
        videos.add(panel.urls)
    }
}

struct StageProgramRailCard: Equatable, Identifiable {
    let slotIndex: Int
    let trackID: String
    let title: String
    let artist: String
    let energy: Double
    let relativeIndex: Int
    let isCurrent: Bool
    let depth: Int
    let opacity: Double
    let scale: Double

    var id: String {
        trackID
    }
}

enum StageProgramRailCardLayout {
    static func horizontalOffset(
        relativeIndex: Int,
        isFocused: Bool
    ) -> Double {
        if isFocused {
            return -30
        }
        return Double(min(2, abs(relativeIndex))) * 9
    }
}

struct StageProgramRailModel: Equatable {
    let title: String?
    let cards: [StageProgramRailCard]

    init(
        plan: ProgramPlan?,
        activeSlotIndex: Int?
    ) {
        guard let plan, !plan.slots.isEmpty else {
            self.init(
                title: plan?.title,
                tracks: [],
                activeIndex: nil
            )
            return
        }

        let activeIndex: Int?
        if
            let activeSlotIndex,
            plan.slots.indices.contains(activeSlotIndex)
        {
            activeIndex = activeSlotIndex
        } else {
            activeIndex = nil
        }

        self.init(
            title: plan.title,
            tracks: plan.slots.map(\.track),
            activeIndex: activeIndex
        )
    }

    init(
        playlist: MusicPlaylistSnapshot,
        activeTrackID: String?
    ) {
        self.init(
            title: playlist.name,
            tracks: playlist.tracks,
            activeIndex: activeTrackID.flatMap { activeTrackID in
                playlist.tracks.firstIndex { $0.id == activeTrackID }
            }
        )
    }

    private init(
        title: String?,
        tracks: [MusicCandidate],
        activeIndex: Int?
    ) {
        self.title = title
        cards = tracks.enumerated().map { absoluteIndex, track in
            let relativeIndex = activeIndex.map {
                absoluteIndex - $0
            } ?? absoluteIndex
            let isCurrent = absoluteIndex == activeIndex
            let distance = abs(relativeIndex)
            let visualDistance = min(distance, 2)
            return StageProgramRailCard(
                slotIndex: absoluteIndex,
                trackID: track.id,
                title: track.title,
                artist: track.artist,
                energy: track.energy,
                relativeIndex: relativeIndex,
                isCurrent: isCurrent,
                depth: visualDistance * -72,
                opacity: isCurrent
                    ? 1
                    : max(
                        relativeIndex < 0 ? 0.34 : 0.46,
                        1 - Double(visualDistance) * 0.16
                    ),
                scale: isCurrent
                    ? 1
                    : max(
                        0.78,
                        1 - Double(visualDistance) * 0.055
                    )
            )
        }
    }
}

@MainActor
enum StageProgramRailRoute: Equatable {
    case programs
    case tracks(programID: String)
    case playlistTracks(playlistID: String)
}

enum StageProgramRailCatalog {
    static func visiblePrograms(
        _ programs: [SavedDJProgram],
        syncedPlaylists: [MusicPlaylistSnapshot]
    ) -> [SavedDJProgram] {
        let syncedIDs = Set(syncedPlaylists.map(\.id))
        return programs.filter {
            !syncedIDs.contains($0.plan.brief.id)
        }
    }
}

@MainActor
final class StageProgramRailSelection: ObservableObject {
    @Published private(set) var route = StageProgramRailRoute.programs
    @Published private(set) var selectedProgramID: String?
    @Published private(set) var selectedPlaylistID: String?
    @Published private(set) var selectedSlotIndex: Int?
    private let onPlay: @MainActor (String, Int) -> Void
    private let onReplan: @MainActor () -> Void
    private let onPlayPlaylist: @MainActor (String, Int) -> Void
    private let onOpenPlaylist: @MainActor (String) -> Void
    private let onLoadMorePlaylist: @MainActor (String) -> Void

    init(
        onPlay: @escaping @MainActor (String, Int) -> Void = { _, _ in },
        onPlayPlaylist:
            @escaping @MainActor (String, Int) -> Void = { _, _ in },
        onOpenPlaylist:
            @escaping @MainActor (String) -> Void = { _ in },
        onLoadMorePlaylist:
            @escaping @MainActor (String) -> Void = { _ in },
        onReplan: @escaping @MainActor () -> Void = {}
    ) {
        self.onPlay = onPlay
        self.onPlayPlaylist = onPlayPlaylist
        self.onOpenPlaylist = onOpenPlaylist
        self.onLoadMorePlaylist = onLoadMorePlaylist
        self.onReplan = onReplan
    }

    func openProgram(_ programID: String) {
        selectedProgramID = programID
        selectedPlaylistID = nil
        selectedSlotIndex = nil
        route = .tracks(programID: programID)
    }

    func openPlaylist(_ playlistID: String) {
        selectedPlaylistID = playlistID
        selectedProgramID = nil
        selectedSlotIndex = nil
        route = .playlistTracks(playlistID: playlistID)
        onOpenPlaylist(playlistID)
    }

    func showPrograms() {
        selectedSlotIndex = nil
        route = .programs
    }

    func activate(slotIndex: Int) {
        selectedSlotIndex = slotIndex
        switch route {
        case let .tracks(programID):
            onPlay(programID, slotIndex)
        case let .playlistTracks(playlistID):
            onPlayPlaylist(playlistID, slotIndex)
        case .programs:
            break
        }
    }

    func replan() {
        onReplan()
    }

    func loadMoreSelectedPlaylist() {
        guard let selectedPlaylistID else {
            return
        }
        onLoadMorePlaylist(selectedPlaylistID)
    }
}

@MainActor
struct StageProgramRailView: View {
    @Bindable var programStore: DJProgramStore
    @Bindable var libraryStore: SyncedMusicLibraryStore
    @ObservedObject var selection: StageProgramRailSelection
    @ObservedObject var videos: StageVideoPlaybackStore
    let audioFeatures: VisualAudioFeatureStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var programs: [SavedDJProgram] {
        let candidates: [SavedDJProgram]
        if !programStore.recentPrograms.isEmpty {
            candidates = programStore.recentPrograms
        } else if let plan = programStore.plan {
            candidates = [
                SavedDJProgram(
                    plan: plan,
                    activeSlotIndex: programStore.activeSlotIndex,
                    updatedAt: plan.generatedAt
                ),
            ]
        } else {
            candidates = []
        }
        return StageProgramRailCatalog.visiblePrograms(
            candidates,
            syncedPlaylists: libraryStore.playlists
        )
    }

    private var selectedProgram: SavedDJProgram? {
        guard let selectedProgramID = selection.selectedProgramID else {
            return nil
        }
        return programs.first {
            $0.plan.brief.id == selectedProgramID
        }
    }

    private var selectedPlaylist: MusicPlaylistSnapshot? {
        guard let selectedPlaylistID = selection.selectedPlaylistID else {
            return nil
        }
        return libraryStore.playlist(id: selectedPlaylistID)
    }

    private var trackModel: StageProgramRailModel {
        if let selectedPlaylist {
            return StageProgramRailModel(
                playlist: selectedPlaylist,
                activeTrackID: programStore.plan?.brief.id == selectedPlaylist.id
                    ? programStore.activeSlot?.track.id
                    : nil
            )
        }
        let selected = selectedProgram
        let isPlayingSelectedProgram =
            selected?.plan.brief.id == programStore.plan?.brief.id
        return StageProgramRailModel(
            plan: selected?.plan,
            activeSlotIndex: isPlayingSelectedProgram
                ? programStore.activeSlotIndex
                : nil
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            switch selection.route {
            case .programs:
                programList
            case .tracks:
                trackList
            case .playlistTracks:
                trackList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 42)
        .padding(.trailing, 10)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.22),
            value: selection.route
        )
    }

    @ViewBuilder
    private var programList: some View {
        if programs.isEmpty && libraryStore.playlists.isEmpty {
            emptyState
                .padding(.top, 96)
        } else {
            railHeader(
                title: "歌单",
                count: programs.count + libraryStore.playlists.count
            )
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .trailing, spacing: 4) {
                    ForEach(programs, id: \.plan.brief.id) { saved in
                        Button {
                            selection.openProgram(saved.plan.brief.id)
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "radio.fill")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Color.cyan.opacity(0.88))
                                    .frame(width: 42, height: 42)
                                    .background(
                                        Color.cyan.opacity(0.1),
                                        in: Circle()
                                    )

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(
                                        programTitle(saved.plan)
                                    )
                                    .font(.system(
                                        size: 16,
                                        weight: .semibold,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)

                                    Text(
                                        "\(saved.plan.slots.count) 首"
                                            + programDirection(saved.plan)
                                    )
                                    .font(.system(
                                        size: 13,
                                        weight: .medium,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(.white.opacity(0.46))
                                    .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                if
                                    saved.plan.brief.id
                                        == programStore.pendingPlan?.brief.id
                                {
                                    Image(systemName: "sparkles")
                                        .font(.system(
                                            size: 13,
                                            weight: .semibold
                                        ))
                                        .foregroundStyle(
                                            Color.cyan.opacity(0.9)
                                        )
                                        .help("后台新编排，等待切换")
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(
                                            size: 12,
                                            weight: .semibold
                                        ))
                                        .foregroundStyle(
                                            .white.opacity(0.34)
                                        )
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(width: 306, height: 74)
                            .background(
                                .ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 22)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 22)
                                    .stroke(
                                        saved.plan.brief.id
                                            == programStore.plan?.brief.id
                                            ? Color.cyan.opacity(0.44)
                                            : Color.white.opacity(0.11),
                                        lineWidth: 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .rotation3DEffect(
                            .degrees(-7),
                            axis: (x: 0, y: 1, z: 0),
                            anchor: .trailing,
                            perspective: 0.72
                        )
                        .shadow(color: .black.opacity(0.38), radius: 13, y: 7)
                    }
                    ForEach(libraryStore.playlists) { playlist in
                        syncedPlaylistButton(playlist)
                    }
                }
            }
            .contentMargins(.vertical, 18)
            .mask(railMask)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if trackModel.cards.isEmpty {
            Group {
                if selectedPlaylist != nil {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载歌曲…")
                            .font(.system(
                                size: 13,
                                weight: .medium,
                                design: .rounded
                            ))
                    }
                    .foregroundStyle(.white.opacity(0.58))
                } else {
                    emptyState
                }
            }
                .padding(.top, 96)
                .onAppear {
                    selection.loadMoreSelectedPlaylist()
                }
        } else {
            HStack(spacing: 8) {
                Button {
                    selection.showPrograms()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityLabel("返回节目单")

                Spacer(minLength: 4)
                if let title = trackModel.title, !title.isEmpty {
                    Text(title.uppercased())
                        .lineLimit(1)
                }
                if let selectedPlaylist {
                    Text(
                        "· \(selectedPlaylist.tracks.count)"
                            + " / \(selectedPlaylist.trackCount)"
                    )
                } else {
                    Text("· \(trackModel.cards.count)")
                }
                if selectedPlaylist == nil {
                    replanButton
                }
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.62))
            .shadow(color: .black.opacity(0.9), radius: 4)
            .padding(.horizontal, 14)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .trailing, spacing: -7) {
                        ForEach(trackModel.cards) { card in
                            programCard(card)
                                .id(card.slotIndex)
                                .onAppear {
                                    guard
                                        selectedPlaylist != nil,
                                        card.slotIndex
                                            >= trackModel.cards.count - 4
                                    else {
                                        return
                                    }
                                    selection.loadMoreSelectedPlaylist()
                                }
                                .scrollTransition(
                                    .interactive,
                                    axis: .vertical
                                ) { content, phase in
                                    content
                                        .opacity(
                                            phase.isIdentity ? 1 : 0.56
                                        )
                                        .scaleEffect(
                                            phase.isIdentity ? 1 : 0.9,
                                            anchor: .trailing
                                        )
                                        .rotation3DEffect(
                                            .degrees(
                                                Double(phase.value) * -13
                                            ),
                                            axis: (x: 1, y: 0.16, z: 0),
                                            anchor: .trailing,
                                            perspective: 0.72
                                        )
                                }
                        }
                        if let selectedPlaylist,
                           selectedPlaylist.tracks.count
                            < selectedPlaylist.trackCount
                        {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.cyan.opacity(0.8))
                                .frame(width: 306, height: 44)
                                .onAppear {
                                    selection.loadMoreSelectedPlaylist()
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .contentMargins(.vertical, 18)
                .mask(railMask)
                .onAppear {
                    scrollToActive(using: proxy, animated: false)
                }
                .onChange(of: programStore.activeSlotIndex) {
                    scrollToActive(using: proxy, animated: true)
                }
            }
        }
    }

    private func railHeader(title: String, count: Int) -> some View {
        HStack(spacing: 10) {
            replanButton
            Spacer(minLength: 4)
            Text("\(title.uppercased()) · \(count)")
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(.white.opacity(0.62))
        .shadow(color: .black.opacity(0.9), radius: 4)
        .padding(.horizontal, 14)
    }

    private func syncedPlaylistButton(
        _ playlist: MusicPlaylistSnapshot
    ) -> some View {
        Button {
            selection.openPlaylist(playlist.id)
        } label: {
            HStack(spacing: 13) {
                AsyncImage(url: playlist.artworkURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.88))
                }
                .frame(width: 42, height: 42)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 5) {
                    Text(playlist.name)
                        .font(.system(
                            size: 16,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(
                        "\(providerName(playlist.providerID)) · "
                            + "\(playlist.trackCount) 首"
                    )
                    .font(.system(
                        size: 13,
                        weight: .medium,
                        design: .rounded
                    ))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.34))
            }
            .padding(.horizontal, 14)
            .frame(width: 306, height: 74)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 22)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.11), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .rotation3DEffect(
            .degrees(-7),
            axis: (x: 0, y: 1, z: 0),
            anchor: .trailing,
            perspective: 0.72
        )
        .shadow(color: .black.opacity(0.38), radius: 13, y: 7)
    }

    private func providerName(_ providerID: MusicProviderID) -> String {
        switch providerID {
        case .netease:
            "网易云"
        case .qqMusic:
            "QQ 音乐"
        case .appleMusic:
            "Apple Music"
        default:
            "音乐库"
        }
    }

    private var replanButton: some View {
        Button {
            selection.replan()
        } label: {
            Image(
                systemName: programStore.status == .planning
                    ? "hourglass"
                    : "arrow.triangle.2.circlepath"
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(
                programStore.status == .planning
                    ? Color.orange.opacity(0.86)
                    : Color.cyan.opacity(0.88)
            )
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(programStore.status == .planning)
        .help(
            programStore.status == .planning
                ? "DJ 正在重新编排"
                : "让 DJ 重新编排后续歌曲"
        )
        .accessibilityLabel("重新编排后续歌曲")
    }

    private var railMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func programDirection(_ plan: ProgramPlan) -> String {
        guard let direction = plan.direction, !direction.isEmpty else {
            return ""
        }
        return " · \(direction)"
    }

    private func programTitle(_ plan: ProgramPlan) -> String {
        guard let title = plan.title, !title.isEmpty else {
            return "未命名节目"
        }
        return title
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.cyan.opacity(0.9))

            Text(programStore.status == .planning ? "DJ 正在排歌" : "暂无节目")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.84))
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.cyan.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: Color.cyan.opacity(0.14), radius: 24)
    }

    @ViewBuilder
    private func programCard(_ card: StageProgramRailCard) -> some View {
        let isFocused = selection.selectedSlotIndex.map {
            $0 == card.slotIndex
        } ?? card.isCurrent
        let relative = Double(
            max(-2, min(2, card.relativeIndex))
        )
        let distance = Double(min(2, abs(card.relativeIndex)))
        ZStack(alignment: .topTrailing) {
            Button {
                withAnimation(
                    reduceMotion ? nil : .easeOut(duration: 0.2)
                ) {
                    selection.activate(slotIndex: card.slotIndex)
                }
            } label: {
                HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(
                            card.isCurrent
                                ? Color.cyan.opacity(0.22)
                                : Color.white.opacity(0.06)
                        )
                    if card.isCurrent {
                        StageReactiveTrackIcon(
                            audioFeatures: audioFeatures
                        )
                    } else {
                        Image(
                            systemName: isFocused
                                ? "play.fill"
                                : "music.note"
                        )
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(
                            isFocused
                                ? Color(red: 0.48, green: 0.95, blue: 1)
                                : Color.white.opacity(0.52)
                        )
                    }
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    Text(card.title)
                        .font(.system(
                            size: card.isCurrent ? 17 : 16,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(.white.opacity(card.isCurrent ? 0.96 : 0.82))
                        .lineLimit(1)

                    HStack(spacing: 12) {
                        Text(card.artist)
                            .font(.system(
                                size: 14,
                                weight: .medium,
                                design: .rounded
                            ))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        energyTrace(card.energy)
                    }
                }
                }
                .padding(.horizontal, 14)
                .frame(width: 294, height: 76)
                .background {
                RoundedRectangle(cornerRadius: 23)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        LinearGradient(
                            colors: [
                                Color(
                                    red: 0.02,
                                    green: 0.55,
                                    blue: 0.88
                                ).opacity(card.isCurrent ? 0.19 : 0.06),
                                Color.black.opacity(0.12),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 23))
                    }
                }
                .overlay {
                RoundedRectangle(cornerRadius: 23)
                    .stroke(
                        card.isCurrent
                            ? Color.cyan.opacity(0.52)
                            : Color.white.opacity(0.12),
                        lineWidth: card.isCurrent ? 1.2 : 0.8
                    )
                }
                .shadow(
                color: card.isCurrent
                    ? Color.cyan.opacity(0.2)
                    : Color.black.opacity(0.42),
                radius: card.isCurrent ? 24 : 13,
                y: 7
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                card.isCurrent
                    ? "正在播放，\(card.title)，\(card.artist)"
                    : "选择，\(card.title)，\(card.artist)"
            )
            .accessibilityHint("立即播放这首歌曲")

            if card.isCurrent, videos.boundAsset(for: card.trackID) != nil {
                Button {
                    videos.playBoundVideo(for: card.trackID)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            videos.activeAssetID
                                == videos.boundAsset(for: card.trackID)?.id
                                && videos.isActive
                                ? Color.cyan
                                : Color.white.opacity(0.62)
                        )
                        .frame(width: 26, height: 26)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: -9, y: 8)
                .help("播放这首歌绑定的视频")
                .accessibilityLabel("播放绑定视频")
            }
        }
        .scaleEffect(
            isFocused ? card.scale + 0.055 : card.scale,
            anchor: .trailing
        )
        .opacity(isFocused ? 1 : card.opacity)
        .blur(radius: isFocused ? 0 : distance * 0.16)
        .rotation3DEffect(
            .degrees(isFocused ? -4 : -10 - relative * 2.5),
            axis: (x: 0, y: 1, z: 0),
            anchor: .trailing,
            perspective: 0.72
        )
        .offset(
            x: StageProgramRailCardLayout.horizontalOffset(
                relativeIndex: card.relativeIndex,
                isFocused: isFocused
            ),
            y: 0
        )
        .zIndex(
            isFocused || card.isCurrent
                ? 20
                : Double(10 - abs(card.relativeIndex))
        )
    }

    private func scrollToActive(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let activeSlotIndex = programStore.activeSlotIndex else {
            return
        }
        let action = {
            proxy.scrollTo(activeSlotIndex, anchor: .center)
        }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.24), action)
        } else {
            action()
        }
    }

    private func energyTrace(_ energy: Double) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0 ..< 7, id: \.self) { index in
                let wave = 0.36
                    + abs(sin(Double(index + 1) * 1.7)) * 0.64
                Capsule()
                    .fill(Color.cyan.opacity(0.42))
                    .frame(width: 2, height: 5 + 13 * energy * wave)
            }
        }
        .frame(width: 28, height: 22)
        .accessibilityHidden(true)
    }
}

private struct StageReactiveTrackIcon: View {
    let audioFeatures: VisualAudioFeatureStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let audio = audioFeatures.current
            HStack(alignment: .center, spacing: 2) {
                ForEach(0 ..< 5, id: \.self) { index in
                    let sample = abs(audio.waveform[index])
                    let band = switch index {
                    case 0, 1:
                        audio.low
                    case 2:
                        audio.mid
                    default:
                        audio.high
                    }
                    let activity = max(
                        sample,
                        band * 0.72,
                        audio.amplitude * 0.56
                    )
                    Capsule()
                        .fill(Color(red: 0.48, green: 0.95, blue: 1))
                        .frame(
                            width: 2.4,
                            height: 5 + CGFloat(activity) * 18
                        )
                }
            }
            .frame(width: 24, height: 25)
            .animation(
                .linear(duration: 1 / 30),
                value: audio.amplitude
            )
        }
        .accessibilityHidden(true)
    }
}
