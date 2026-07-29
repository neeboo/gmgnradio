import SwiftUI

struct StageOverlayView: View {
    @ObservedObject var presentation: StagePresentationModel

    var body: some View {
        ZStack {
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
                }
            }
        }
        .animation(.easeOut(duration: 0.28), value: presentation.currentCue?.id)
        .allowsHitTesting(false)
    }
}
