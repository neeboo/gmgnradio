import CoreGraphics

struct DisplayFrame: Equatable, Sendable {
    let id: String
    let visibleFrame: CGRect
}

enum WindowPlacement {
    static func defaultFrame(
        size: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat
    ) -> CGRect {
        CGRect(
            x: visibleFrame.maxX - size.width - margin,
            y: visibleFrame.minY + margin,
            width: size.width,
            height: size.height
        )
    }

    static func snappedFrame(
        _ proposed: CGRect,
        visibleFrames: [CGRect],
        margin: CGFloat,
        snapDistance: CGFloat
    ) -> CGRect {
        guard let visibleFrame = bestVisibleFrame(for: proposed, in: visibleFrames) else {
            return proposed
        }

        let minimumX = visibleFrame.minX + margin
        let maximumX = visibleFrame.maxX - margin - proposed.width
        let minimumY = visibleFrame.minY + margin
        let maximumY = visibleFrame.maxY - margin - proposed.height

        var origin = CGPoint(
            x: min(max(proposed.minX, minimumX), maximumX),
            y: min(max(proposed.minY, minimumY), maximumY)
        )

        if abs(proposed.minX - minimumX) <= snapDistance {
            origin.x = minimumX
        } else if abs(proposed.minX - maximumX) <= snapDistance {
            origin.x = maximumX
        }

        if abs(proposed.minY - minimumY) <= snapDistance {
            origin.y = minimumY
        } else if abs(proposed.minY - maximumY) <= snapDistance {
            origin.y = maximumY
        }

        return CGRect(origin: origin, size: proposed.size)
    }

    static func restoredFrame(
        size: CGSize,
        displays: [DisplayFrame],
        savedDisplayID: String?,
        savedOrigin: CGPoint?,
        margin: CGFloat
    ) -> CGRect {
        guard let fallback = displays.first else {
            return CGRect(origin: savedOrigin ?? .zero, size: size)
        }

        guard
            let savedDisplayID,
            let savedOrigin,
            let display = displays.first(where: { $0.id == savedDisplayID })
        else {
            return defaultFrame(size: size, visibleFrame: fallback.visibleFrame, margin: margin)
        }

        return snappedFrame(
            CGRect(origin: savedOrigin, size: size),
            visibleFrames: [display.visibleFrame],
            margin: margin,
            snapDistance: margin
        )
    }

    private static func bestVisibleFrame(
        for proposed: CGRect,
        in visibleFrames: [CGRect]
    ) -> CGRect? {
        visibleFrames.max { lhs, rhs in
            intersectionArea(of: proposed, and: lhs)
                < intersectionArea(of: proposed, and: rhs)
        }
    }

    private static func intersectionArea(of lhs: CGRect, and rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }
}

