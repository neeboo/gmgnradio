import Foundation

/// Format compatibility between an avatar's bone engine and an installed
/// motion. The rule is metadata-driven (`StageMotionFormat` /
/// `PresenceEngine`); filenames never participate. Both installed formats are
/// always kept on disk — filtering only decides what the current character's
/// motion lists offer. Settings and the stage overlay share this one rule.
enum MotionFormatFilter {
    enum Engine: Equatable, Sendable {
        case vrm
        case pmx
        case live2D
        case orb
        /// No character selected (or a bare orb): nothing is playable yet.
        case unspecified
    }

    enum Format: Equatable, Sendable {
        case procedural
        case vrma
        case vmd
    }

    /// The LIST rule is native format: VRM shows VRMA + procedural, PMX shows
    /// VMD + procedural. The VMD-on-VRM playback adapter stays a playback-layer
    /// capability and deliberately does not broaden these lists — otherwise a
    /// PMX-authored motion would appear twice across the two characters' lists.
    static func isNativeFormat(engine: Engine, format: Format) -> Bool {
        switch engine {
        case .vrm: format == .vrma || format == .procedural
        case .pmx: format == .vmd || format == .procedural
        case .live2D, .orb, .unspecified: false
        }
    }

    /// Catalog format strings ("vrma" / "vmd") mapped to the list rule; unknown
    /// strings return nil and are filtered out of remote lists.
    static func native(catalogFormat: String) -> Format? {
        switch catalogFormat {
        case "vrma": .vrma
        case "vmd": .vmd
        default: nil
        }
    }

    /// Why the current character's motion list is empty even though motions
    /// are installed. `nil` when the list should simply show its matches, and
    /// `nil` for an empty library so the plain install hint stays accurate.
    static func unavailableNotice(engine: Engine, installedCount: Int) -> String? {
        guard installedCount > 0 else { return nil }
        switch engine {
        case .vrm, .pmx: return nil
        case .live2D: return "Live2D 角色暂不支持骨骼动作。"
        case .orb, .unspecified: return "请先选择 VRM 或 PMX 角色。"
        }
    }

    /// Keeps only motions natively belonging to the engine, preserving input order.
    static func available<Directional: BoneFormatDescribing>(
        _ motions: [Directional],
        engine: Engine
    ) -> [Directional] {
        motions.filter { isNativeFormat(engine: engine, format: $0.boneFormat) }
    }
}

/// Anything that exposes its bone-motion format for compatibility filtering.
protocol BoneFormatDescribing {
    var boneFormat: MotionFormatFilter.Format { get }
}

/// A motion that can be filtered by native format first, then by its library
/// category. Unknown or non-BONES ids carry no category and stay visible only
/// under 全部 — never under a specific category.
protocol MotionLibraryFiltering: BoneFormatDescribing {
    var libraryMotionID: String { get }
}

extension MotionFormatFilter {
    /// Format filter first, then the browsing category (`nil` = 全部).
    static func libraryList<Motion: MotionLibraryFiltering>(
        _ motions: [Motion],
        engine: Engine,
        category: MotionLibraryCategory?
    ) -> [Motion] {
        motions.filter { motion in
            guard isNativeFormat(engine: engine, format: motion.boneFormat) else { return false }
            guard let category else { return true }
            return MotionLibraryCategory.category(forMotionID: motion.libraryMotionID) == category
        }
    }
}
