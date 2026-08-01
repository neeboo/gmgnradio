import Foundation
import Testing
@testable import GMGNRadio

@Test
func partitaLayoutIsStableAndKeepsEveryGlyphInsideTheStage() {
    let glyphIDs = (0 ..< 14).map { "glyph-\($0)" }
    let first = StagePartitaLayoutModel(
        glyphIDs: glyphIDs,
        lineID: "city-pop-line",
        isChorus: false
    )
    let second = StagePartitaLayoutModel(
        glyphIDs: glyphIDs,
        lineID: "city-pop-line",
        isChorus: false
    )

    #expect(first == second)
    #expect(first.placements.map(\.glyphID) == glyphIDs)
    #expect(first.placements.allSatisfy {
        (-0.46 ... 0.46).contains($0.x)
            && (-0.42 ... 0.42).contains($0.y)
    })
}

@Test
func partitaChorusUsesAFanInsteadOfTheRegularLineComposition() {
    let glyphIDs = (0 ..< 10).map { "chorus-\($0)" }
    let verse = StagePartitaLayoutModel(
        glyphIDs: glyphIDs,
        lineID: "same-line",
        isChorus: false
    )
    let chorus = StagePartitaLayoutModel(
        glyphIDs: glyphIDs,
        lineID: "same-line",
        isChorus: true
    )

    #expect(chorus.composition == .chorusFan)
    #expect(verse.composition != chorus.composition)
    #expect(Set(chorus.placements.map(\.rotationDegrees)).count > 3)
}

@Test
func fumeArticleKeepsTheWholeLyricAndMovesTheCameraToTheActiveBlock() throws {
    let lines = [
        StageLyricLine(id: "a", startsAt: 0, text: "第一句"),
        StageLyricLine(id: "b", startsAt: 5, text: "第二句稍微长一些"),
        StageLyricLine(id: "c", startsAt: 10, text: "第三句"),
        StageLyricLine(id: "d", startsAt: 15, text: "第四句"),
    ]
    let article = StageFumeArticleModel(
        lines: lines,
        activeLineID: "c"
    )
    let active = try #require(article.activeBlock)

    #expect(article.blocks.map(\.lineID) == ["a", "b", "c", "d"])
    #expect(active.lineID == "c")
    #expect(article.cameraTarget == active.position)
    #expect(article.blocks.map(\.position.y) == article.blocks
        .map(\.position.y).sorted())
}

@Test
func cappellaConversationAssignsStableVoicesAndPromotesChorusToEnsemble() {
    let verse = StageCappellaConversationModel(
        previousLineID: "a",
        activeLineID: "b",
        nextLineID: "c",
        isChorus: false
    )
    let repeated = StageCappellaConversationModel(
        previousLineID: "a",
        activeLineID: "b",
        nextLineID: "c",
        isChorus: false
    )
    let chorus = StageCappellaConversationModel(
        previousLineID: "a",
        activeLineID: "b",
        nextLineID: "c",
        isChorus: true
    )

    #expect(verse == repeated)
    #expect(verse.activeVoice != .ensemble)
    #expect(chorus.activeVoice == .ensemble)
    #expect(verse.previousVoice != verse.nextVoice)
}

@Test
func tiltSplitsALongLyricIntoTimedStaggeredSegments() {
    let line = StageLyricLine(
        id: "tilt-long-line",
        startsAt: 12,
        endsAt: 20,
        text: "霓虹穿过街角以后我们继续向前"
    )
    let first = StageTiltLayoutModel(line: line)
    let repeated = StageTiltLayoutModel(line: line)

    #expect(first == repeated)
    #expect((2 ... 4).contains(first.segments.count))
    #expect(first.segments.map(\.text).joined() == line.text)
    #expect(first.segments.filter(\.isTilted).count == 1)
    #expect(first.segments.map(\.revealAt) == first.segments
        .map(\.revealAt).sorted())
}

@Test
func monetBuildsAFiveLineRailAroundTheCurrentLyric() {
    let lines = (0 ..< 8).map {
        StageLyricLine(
            id: "monet-\($0)",
            startsAt: Double($0 * 4),
            endsAt: Double($0 * 4 + 4),
            text: "第\($0)句"
        )
    }
    let rail = StageMonetRailModel(
        lines: lines,
        activeLineID: "monet-4"
    )

    #expect(rail.entries.map(\.line.id) == [
        "monet-2",
        "monet-3",
        "monet-4",
        "monet-5",
        "monet-6",
    ])
    #expect(rail.entries.map(\.offset) == [-2, -1, 0, 1, 2])
    #expect(rail.entries.map(\.status) == [
        .passed,
        .passed,
        .active,
        .waiting,
        .waiting,
    ])
}

@Test
func pendoloPlacesWholeLinesOnTheRightClockArc() throws {
    let lines = (0 ..< 9).map {
        StageLyricLine(
            id: "pendolo-\($0)",
            startsAt: Double($0 * 3),
            endsAt: Double($0 * 3 + 3),
            text: "钟摆歌词 \($0)"
        )
    }
    let wheel = StagePendoloWheelModel(
        lines: lines,
        activeLineID: "pendolo-4"
    )
    let active = try #require(wheel.items.first { $0.isActive })

    #expect(wheel.items.count >= 5)
    #expect(abs(active.angleDegrees) < 0.001)
    #expect(abs(active.x - 1) < 0.001)
    #expect(abs(active.y) < 0.001)
    #expect(wheel.items.allSatisfy { $0.x >= 0 })
    #expect(wheel.items.allSatisfy {
        (-90 ... 90).contains($0.angleDegrees)
    })
}
