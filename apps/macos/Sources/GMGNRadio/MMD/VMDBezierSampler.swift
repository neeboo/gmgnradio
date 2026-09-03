import Foundation

enum VMDBezierSampler {
    static func value(at progress: Float, controlPoints: VMDBezierControlPoints) -> Float {
        let progress = min(max(progress, 0), 1)
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return 1 }

        let points = controlPoints.normalized
        var lower: Float = 0
        var upper: Float = 1

        // The VMD x control points are monotonic. Solving x(t) with a fixed
        // binary search keeps sampling deterministic across CPU architectures.
        for _ in 0..<20 {
            let parameter = (lower + upper) * 0.5
            if cubic(parameter, points.x1, points.x2) < progress {
                lower = parameter
            } else {
                upper = parameter
            }
        }

        return cubic((lower + upper) * 0.5, points.y1, points.y2)
    }

    private static func cubic(_ parameter: Float, _ control1: Float, _ control2: Float) -> Float {
        let inverse = 1 - parameter
        return 3 * inverse * inverse * parameter * control1
            + 3 * inverse * parameter * parameter * control2
            + parameter * parameter * parameter
    }
}
