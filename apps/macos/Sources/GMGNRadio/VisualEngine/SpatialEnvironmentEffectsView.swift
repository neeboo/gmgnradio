import SwiftUI

struct SpatialEnvironmentEffectsView: View {
    @Bindable var spatialStage: SpatialStageStore

    var body: some View {
        Group {
            if spatialStage.shouldRenderEnvironmentEffects {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) {
                    timeline in
                    GeometryReader { geometry in
                        ZStack {
                            weatherLayer(
                                at: timeline.date,
                                size: geometry.size
                            )
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func weatherLayer(at date: Date, size: CGSize) -> some View {
        switch spatialStage.environment.weather {
        case .clear:
            Color.clear
        case .rain:
            RainEffectView(date: date, size: size, intensity: 0.64)
        case .thunderstorm:
            ZStack {
                RainEffectView(date: date, size: size, intensity: 0.92)
                Color.white.opacity(lightningOpacity(at: date))
                    .blendMode(.screen)
            }
        }
    }

    private func lightningOpacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 5.4)
        if phase < 0.07 {
            return 0.46
        }
        if phase > 0.15, phase < 0.22 {
            return 0.22
        }
        return 0
    }
}

private struct RainEffectView: View {
    let date: Date
    let size: CGSize
    let intensity: Double

    var body: some View {
        Canvas { context, _ in
            let time = date.timeIntervalSinceReferenceDate
            let count = max(80, Int(size.width / 9))
            for index in 0 ..< count {
                let seed = Double((index * 73) % max(count, 1))
                let x = (seed / Double(count)) * size.width
                let speed = 420 + Double((index * 37) % 260)
                let y = (time * speed + Double(index * 97))
                    .truncatingRemainder(dividingBy: size.height + 120) - 60
                var path = Path()
                path.move(to: CGPoint(x: x + 16, y: y - 32))
                path.addLine(to: CGPoint(x: x, y: y + 18))
                context.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            .clear,
                            Color.cyan.opacity(0.34 * intensity),
                        ]),
                        startPoint: CGPoint(x: x + 16, y: y - 32),
                        endPoint: CGPoint(x: x, y: y + 18)
                    ),
                    lineWidth: index.isMultiple(of: 5) ? 1.4 : 0.7
                )
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color.indigo.opacity(0.08 * intensity),
                    Color.black.opacity(0.16 * intensity),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
