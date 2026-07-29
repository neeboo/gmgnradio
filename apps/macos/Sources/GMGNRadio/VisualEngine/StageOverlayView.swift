import SwiftUI

struct StageOverlayView: View {
    @ObservedObject var presentation: StagePresentationModel
    @ObservedObject var overlayState: StageOverlayState
    @ObservedObject var lyrics: StageLyricsStore
    let playbackPosition: @MainActor () -> TimeInterval

    var body: some View {
        ZStack {
            StageLyricsView(
                lyrics: lyrics,
                overlayState: overlayState,
                playbackPosition: playbackPosition
            )

            VStack(alignment: .leading) {
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

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 34)
            .padding(.leading, 36)

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
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)
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
        }
        .animation(.easeOut(duration: 0.28), value: presentation.currentCue?.id)
        .animation(
            .easeOut(duration: 0.22),
            value: overlayState.isProgramRailVisible
        )
        .allowsHitTesting(false)
    }
}

@MainActor
private struct StageLyricsView: View {
    @ObservedObject var lyrics: StageLyricsStore
    @ObservedObject var overlayState: StageOverlayState
    let playbackPosition: @MainActor () -> TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1 / 24)) { _ in
            let scene = StageLyricSceneModel(
                lines: lyrics.lines,
                playbackTime: playbackPosition()
            )
            let activeID = scene.lines.first(where: {
                $0.position == 0
            })?.id

            ZStack {
                ForEach(scene.lines) { line in
                    lyricLine(line)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(
                .easeOut(duration: 0.26),
                value: activeID
            )
            .animation(
                .easeOut(duration: 0.22),
                value: overlayState.isProgramRailVisible
            )
        }
        .allowsHitTesting(false)
    }

    private func lyricLine(_ line: StageLyricSceneLine) -> some View {
        let isCurrent = line.position == 0
        let railOffset = overlayState.isProgramRailVisible ? -150.0 : 0
        let xOffset = railOffset + Double(line.position) * 92
        let yOffset = Double(line.position) * 96
        let glow = isCurrent
            ? Color.cyan.opacity(0.5)
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
            .scaleEffect(line.scale)
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
                    Color.white,
                    Color(red: 0.56, green: 0.94, blue: 1),
                ]
                : [
                    Color.white.opacity(0.76),
                    Color.cyan.opacity(0.5),
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

struct StageProgramRailCard: Equatable, Identifiable {
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

struct StageProgramRailModel: Equatable {
    let title: String?
    let cards: [StageProgramRailCard]

    init(
        plan: ProgramPlan?,
        activeSlotIndex: Int?,
        maximumVisibleCards: Int = 5
    ) {
        title = plan?.title
        guard let plan, !plan.slots.isEmpty else {
            cards = []
            return
        }

        let firstIndex: Int
        let activeIndex: Int?
        if
            let activeSlotIndex,
            plan.slots.indices.contains(activeSlotIndex)
        {
            activeIndex = activeSlotIndex
            let lastStart = max(
                plan.slots.count - max(0, maximumVisibleCards),
                plan.slots.startIndex
            )
            firstIndex = min(
                max(activeSlotIndex - 2, plan.slots.startIndex),
                lastStart
            )
        } else {
            activeIndex = nil
            firstIndex = plan.slots.startIndex
        }

        cards = plan.slots[firstIndex...]
            .prefix(max(0, maximumVisibleCards))
            .enumerated()
            .map { visibleIndex, slot in
                let absoluteIndex = firstIndex + visibleIndex
                let relativeIndex = activeIndex.map {
                    absoluteIndex - $0
                } ?? visibleIndex
                let isCurrent = absoluteIndex == activeIndex
                let distance = abs(relativeIndex)
                return StageProgramRailCard(
                    trackID: slot.track.id,
                    title: slot.track.title,
                    artist: slot.track.artist,
                    energy: slot.track.energy,
                    relativeIndex: relativeIndex,
                    isCurrent: isCurrent,
                    depth: distance * -72,
                    opacity: isCurrent
                        ? 1
                        : max(
                            relativeIndex < 0 ? 0.34 : 0.46,
                            1 - Double(distance) * 0.16
                        ),
                    scale: isCurrent
                        ? 1
                        : max(0.78, 1 - Double(distance) * 0.055)
                )
            }
    }
}

@MainActor
struct StageProgramRailView: View {
    @Bindable var programStore: DJProgramStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focusedTrackID: String?

    private var model: StageProgramRailModel {
        StageProgramRailModel(
            plan: programStore.plan,
            activeSlotIndex: programStore.activeSlotIndex
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if model.cards.isEmpty {
                emptyState
                    .padding(.top, 96)
            } else {
                HStack(spacing: 8) {
                    if let title = model.title, !title.isEmpty {
                        Text(title.uppercased())
                            .lineLimit(1)
                    }
                    Text("· \(programStore.plan?.slots.count ?? 0)")
                }
                        .font(.system(
                            size: 14,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.62))
                        .shadow(color: .black.opacity(0.9), radius: 4)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 14)

                VStack(alignment: .trailing, spacing: -7) {
                    ForEach(model.cards) { card in
                        programCard(card)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 42)
        .padding(.trailing, 10)
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
        let isFocused = focusedTrackID == card.trackID
        let relative = Double(card.relativeIndex)
        let distance = Double(abs(card.relativeIndex))
        Button {
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.2)
            ) {
                focusedTrackID = isFocused ? nil : card.trackID
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
                    Image(systemName: card.isCurrent ? "waveform" : "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            card.isCurrent
                                ? Color(red: 0.45, green: 0.94, blue: 1)
                                : Color.white.opacity(0.52)
                        )
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
                : "接下来，\(card.title)，\(card.artist)"
        )
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
            x: isFocused
                ? -30
                : Double(abs(card.relativeIndex)) * 9,
            y: 0
        )
        .zIndex(
            isFocused || card.isCurrent
                ? 20
                : Double(10 - abs(card.relativeIndex))
        )
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
