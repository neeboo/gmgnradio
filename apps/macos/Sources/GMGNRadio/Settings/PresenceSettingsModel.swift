import AppKit
import Foundation
import MotionDistribution
import Observation
import UniformTypeIdentifiers

extension Notification.Name {
    static let gmgnManualMotionWillActivate = Notification.Name(
        "ai.gmgn.radio.manual-motion-will-activate"
    )
}

@MainActor
@Observable
final class PresenceSettingsModel {
    enum MotionCompatibility: Equatable {
        case compatible
        case incompatible(String)
    }

    enum PublishedMotionInstallState: Equatable {
        case notInstalled
        case installed
        case updateAvailable
    }

    var packages: [PresencePackage] = []
    var motions: [StageMotionAsset] = []
    var publishedMotions: [PublishedMotion] = []
    var activeMotionID: String?
    var downloadURL = ""
    var remoteMotionCatalogURL: String
    var message: String?
    var hasError = false
    var isWorking = false
    var orbAppearance: OrbAppearance

    private let service: PresenceCommandService?
    private let startupError: Error?
    private let motionStore: MotionPackageStore?
    private let motionStartupError: Error?
    private let defaults: UserDefaults
    private let avatarRuntime: StageAvatarRuntimeStore
    private let onWillActivateMotion: (String) -> Void
    private let playbackCompatibility: (PresenceEngine?, StageMotionFormat) -> MotionCompatibility
    private var remoteMotionLibrary: RemoteMotionLibrary?
    private var importPanel: NSOpenPanel?

    private enum MotionPreferenceKey {
        static let vrm = "gmgn.presence.motion.preferred.vrm"
        static let pmx = "gmgn.presence.motion.preferred.pmx"
    }

    private static let motionCatalogURLKey = "gmgn.presence.motion.catalog-url"

    init(
        defaults: UserDefaults = .standard,
        avatarRuntime: StageAvatarRuntimeStore = .shared,
        presenceStore: PresencePackageStore? = nil,
        motionStore: MotionPackageStore? = nil,
        remoteMotionLibrary: RemoteMotionLibrary? = nil,
        playbackCompatibility: ((PresenceEngine?, StageMotionFormat) -> MotionCompatibility)? = nil,
        onWillActivateMotion: @escaping (String) -> Void = { motionID in
            NotificationCenter.default.post(
                name: .gmgnManualMotionWillActivate,
                object: motionID
            )
        }
    ) {
        self.defaults = defaults
        self.avatarRuntime = avatarRuntime
        self.onWillActivateMotion = onWillActivateMotion
        self.playbackCompatibility = playbackCompatibility ?? {
            Self.motionCompatibility(avatarEngine: $0, motionFormat: $1)
        }
        self.remoteMotionLibrary = remoteMotionLibrary
        remoteMotionCatalogURL = remoteMotionLibrary?.catalogURL.absoluteString
            ?? MotionServiceConfiguration.resolvedCatalogURLString(
                persisted: defaults.string(forKey: Self.motionCatalogURLKey)
            )
        orbAppearance = OrbAppearance.load(from: defaults)
        do {
            service = PresenceCommandService(
                store: try presenceStore ?? PresencePackageStore.liveStore()
            )
            startupError = nil
        } catch {
            service = nil
            startupError = error
        }
        do {
            self.motionStore = try motionStore ?? MotionPackageStore.liveStore()
            motionStartupError = nil
        } catch {
            self.motionStore = nil
            motionStartupError = error
        }
    }

    func setOrbColor(red: Float, green: Float, blue: Float) {
        orbAppearance.red = red
        orbAppearance.green = green
        orbAppearance.blue = blue
        orbAppearance.save(to: defaults)
        orbAppearance = OrbAppearance.load(from: defaults)
    }

    func setOrbFlowIntensity(_ value: Float) {
        orbAppearance.flowIntensity = value
        orbAppearance.save(to: defaults)
        orbAppearance = OrbAppearance.load(from: defaults)
    }

    func load() {
        guard let service, let motionStore else {
            show(error: startupError ?? motionStartupError)
            return
        }
        do {
            packages = try service.list()
            motions = try motionStore.listMotions()
            activeMotionID = try motionStore.activeMotion().id
            try refreshEffectiveMotionForActiveAvatar()
        } catch {
            show(error: error)
        }
    }

    var activeAvatarEngine: PresenceEngine? {
        packages.first(where: \.isActive)?.manifest.engine
    }

    /// Shared-runtime identity lets an open settings window refresh after a
    /// character switch made by another surface, including clearing it.
    var activeAvatarID: String? {
        avatarRuntime.snapshot.avatar?.id
    }

    static func motionCompatibility(
        avatarEngine: PresenceEngine?,
        motionFormat: StageMotionFormat
    ) -> MotionCompatibility {
        // Playback compatibility remains broader than native-format browsing.
        // Filtering a list must not invalidate an existing VMD-on-VRM choice.
        switch avatarEngine {
        case .vrm: return .compatible
        case .pmx:
            return motionFormat == .vrma
                ? .incompatible("VRMA 只能用于 VRM 角色。") : .compatible
        case .live2D: return .incompatible("Live2D 角色暂不支持骨骼动作。")
        case .orb, nil: return .incompatible("请先选择 VRM 或 PMX 角色。")
        }
    }

    /// Native-format browsing projection. The broader playback compatibility
    /// above deliberately does not determine which duplicate formats to show.
    var availableMotions: [StageMotionAsset] {
        motions.filter { motion in
            MotionFormatFilter.isNativeFormat(
                engine: MotionFormatFilter.Engine(activeAvatarEngine),
                format: MotionFormatFilter.Format(motion.format))
        }
    }

    /// Remote catalog entries natively belonging to the active avatar. The
    /// catalog's format string (not its name) drives the filter; unknown
    /// formats are hidden from both characters' lists.
    var availablePublishedMotions: [PublishedMotion] {
        publishedMotions.filter { published in
            guard let format = MotionFormatFilter.native(catalogFormat: published.format) else {
                return false
            }
            return MotionFormatFilter.isNativeFormat(
                engine: MotionFormatFilter.Engine(activeAvatarEngine), format: format)
        }
    }

    /// Format filter first, then the browsing category (`nil` = 全部).
    /// Unclassified and non-BONES motions are only offered under 全部.
    func motions(in category: MotionLibraryCategory?) -> [StageMotionAsset] {
        MotionFormatFilter.libraryList(
            motions,
            engine: MotionFormatFilter.Engine(activeAvatarEngine),
            category: category)
    }

    /// Explains an empty list while motions are installed (wrong character or
    /// no character). `nil` means the filtered list itself is the truth.
    var motionListNotice: String? {
        MotionFormatFilter.unavailableNotice(
            engine: MotionFormatFilter.Engine(activeAvatarEngine),
            installedCount: motions.count)
    }

    func motionCompatibility(_ motion: StageMotionAsset) -> MotionCompatibility {
        playbackCompatibility(activeAvatarEngine, motion.format)
    }

    func isBuiltInMotion(_ motion: StageMotionAsset) -> Bool {
        [
            MotionPackageStore.naturalIdleID,
            MotionPackageStore.iluvSlapBassID,
        ].contains(motion.id)
    }

    func importModel() {
        guard importPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "导入角色模型"
        panel.prompt = "安装"
        panel.message = "选择 .vrm 文件，或包含 PMX / Live2D 模型的目录、ZIP。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .folder,
            .zip,
            UTType(filenameExtension: "gmgnpet") ?? .data,
            UTType(filenameExtension: "vrm") ?? .data,
        ]
        importPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            self.importPanel = nil
            guard response == .OK, let sourceURL = panel.url else { return }
            self.install(from: sourceURL)
        }
    }

    func importMotion() {
        guard importPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "导入动作"
        panel.prompt = "安装"
        panel.message = "选择 VRMA 或 VMD 动作文件。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "vrma") ?? .data,
            UTType(filenameExtension: "vmd") ?? .data,
        ]
        importPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            self.importPanel = nil
            guard response == .OK, let sourceURL = panel.url else { return }
            self.installMotion(from: sourceURL)
        }
    }

    func activateMotion(_ motion: StageMotionAsset) {
        guard motionCompatibility(motion) == .compatible else { return }
        do {
            let store = try requireMotionStore()
            onWillActivateMotion(motion.id)
            savePreferredMotion(motion.id, for: activeAvatarEngine)
            try store.activate(id: motion.id)
            motions = try store.listMotions()
            activeMotionID = motion.id
            avatarRuntime.refresh()
            show(message: "已切换为 \(motion.name)。")
        } catch {
            show(error: error)
        }
    }

    func removeMotion(_ motion: StageMotionAsset) {
        do {
            let store = try requireMotionStore()
            clearPreferredMotionReferences(to: motion.id)
            try store.remove(id: motion.id)
            motions = try store.listMotions()
            try refreshEffectiveMotionForActiveAvatar()
            show(message: "已移除 \(motion.name)。")
        } catch {
            show(error: error)
        }
    }

    func refreshPublishedMotions() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let library = try requireRemoteMotionLibrary()
            publishedMotions = Self.latestPublishedMotions(
                from: try await library.refresh()
            )
            defaults.set(remoteMotionCatalogURL, forKey: Self.motionCatalogURLKey)
            show(message: publishedMotions.isEmpty
                ? "动作库当前没有可下载动作。"
                : "已找到 \(publishedMotions.count) 个动作。")
        } catch {
            show(error: error)
        }
    }

    func installPublishedMotion(_ published: PublishedMotion) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let store = try requireMotionStore()
            let installed = try await requireRemoteMotionLibrary().install(published)
            motions = try store.listMotions()
            if motionCompatibility(installed) == .compatible {
                onWillActivateMotion(installed.id)
                savePreferredMotion(installed.id, for: activeAvatarEngine)
                try store.activate(id: installed.id)
                activeMotionID = installed.id
                avatarRuntime.refresh()
                show(message: "已安装并启用 \(installed.name)。")
            } else {
                activeMotionID = try store.activeMotion().id
                show(message: published.format == "vmd"
                    ? "动作已安装；切换到 PMX 角色后即可使用。"
                    : "动作已安装；切换到 VRM 角色后即可使用。")
            }
        } catch {
            show(error: error)
        }
    }

    func publishedMotionInstallState(
        _ published: PublishedMotion
    ) -> PublishedMotionInstallState {
        guard let motionStore else { return .notInstalled }
        do {
            guard let installed = try motionStore.installedPublishedMotion(
                id: published.id
            ) else {
                return .notInstalled
            }
            return installed.version == published.version
                && installed.sha256 == published.sha256
                && installed.loop == published.loop
                ? .installed
                : .updateAvailable
        } catch {
            return .notInstalled
        }
    }

    static func latestPublishedMotions(
        from motions: [PublishedMotion]
    ) -> [PublishedMotion] {
        var latestByID: [String: PublishedMotion] = [:]
        for motion in motions {
            guard let current = latestByID[motion.id] else {
                latestByID[motion.id] = motion
                continue
            }
            if motion.version.compare(
                current.version,
                options: .numeric
            ) == .orderedDescending {
                latestByID[motion.id] = motion
            }
        }
        return latestByID.values.sorted {
            if $0.name != $1.name {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    private func requireRemoteMotionLibrary() throws -> RemoteMotionLibrary {
        let trimmed = remoteMotionCatalogURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            throw URLError(.badURL)
        }
        if let remoteMotionLibrary,
           remoteMotionLibrary.catalogURL == url {
            return remoteMotionLibrary
        }
        let library = RemoteMotionLibrary(
            catalogURL: url,
            motionStore: try requireMotionStore(),
            cacheRootURL: try RemoteMotionLibrary.liveCacheRoot()
        )
        remoteMotionLibrary = library
        return library
    }

    private func installMotion(from sourceURL: URL) {
        isWorking = true
        defer { isWorking = false }
        do {
            let store = try requireMotionStore()
            let installed = try store.installMotion(from: sourceURL)
            motions = try store.listMotions()
            if motionCompatibility(installed) == .compatible {
                onWillActivateMotion(installed.id)
                savePreferredMotion(installed.id, for: activeAvatarEngine)
                try store.activate(id: installed.id)
                activeMotionID = installed.id
                avatarRuntime.refresh()
                show(message: "动作已安装并启用。")
            } else {
                activeMotionID = try store.activeMotion().id
                show(message: "动作已安装；切换到兼容角色后即可使用。")
            }
        } catch {
            show(error: error)
        }
    }

    @available(*, deprecated, renamed: "importModel")
    func importLocal() {
        importModel()
    }

    func downloadAndInstall() async {
        guard let service else {
            show(error: startupError)
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            let url = try service.validatedDownloadURL(downloadURL)
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            guard
                let response = response as? HTTPURLResponse,
                (200 ... 299).contains(response.statusCode),
                response.url?.scheme?.lowercased() == "https"
            else {
                throw URLError(.badServerResponse)
            }
            if response.expectedContentLength > 500 * 1_024 * 1_024 {
                throw PresenceDownloadError.packageTooLarge
            }

            let suffix = url.pathExtension.isEmpty ? "gmgnpet" : url.pathExtension
            let localURL = FileManager.default.temporaryDirectory
                .appending(path: "gmgn-presence-\(UUID().uuidString).\(suffix)")
            try FileManager.default.copyItem(at: temporaryURL, to: localURL)
            defer { try? FileManager.default.removeItem(at: localURL) }

            let installed = try service.store.installPackage(from: localURL)
            try activateInstalledIfPossible(installed, using: service)
            packages = try service.list()
            try refreshEffectiveMotionForActiveAvatar()
            downloadURL = ""
            show(message: "模型已安装。")
        } catch {
            show(error: error)
        }
    }

    func activate(_ package: PresencePackage) {
        guard package.rendererAvailable else { return }
        do {
            try requireService().store.activate(id: package.manifest.id)
            packages = try requireService().list()
            try refreshEffectiveMotionForActiveAvatar()
            show(message: "已切换为 \(package.manifest.name)。")
        } catch {
            show(error: error)
        }
    }

    func remove(_ package: PresencePackage) {
        do {
            try requireService().store.remove(id: package.manifest.id)
            packages = try requireService().list()
            try refreshEffectiveMotionForActiveAvatar()
            show(message: "已移除 \(package.manifest.name)。")
        } catch {
            show(error: error)
        }
    }

    private func install(from sourceURL: URL) {
        isWorking = true
        defer { isWorking = false }
        do {
            let service = try requireService()
            let installed = try service.store.installPackage(from: sourceURL)
            try activateInstalledIfPossible(installed, using: service)
            packages = try service.list()
            try refreshEffectiveMotionForActiveAvatar()
            show(message: "模型已安装。")
        } catch {
            show(error: error)
        }
    }

    private func requireService() throws -> PresenceCommandService {
        if let service {
            return service
        }
        throw startupError ?? PresenceSettingsError.storeUnavailable
    }

    private func requireMotionStore() throws -> MotionPackageStore {
        if let motionStore {
            return motionStore
        }
        throw motionStartupError ?? PresenceSettingsError.storeUnavailable
    }

    func refreshEffectiveMotionForActiveAvatar() throws {
        let store = try requireMotionStore()
        motions = try store.listMotions()
        let current = try store.activeMotion()
        migrateUnambiguousPreference(from: current)

        let effective: StageMotionAsset
        if
            let engine = activeAvatarEngine,
            let preferenceKey = preferenceKey(for: engine)
        {
            if
                let preferredID = defaults.string(forKey: preferenceKey),
                let preferred = motions.first(where: { $0.id == preferredID }),
                playbackCompatibility(engine, preferred.format) == .compatible
            {
                effective = preferred
            } else if playbackCompatibility(engine, current.format) == .compatible {
                effective = current
                defaults.set(current.id, forKey: preferenceKey)
            } else {
                effective = try naturalIdle(in: motions)
                defaults.set(effective.id, forKey: preferenceKey)
            }
        } else {
            effective = try naturalIdle(in: motions)
        }

        if current.id != effective.id {
            try store.activate(id: effective.id)
        }
        activeMotionID = effective.id
        avatarRuntime.refresh()
    }

    private func naturalIdle(
        in motions: [StageMotionAsset]
    ) throws -> StageMotionAsset {
        guard let naturalIdle = motions.first(where: {
            $0.id == MotionPackageStore.naturalIdleID
        }) else {
            throw MotionPackageError.motionNotFound
        }
        return naturalIdle
    }

    private func savePreferredMotion(
        _ motionID: String,
        for engine: PresenceEngine?
    ) {
        guard let preferenceKey = preferenceKey(for: engine) else { return }
        defaults.set(motionID, forKey: preferenceKey)
    }

    private func preferenceKey(for engine: PresenceEngine?) -> String? {
        switch engine {
        case .vrm:
            MotionPreferenceKey.vrm
        case .pmx:
            MotionPreferenceKey.pmx
        case .orb, .live2D, nil:
            nil
        }
    }

    private func clearPreferredMotionReferences(to motionID: String) {
        for key in [MotionPreferenceKey.vrm, MotionPreferenceKey.pmx]
        where defaults.string(forKey: key) == motionID {
            defaults.removeObject(forKey: key)
        }
    }

    private func migrateUnambiguousPreference(
        from motion: StageMotionAsset
    ) {
        guard
            motion.format == .vrma,
            defaults.string(forKey: MotionPreferenceKey.vrm) == nil
        else {
            return
        }
        defaults.set(motion.id, forKey: MotionPreferenceKey.vrm)
    }

    private func activateInstalledIfPossible(
        _ package: PresencePackage,
        using service: PresenceCommandService
    ) throws {
        guard package.rendererAvailable else { return }
        try service.store.activate(id: package.manifest.id)
    }

    private func show(message: String) {
        self.message = message
        hasError = false
    }

    private func show(error: Error?) {
        message = (error as? LocalizedError)?.errorDescription
            ?? error?.localizedDescription
            ?? "无法打开角色或动作目录。"
        hasError = true
    }
}

extension MotionFormatFilter.Engine {
    init(_ engine: PresenceEngine?) {
        switch engine {
        case .vrm: self = .vrm
        case .pmx: self = .pmx
        case .live2D: self = .live2D
        case .orb: self = .orb
        case nil: self = .unspecified
        }
    }
}

extension MotionFormatFilter.Format {
    init(_ format: StageMotionFormat) {
        switch format {
        case .procedural: self = .procedural
        case .vrma: self = .vrma
        case .vmd: self = .vmd
        }
    }
}

extension StageMotionAsset: MotionLibraryFiltering {
    var libraryMotionID: String { id }
    var boneFormat: MotionFormatFilter.Format { MotionFormatFilter.Format(format) }
}

private enum PresenceDownloadError: Error, LocalizedError {
    case packageTooLarge

    var errorDescription: String? {
        "模型包超过 500 MB，已停止安装。"
    }
}

private enum PresenceSettingsError: Error, LocalizedError {
    case storeUnavailable

    var errorDescription: String? {
        "无法打开角色或动作目录。"
    }
}
