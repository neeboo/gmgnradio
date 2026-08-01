import Foundation

struct ProgramVisualCue: Equatable, Sendable {
    let role: ProgramSlotRole
    let mood: StageVisualMood
    let frame: StageVisualPresetFrame
    let palette: StageVisualPalette
    let intensity: Float
    let transitionDuration: TimeInterval
}
