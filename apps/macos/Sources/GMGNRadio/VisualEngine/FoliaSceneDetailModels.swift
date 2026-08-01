import Foundation

// Scene composition concepts adapted from Folia's Partita, Fume, Cappella,
// Tilt, Monet and Pendolo visualizers. Rewritten for gmgn radio in Swift
// on 2026-07-31.
// Licensed under GNU AGPL v3. See THIRD_PARTY_NOTICES.md.

enum StagePartitaComposition: Equatable, Sendable {
    case columns
    case staircase
    case constellation
    case chorusFan
}

struct StagePartitaGlyphPlacement: Equatable, Sendable {
    let glyphID: String
    let x: Double
    let y: Double
    let scale: Double
    let rotationDegrees: Double
}

struct StagePartitaLayoutModel: Equatable, Sendable {
    let composition: StagePartitaComposition
    let placements: [StagePartitaGlyphPlacement]

    init(
        glyphIDs: [String],
        lineID: String,
        isChorus: Bool
    ) {
        composition = isChorus
            ? .chorusFan
            : Self.regularComposition(lineID: lineID)
        placements = Self.makePlacements(
            glyphIDs: glyphIDs,
            lineID: lineID,
            composition: composition
        )
    }

    private static func regularComposition(
        lineID: String
    ) -> StagePartitaComposition {
        switch stableHash(lineID, salt: 17) % 3 {
        case 0:
            .columns
        case 1:
            .staircase
        default:
            .constellation
        }
    }

    private static func makePlacements(
        glyphIDs: [String],
        lineID: String,
        composition: StagePartitaComposition
    ) -> [StagePartitaGlyphPlacement] {
        let count = max(glyphIDs.count, 1)
        return glyphIDs.enumerated().map { index, glyphID in
            let unit = count == 1
                ? 0.5
                : Double(index) / Double(count - 1)
            let point: (Double, Double, Double, Double)
            switch composition {
            case .columns:
                let column = index % 3
                let rowCount = max(Int(ceil(Double(count) / 3)), 1)
                let row = index / 3
                let rowUnit = rowCount == 1
                    ? 0.5
                    : Double(row) / Double(rowCount - 1)
                point = (
                    Double(column - 1) * 0.31,
                    (rowUnit - 0.5) * 0.78
                        + Double(column - 1) * 0.035,
                    1,
                    Double(column - 1) * -8
                )
            case .staircase:
                point = (
                    (unit - 0.5) * 0.82,
                    (unit - 0.5) * 0.72,
                    0.92 + sin(unit * .pi) * 0.14,
                    (unit - 0.5) * -14
                )
            case .constellation:
                let phase = stableUnit(
                    lineID,
                    index: index,
                    salt: 31
                ) * .pi * 2
                let radius = 0.14 + 0.28 * sqrt(unit)
                point = (
                    cos(phase) * radius,
                    sin(phase) * radius * 0.86,
                    0.9 + stableUnit(
                        lineID,
                        index: index,
                        salt: 47
                    ) * 0.2,
                    (stableUnit(
                        lineID,
                        index: index,
                        salt: 59
                    ) - 0.5) * 18
                )
            case .chorusFan:
                let angle = (-0.72 + unit * 1.44)
                point = (
                    sin(angle) * 0.44,
                    -cos(angle) * 0.3 + 0.1,
                    0.96 + sin(unit * .pi) * 0.12,
                    angle * 24
                )
            }
            return StagePartitaGlyphPlacement(
                glyphID: glyphID,
                x: min(max(point.0, -0.46), 0.46),
                y: min(max(point.1, -0.42), 0.42),
                scale: point.2,
                rotationDegrees: point.3
            )
        }
    }
}

struct StageFumeArticleBlock: Equatable, Sendable {
    let lineID: String
    let text: String
    let position: SIMD2<Double>
    let width: Double
    let emphasis: Double
}

struct StageFumeArticleModel: Equatable, Sendable {
    let blocks: [StageFumeArticleBlock]
    let activeBlock: StageFumeArticleBlock?
    let cameraTarget: SIMD2<Double>

    init(lines: [StageLyricLine], activeLineID: String?) {
        var cursorY = 0.08
        blocks = lines.enumerated().map { index, line in
            let textLength = max(
                line.text.filter { !$0.isWhitespace }.count,
                4
            )
            let height = 0.105 + min(Double(textLength), 32) * 0.0024
            defer {
                cursorY += height
            }
            return StageFumeArticleBlock(
                lineID: line.id,
                text: line.text,
                position: SIMD2<Double>(
                    index.isMultiple(of: 2) ? 0.36 : 0.62,
                    cursorY
                ),
                width: min(max(Double(textLength) / 28, 0.34), 0.68),
                emphasis: line.id == activeLineID ? 1 : 0
            )
        }
        activeBlock = blocks.first { $0.lineID == activeLineID }
        cameraTarget = activeBlock?.position ?? SIMD2<Double>(0.5, 0.5)
    }
}

enum StageCappellaVoice: Int, CaseIterable, Equatable, Sendable {
    case lead
    case alto
    case tenor
    case ensemble

    var symbolName: String {
        switch self {
        case .lead:
            "waveform"
        case .alto:
            "music.note"
        case .tenor:
            "music.mic"
        case .ensemble:
            "person.3.fill"
        }
    }
}

struct StageCappellaConversationModel: Equatable, Sendable {
    let previousVoice: StageCappellaVoice
    let activeVoice: StageCappellaVoice
    let nextVoice: StageCappellaVoice

    init(
        previousLineID: String?,
        activeLineID: String,
        nextLineID: String?,
        isChorus: Bool
    ) {
        let previous = Self.voice(
            for: previousLineID ?? "\(activeLineID)-previous",
            salt: 11
        )
        let active = Self.voice(for: activeLineID, salt: 23)
        var next = Self.voice(
            for: nextLineID ?? "\(activeLineID)-next",
            salt: 37
        )
        if next == previous {
            next = StageCappellaVoice(
                rawValue: (next.rawValue + 1) % 3
            ) ?? .lead
        }
        previousVoice = previous
        activeVoice = isChorus ? .ensemble : active
        nextVoice = next
    }

    private static func voice(
        for lineID: String,
        salt: UInt64
    ) -> StageCappellaVoice {
        StageCappellaVoice(
            rawValue: Int(stableHash(lineID, salt: salt) % 3)
        ) ?? .lead
    }
}

struct StageTiltSegment: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let revealAt: TimeInterval
    let isTilted: Bool
    let xOffset: Double
    let yOffset: Double
}

struct StageTiltLayoutModel: Equatable, Sendable {
    let segments: [StageTiltSegment]

    init(line: StageLyricLine) {
        let characters = Array(line.text)
        let visibleCount = max(
            characters.filter { !$0.isWhitespace }.count,
            1
        )
        let segmentCount: Int
        switch visibleCount {
        case 0 ... 8:
            segmentCount = 1
        case 9 ... 16:
            segmentCount = 2
        case 17 ... 26:
            segmentCount = 3
        default:
            segmentCount = 4
        }
        let tiltIndex = Int(
            stableHash(line.id, salt: 71) % UInt64(segmentCount)
        )
        let duration = max(line.endsAt - line.startsAt, 0.01)

        segments = (0 ..< segmentCount).compactMap { index in
            let start = characters.count * index / segmentCount
            let end = characters.count * (index + 1) / segmentCount
            guard start < end else {
                return nil
            }
            let isTilted = index == tiltIndex
            return StageTiltSegment(
                id: "\(line.id)-segment-\(index)",
                text: String(characters[start ..< end]),
                revealAt: line.startsAt
                    + duration * Double(index) / Double(segmentCount),
                isTilted: isTilted,
                xOffset: Double(index.isMultiple(of: 2) ? index : -index)
                    * 0.045,
                yOffset: Double(index) * 0.12
                    + (isTilted ? -0.035 : 0)
            )
        }
    }
}

enum StageMonetLineStatus: Equatable, Sendable {
    case passed
    case active
    case waiting
}

struct StageMonetRailEntry: Identifiable, Equatable, Sendable {
    var id: String {
        line.id
    }

    let line: StageLyricLine
    let offset: Int
    let status: StageMonetLineStatus
}

struct StageMonetRailModel: Equatable, Sendable {
    let entries: [StageMonetRailEntry]

    init(
        lines: [StageLyricLine],
        activeLineID: String?,
        before: Int = 2,
        after: Int = 2
    ) {
        guard
            !lines.isEmpty,
            let activeIndex = lines.firstIndex(where: {
                $0.id == activeLineID
            })
        else {
            entries = []
            return
        }
        let start = max(lines.startIndex, activeIndex - max(before, 0))
        let end = min(
            lines.index(before: lines.endIndex),
            activeIndex + max(after, 0)
        )
        entries = (start ... end).map { index in
            let status: StageMonetLineStatus
            if index < activeIndex {
                status = .passed
            } else if index == activeIndex {
                status = .active
            } else {
                status = .waiting
            }
            return StageMonetRailEntry(
                line: lines[index],
                offset: index - activeIndex,
                status: status
            )
        }
    }
}

struct StagePendoloWheelItem: Identifiable, Equatable, Sendable {
    var id: String {
        line.id
    }

    let line: StageLyricLine
    let angleDegrees: Double
    let x: Double
    let y: Double
    let opacity: Double
    let scale: Double
    let isActive: Bool
}

struct StagePendoloWheelModel: Equatable, Sendable {
    let items: [StagePendoloWheelItem]

    init(
        lines: [StageLyricLine],
        activeLineID: String?,
        visibleRadius: Int = 4
    ) {
        guard
            !lines.isEmpty,
            let activeIndex = lines.firstIndex(where: {
                $0.id == activeLineID
            })
        else {
            items = []
            return
        }
        let radius = max(visibleRadius, 1)
        let start = max(lines.startIndex, activeIndex - radius)
        let end = min(
            lines.index(before: lines.endIndex),
            activeIndex + radius
        )
        let angleStep = 82 / Double(radius)
        items = (start ... end).map { index in
            let distance = index - activeIndex
            let angle = Double(distance) * angleStep
            let angleRadians = angle * .pi / 180
            let distanceScale = Double(abs(distance))
            return StagePendoloWheelItem(
                line: lines[index],
                angleDegrees: angle,
                x: cos(angleRadians),
                y: sin(angleRadians),
                opacity: max(0.12, 1 - distanceScale * 0.19),
                scale: index == activeIndex
                    ? 1.08
                    : max(0.7, 1 - distanceScale * 0.08),
                isActive: index == activeIndex
            )
        }
    }
}

private func stableHash(_ value: String, salt: UInt64) -> UInt64 {
    value.utf8.reduce(14_695_981_039_346_656_037 ^ salt) {
        partial, byte in
        (partial ^ UInt64(byte)) &* 1_099_511_628_211
    }
}

private func stableUnit(
    _ value: String,
    index: Int,
    salt: UInt64
) -> Double {
    let hash = stableHash("\(value)-\(index)", salt: salt)
    return Double(hash % 10_000) / 9_999
}
