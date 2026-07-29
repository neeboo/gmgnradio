import Foundation

struct ProgramVisualCue: Equatable, Sendable {
    let role: ProgramSlotRole
    let mood: StageVisualMood
    let frame: StageVisualPresetFrame
    let intensity: Float
    let transitionDuration: TimeInterval
}
