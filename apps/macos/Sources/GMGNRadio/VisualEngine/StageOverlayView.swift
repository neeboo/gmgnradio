import SwiftUI

struct StageOverlayView: View {
    @ObservedObject var presentation: StagePresentationModel

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("GMGN RADIO / LIVE")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color(red: 0.02, green: 0.22, blue: 0.72))

                Text(presentation.programTitle)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.02, green: 0.09, blue: 0.24))

                Text(presentation.programDetail)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Color(red: 0.20, green: 0.32, blue: 0.48))

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 36)
            .padding(.leading, 38)

            VStack {
                Spacer()
                if let cue = presentation.currentCue {
                    VStack(spacing: 6) {
                        Text(cue.text)
                            .font(.system(
                                size: 18 + CGFloat(cue.emphasis) * 5,
                                weight: .semibold,
                                design: .rounded
                            ))
                            .foregroundStyle(Color(red: 0.015, green: 0.10, blue: 0.32))

                        if let secondaryText = cue.secondaryText {
                            Text(secondaryText)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(red: 0.08, green: 0.30, blue: 0.66))
                        }
                    }
                    .id(cue.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .shadow(color: .white, radius: 10)
                    .padding(.bottom, 58)
                }

                HStack {
                    Text("拖拽旋转 · 双击复位")
                    Spacer()
                    Text("白蓝粒子舞台 / 60–120 FPS")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 0.16, green: 0.32, blue: 0.52))
                .padding(.horizontal, 30)
                .padding(.bottom, 22)
            }
        }
        .animation(.easeOut(duration: 0.28), value: presentation.currentCue?.id)
        .allowsHitTesting(false)
    }
}
