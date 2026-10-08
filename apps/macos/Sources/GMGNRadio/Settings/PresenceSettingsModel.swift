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
    private let orbSettings: RustProductSettingsClient
    private var orbSaveTask: Task<Void, Never>?
    private var pendingOrbChanges: [String: Any] = [:]
    private let avatarRuntime: StageAvatarRuntimeStore
    private let onWillActivateMotion: (String) -> Void
    private let playbackCompatibility: (PresenceEngine?, StageMotionFormat) -> MotionCompatibility
    private var remoteMotionLibrary: RemoteMotionLibrary?
    private var importPanel: NSOpenPanel?
    var onSelectionChanged: (() -> Void)?
    private let renderPolicy: String
    private let supportedEngines: Set<String>
    private var selectionTask: Task<Void, Never>?

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
        productSettings: RustProductSettingsClient = .shared,
        remoteMotionLibrary: RemoteMotionLibrary? = nil,
        renderPolicy: String = "native",
        supportedEngines: Set<String> = ["orb", "vrm", "pmx", "live2d"],
        playbackCompatibility: ((PresenceEngine?, StageMotionFormat) -> MotionCompatibility)? = nil,
        onWillActivateMotion: @escaping (String) -> Void = { motionID in
            NotificationCenter.default.post(
                name: .gmgnManualMotionWillActivate,
                object: motionID
            )
        }
    ) {
        self.defaults = defaults
        orbSettings = productSettings
        self.renderPolicy = renderPolicy; self.supportedEngines = supportedEngines
        self.avatarRuntime = avatarRuntime
        self.onWillActivateMotion = onWillActivateMotion
        self.playbackCompatibility = playbackCompatibility ?? {
            Self.motionCompatibility(avatarEngine: $0, motionFormat: $1)
        }
        self.remoteMotionLibrary = remoteMotionLibrary
        remoteMotionCatalogURL = remoteMotionLibrary?.catalogURL.absoluteString
            ?? productSettings.confirmed?.values.remoteMotionCatalogURL ?? ""
        orbAppearance = OrbAppearance.load(from: defaults, settings: productSettings)
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
        scheduleOrbChanges(["orbRed": red, "orbGreen": green, "orbBlue": blue])
    }

    func setOrbFlowIntensity(_ value: Float) {
        scheduleOrbChanges(["orbFlowIntensity": value])
    }

    private func scheduleOrbChanges(_ changes: [String: Any]) {
        pendingOrbChanges.merge(changes) { _, newest in newest }
        orbSaveTask?.cancel()
        orbSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self else { return }
            let changes = pendingOrbChanges; pendingOrbChanges = [:]
            do {
                _ = try await orbSettings.apply(changes)
                orbAppearance = OrbAppearance.load(from: defaults, settings: orbSettings)
                NotificationCenter.default.post(name: .orbAppearanceDidChange, object: defaults)
                message = "外观已保存。"; hasError = false
            } catch { message = "外观未保存，请检查后台连接。"; hasError = true }
        }
    }

    func load() {
        runSelection { try await self.loadConfirmed() }
    }

    func loadConfirmed() async throws {
        try await orbSettings.ensureLoaded()
        orbAppearance = OrbAppearance.load(from: defaults, settings: orbSettings)
        if remoteMotionLibrary == nil { remoteMotionCatalogURL = orbSettings.confirmed?.values.remoteMotionCatalogURL ?? "" }
        let service = try requireService(), motionStore = try requireMotionStore()
        let catalog = try service.list(), clips = try motionStore.listMotions()
        _ = try await service.store.selectionAuthority.bind(packages: catalog, motions: clips,
            packageRoot: service.store.rootURL, motionRoot: motionStore.rootURL,
            policy: renderPolicy, supportedEngines: supportedEngines,
            builtInMotionIDs: Set(motionStore.builtInMotions.map(\.id)).union([MotionPackageStore.naturalIdleID]),
            legacyPreferences: ["vrm": defaults.string(forKey: MotionPreferenceKey.vrm),
                                "pmx": defaults.string(forKey: MotionPreferenceKey.pmx)].compactMapValues { $0 })
        try refreshEffectiveMotionForActiveAvatar()
        onSelectionChanged?()
    }
    private func runSelection(_ body: @escaping @MainActor () async throws -> Void) {
        guard selectionTask == nil else { return }
        isWorking = true
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false; selectionTask = nil }
            do { try await body() } catch { show(error: error) }
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
        runSelection { try await self.activateMotionConfirmed(motion) }
    }
    func activateMotionConfirmed(_ motion: StageMotionAsset) async throws {
        onWillActivateMotion(motion.id)
        try await requireMotionStore().activateAsync(id: motion.id)
        try refreshEffectiveMotionForActiveAvatar(); onSelectionChanged?()
        show(message: "正在载入 \(motion.name)…")
    }

    func removeMotion(_ motion: StageMotionAsset) {
        runSelection { [self] in
            let store = try requireMotionStore()
            try await store.removeAsync(id: motion.id)
            try await loadConfirmed()
            show(message: "已移除 \(motion.name)。")
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
            let confirmed = try await orbSettings.apply(["remoteMotionCatalogURL": library.catalogURL.absoluteString])
            remoteMotionCatalogURL = confirmed.values.remoteMotionCatalogURL
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
            try await loadConfirmed()
            if motionCompatibility(installed) == .compatible {
                onWillActivateMotion(installed.id)
                try await store.activateAsync(id: installed.id)
                try refreshEffectiveMotionForActiveAvatar(); onSelectionChanged?()
                show(message: "已安装，正在载入 \(installed.name)。")
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
        runSelection { [self] in
            let store = try requireMotionStore()
            let installed = try store.installMotion(from: sourceURL)
            motions = try store.listMotions()
            try await loadConfirmed()
            if motionCompatibility(installed) == .compatible {
                onWillActivateMotion(installed.id)
                try await store.activateAsync(id: installed.id)
                try refreshEffectiveMotionForActiveAvatar(); onSelectionChanged?()
                show(message: "动作已安装，正在载入。")
            } else {
                activeMotionID = try store.activeMotion().id
                show(message: "动作已安装；切换到兼容角色后即可使用。")
            }
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
            try await loadConfirmed()
            try await activateConfirmed(installed)
            downloadURL = ""
            show(message: "模型已安装。")
        } catch {
            show(error: error)
        }
    }

    func activate(_ package: PresencePackage) {
        runSelection { try await self.activateConfirmed(package) }
    }
    func activateConfirmed(_ package: PresencePackage) async throws {
        try await requireService().store.activateAsync(id: package.manifest.id)
        try refreshEffectiveMotionForActiveAvatar(); onSelectionChanged?()
        show(message: "正在载入 \(package.manifest.name)…")
    }

    func remove(_ package: PresencePackage) {
        runSelection { [self] in
            try await requireService().store.removeAsync(id: package.manifest.id)
            try await loadConfirmed()
            show(message: "已移除 \(package.manifest.name)。")
        }
    }

    private func install(from sourceURL: URL) {
        runSelection { [self] in
            let service = try requireService()
            let installed = try service.store.installPackage(from: sourceURL)
            try await loadConfirmed()
            try await activateConfirmed(installed)
            show(message: "模型已安装。")
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
        packages = try requireService().list()
        guard let selection = store.selectionAuthority.confirmed else {
            throw RustPresenceSelectionClient.SelectionError.unavailable
        }
        activeMotionID = selection.motionID
        avatarRuntime.refresh()
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
