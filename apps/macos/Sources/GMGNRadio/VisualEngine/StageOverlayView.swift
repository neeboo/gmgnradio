import SwiftUI

struct StageOverlayView: View {
    @ObservedObject var presentation: StagePresentationModel

    var body: some View {
        ZStack {
            VStack(alignment: .leading) {
                Text(presentation.programTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(Color(red: 0.02, green: 0.09, blue: 0.24))

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
                        .foregroundStyle(Color(red: 0.015, green: 0.10, blue: 0.32))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)
                        .id(cue.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .shadow(color: .white, radius: 10)
                        .padding(.bottom, 38)
                }
            }
        }
        .animation(.easeOut(duration: 0.28), value: presentation.currentCue?.id)
        .allowsHitTesting(false)
    }
}
