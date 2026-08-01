@preconcurrency import AVFoundation
import Combine
@preconcurrency import Foundation

private struct StageVideoEndedItem: @unchecked Sendable {
    let item: AVPlayerItem?
}

enum StageVideoPlaybackMode: String, CaseIterable, Codable, Sendable {
    case once
    case loop
    case randomSequence

    var displayName: String {
        switch self {
        case .once:
            "单次"
        case .loop:
            "循环"
        case .randomSequence:
            "随机拼接"
        }
    }

    var symbolName: String {
        switch self {
        case .once:
            "play.fill"
        case .loop:
            "repeat"
        case .randomSequence:
            "shuffle"
        }
    }
}

struct StageVideoAsset: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    let tags: Set<String>

    init(url: URL) {
        let resolvedURL = url.standardizedFileURL
        self.url = resolvedURL
        id = resolvedURL.path
        displayName = resolvedURL
            .deletingPathExtension()
            .lastPathComponent
        tags = Set(
            displayName
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
    }
}

struct StageBoundVideoPrompt: Identifiable, Equatable, Sendable {
    let trackID: String
    let trackTitle: String
    let asset: StageVideoAsset

    var id: String {
        "\(trackID)::\(asset.id)"
    }
}

enum StageVideoSequencePlanner {
    static func nextIndex(
        mode: StageVideoPlaybackMode,
        currentIndex: Int,
        count: Int,
        randomUnit: Double
    ) -> Int? {
        guard count > 0 else {
            return nil
        }
        let current = min(max(currentIndex, 0), count - 1)
        switch mode {
        case .once:
            return nil
        case .loop:
            return current
        case .randomSequence:
            guard count > 1 else {
                return current
            }
            let boundedRandom = min(max(randomUnit, 0), 0.999_999)
            let candidate = Int(floor(boundedRandom * Double(count - 1)))
            return candidate >= current ? candidate + 1 : candidate
        }
    }
}

struct StageVideoProgramDirector: Sendable {
    func rankedAssets(
        _ assets: [StageVideoAsset],
        for cue: ProgramVisualCue
    ) -> [StageVideoAsset] {
        let preferredTags = tags(for: cue)
        return assets.sorted { lhs, rhs in
            let lhsScore = score(lhs, preferredTags: preferredTags)
            let rhsScore = score(rhs, preferredTags: preferredTags)
            if lhsScore == rhsScore {
                return lhs.id < rhs.id
            }
            return lhsScore > rhsScore
        }
    }

    private func tags(for cue: ProgramVisualCue) -> Set<String> {
        var values: Set<String>
        switch cue.mood {
        case .pulse:
            values = [
                "neon", "city", "night", "drive", "dance",
                "霓虹", "城市", "夜", "公路", "舞台",
            ]
        case .liquid:
            values = [
                "water", "ocean", "rain", "river", "cloud",
                "水", "海", "雨", "河", "云",
            ]
        case .afterglow:
            values = [
                "cozy", "wood", "cafe", "sunset", "morning",
                "温暖", "木屋", "咖啡", "日落", "清晨",
            ]
        }
        switch cue.role {
        case .opener:
            values.formUnion(["intro", "arrival", "开场", "进入"])
        case .build:
            values.formUnion(["flow", "travel", "流动", "行走"])
        case .peak:
            values.formUnion(["peak", "fast", "高潮", "高能"])
        case .cooldown:
            values.formUnion(["calm", "slow", "安静", "慢"])
        case .closer:
            values.formUnion(["outro", "sleep", "晚安", "结束"])
        }
        return values
    }

    private func score(
        _ asset: StageVideoAsset,
        preferredTags: Set<String>
    ) -> Int {
        let name = asset.displayName.lowercased()
        return preferredTags.reduce(into: 0) { result, tag in
            if asset.tags.contains(tag) || name.contains(tag) {
                result += 1
            }
        }
    }
}

@MainActor
final class StageVideoPlaybackStore: ObservableObject {
    private static let modeDefaultsKey = "stage.video.playback-mode"
    private static let assetPathsDefaultsKey = "stage.video.asset-paths"
    private static let selectedAssetDefaultsKey = "stage.video.selected-asset"
    private static let brightnessDefaultsKey = "stage.video.brightness"
    private static let enabledDefaultsKey = "stage.video.user-enabled"
    private static let bindingsDefaultsKey = "stage.video.track-bindings"

    let player = AVQueuePlayer()

    @Published private(set) var assets: [StageVideoAsset]
    @Published private(set) var mode: StageVideoPlaybackMode
    @Published private(set) var selectedAssetID: String?
    @Published private(set) var activeAssetID: String?
    @Published private(set) var isActive = false
    @Published private(set) var brightness: Float
    @Published private(set) var isUserEnabled = false
    @Published private(set) var pendingBoundVideo: StageBoundVideoPrompt?

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var endObserver: NSObjectProtocol?
    private var looper: AVPlayerLooper?
    private var randomAssets: [StageVideoAsset] = []
    private var queuedAssetIDs: [String] = []
    private var itemAssetIDs: [ObjectIdentifier: String] = [:]
    private var trackBindings: [String: String] = [:]
    private var temporaryBoundTrackID: String?

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        mode = defaults.string(forKey: Self.modeDefaultsKey)
            .flatMap(StageVideoPlaybackMode.init(rawValue:))
            ?? .loop
        brightness = defaults.object(
            forKey: Self.brightnessDefaultsKey
        ) == nil
            ? StageCompositingProfile.video.videoOpacity
            : Self.clampBrightness(
                Float(defaults.double(forKey: Self.brightnessDefaultsKey))
            )
        let restoredAssets = defaults
            .stringArray(forKey: Self.assetPathsDefaultsKey)
            ?? []
        assets = restoredAssets
            .map { StageVideoAsset(url: URL(fileURLWithPath: $0)) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
        let restoredSelection = defaults.string(
            forKey: Self.selectedAssetDefaultsKey
        )
        selectedAssetID = assets.contains(where: {
            $0.id == restoredSelection
        }) ? restoredSelection : assets.first?.id
        isUserEnabled = defaults.object(
            forKey: Self.enabledDefaultsKey
        ) == nil
            ? !assets.isEmpty
            : defaults.bool(forKey: Self.enabledDefaultsKey)
        trackBindings = defaults.dictionary(
            forKey: Self.bindingsDefaultsKey
        ) as? [String: String] ?? [:]

        player.isMuted = true
        player.volume = 0
        endObserver = notificationCenter.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let ended = StageVideoEndedItem(
                item: notification.object as? AVPlayerItem
            )
            Task { @MainActor [weak self, ended] in
                self?.handlePlaybackEnded(ended.item)
            }
        }
    }

    var selectedAsset: StageVideoAsset? {
        assets.first { $0.id == selectedAssetID }
    }

    var activeAsset: StageVideoAsset? {
        assets.first { $0.id == activeAssetID }
    }

    func add(_ urls: [URL]) {
        let imported = urls
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .map(StageVideoAsset.init(url:))
        guard !imported.isEmpty else {
            return
        }
        for asset in imported where !assets.contains(where: {
            $0.id == asset.id
        }) {
            assets.append(asset)
        }
        selectedAssetID = imported.first?.id
        setUserEnabled(true)
        persistLibrary()
        start()
    }

    func select(_ assetID: String) {
        guard assets.contains(where: { $0.id == assetID }) else {
            return
        }
        selectedAssetID = assetID
        temporaryBoundTrackID = nil
        setUserEnabled(true)
        defaults.set(assetID, forKey: Self.selectedAssetDefaultsKey)
        start()
    }

    func toggle(_ assetID: String) {
        if isActive, activeAssetID == assetID {
            disableByUser()
        } else {
            select(assetID)
        }
    }

    func remove(_ assetID: String) {
        guard assets.contains(where: { $0.id == assetID }) else {
            return
        }
        let shouldResume = isActive && isUserEnabled
        stopPlayback()
        assets.removeAll { $0.id == assetID }
        trackBindings = trackBindings.filter { $0.value != assetID }
        if selectedAssetID == assetID {
            selectedAssetID = assets.first?.id
        }
        persistLibrary()
        persistBindings()
        if shouldResume, selectedAsset != nil {
            start()
        }
    }

    func setMode(_ mode: StageVideoPlaybackMode) {
        self.mode = mode
        temporaryBoundTrackID = nil
        setUserEnabled(true)
        defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey)
        if selectedAsset != nil {
            start()
        }
    }

    func setBrightness(_ brightness: Float) {
        let value = Self.clampBrightness(brightness)
        self.brightness = value
        defaults.set(value, forKey: Self.brightnessDefaultsKey)
    }

    func apply(
        _ cue: ProgramVisualCue,
        trackID: String? = nil,
        trackTitle: String? = nil
    ) {
        randomAssets = StageVideoProgramDirector().rankedAssets(
            assets,
            for: cue
        )

        guard let trackID else {
            if isUserEnabled, isActive, mode == .randomSequence {
                startRandomSequence()
            }
            return
        }

        pendingBoundVideo = nil
        if temporaryBoundTrackID != trackID {
            temporaryBoundTrackID = nil
            if !isUserEnabled {
                stopPlayback()
            }
        }

        if let asset = boundAsset(for: trackID) {
            if isUserEnabled {
                playBoundAsset(asset, trackID: trackID, temporary: false)
            } else {
                pendingBoundVideo = StageBoundVideoPrompt(
                    trackID: trackID,
                    trackTitle: trackTitle ?? "这首歌",
                    asset: asset
                )
            }
            return
        }

        guard isUserEnabled else {
            stopPlayback()
            return
        }
        if mode == .randomSequence, !assets.isEmpty {
            startRandomSequence()
        }
    }

    func bind(_ assetID: String, to trackID: String) {
        guard assets.contains(where: { $0.id == assetID }) else {
            return
        }
        trackBindings[trackID] = assetID
        persistBindings()
    }

    func unbind(trackID: String) {
        trackBindings.removeValue(forKey: trackID)
        persistBindings()
    }

    func boundAsset(for trackID: String) -> StageVideoAsset? {
        guard let assetID = trackBindings[trackID] else {
            return nil
        }
        return assets.first { $0.id == assetID }
    }

    func playBoundVideo(for trackID: String) {
        guard let asset = boundAsset(for: trackID) else {
            return
        }
        playBoundAsset(
            asset,
            trackID: trackID,
            temporary: !isUserEnabled
        )
    }

    func playPendingBoundVideo() {
        guard let prompt = pendingBoundVideo else {
            return
        }
        pendingBoundVideo = nil
        playBoundAsset(
            prompt.asset,
            trackID: prompt.trackID,
            temporary: !isUserEnabled
        )
    }

    func dismissBoundVideoPrompt(id: String? = nil) {
        guard
            id == nil || pendingBoundVideo?.id == id
        else {
            return
        }
        pendingBoundVideo = nil
    }

    func start() {
        guard isUserEnabled, let selectedAsset else {
            stopPlayback()
            return
        }
        switch mode {
        case .once:
            startOnce(selectedAsset)
        case .loop:
            startLoop(selectedAsset)
        case .randomSequence:
            randomAssets = assets
            startRandomSequence()
        }
    }

    func resume() {
        guard
            isUserEnabled || temporaryBoundTrackID != nil,
            selectedAsset != nil
        else {
            return
        }
        if player.currentItem == nil {
            start()
        } else {
            isActive = true
            player.play()
        }
    }

    func pause() {
        player.pause()
    }

    func stop() {
        disableByUser()
    }

    func disableByUser() {
        temporaryBoundTrackID = nil
        pendingBoundVideo = nil
        setUserEnabled(false)
        stopPlayback()
    }

    private func stopPlayback() {
        player.pause()
        looper = nil
        player.removeAllItems()
        queuedAssetIDs = []
        itemAssetIDs = [:]
        activeAssetID = nil
        isActive = false
    }

    private func playBoundAsset(
        _ asset: StageVideoAsset,
        trackID: String,
        temporary: Bool
    ) {
        selectedAssetID = asset.id
        defaults.set(asset.id, forKey: Self.selectedAssetDefaultsKey)
        temporaryBoundTrackID = temporary ? trackID : nil
        startLoop(asset)
    }

    private func startOnce(_ asset: StageVideoAsset) {
        resetQueue()
        player.actionAtItemEnd = .pause
        let item = makeItem(for: asset)
        player.insert(item, after: nil)
        activeAssetID = asset.id
        isActive = true
        player.play()
    }

    private func startLoop(_ asset: StageVideoAsset) {
        resetQueue()
        player.actionAtItemEnd = .advance
        let item = AVPlayerItem(url: asset.url)
        itemAssetIDs[ObjectIdentifier(item)] = asset.id
        looper = AVPlayerLooper(
            player: player,
            templateItem: item
        )
        activeAssetID = asset.id
        isActive = true
        player.play()
    }

    private func startRandomSequence() {
        let source = randomAssets.isEmpty ? assets : randomAssets
        guard !source.isEmpty else {
            stop()
            return
        }
        resetQueue()
        player.actionAtItemEnd = .advance
        randomAssets = source
        let selectedIndex = source.firstIndex(where: {
            $0.id == selectedAssetID
        }) ?? 0
        var currentIndex = selectedIndex
        appendRandomAsset(source[currentIndex])
        let preloadCount = min(max(source.count * 2, 4), 12)
        for _ in 1 ..< preloadCount {
            currentIndex = StageVideoSequencePlanner.nextIndex(
                mode: .randomSequence,
                currentIndex: currentIndex,
                count: source.count,
                randomUnit: Double.random(in: 0 ..< 1)
            ) ?? currentIndex
            appendRandomAsset(source[currentIndex])
        }
        activeAssetID = queuedAssetIDs.first
        isActive = true
        player.play()
    }

    private func appendRandomAsset(_ asset: StageVideoAsset) {
        let item = makeItem(for: asset)
        guard player.canInsert(item, after: player.items().last) else {
            return
        }
        player.insert(item, after: player.items().last)
        queuedAssetIDs.append(asset.id)
    }

    private func makeItem(for asset: StageVideoAsset) -> AVPlayerItem {
        let item = AVPlayerItem(url: asset.url)
        itemAssetIDs[ObjectIdentifier(item)] = asset.id
        return item
    }

    private func resetQueue() {
        player.pause()
        looper = nil
        player.removeAllItems()
        queuedAssetIDs = []
        itemAssetIDs = [:]
    }

    private func handlePlaybackEnded(_ item: AVPlayerItem?) {
        guard
            let item,
            let endedAssetID = itemAssetIDs.removeValue(
                forKey: ObjectIdentifier(item)
            )
        else {
            return
        }
        switch mode {
        case .once:
            guard endedAssetID == activeAssetID else {
                return
            }
            isActive = false
            activeAssetID = nil
        case .loop:
            break
        case .randomSequence:
            if queuedAssetIDs.first == endedAssetID {
                queuedAssetIDs.removeFirst()
            } else if let index = queuedAssetIDs.firstIndex(of: endedAssetID) {
                queuedAssetIDs.remove(at: index)
            }
            activeAssetID = queuedAssetIDs.first
            guard !randomAssets.isEmpty else {
                return
            }
            let previousID = queuedAssetIDs.last ?? endedAssetID
            let currentIndex = randomAssets.firstIndex(where: {
                $0.id == previousID
            }) ?? 0
            let nextIndex = StageVideoSequencePlanner.nextIndex(
                mode: .randomSequence,
                currentIndex: currentIndex,
                count: randomAssets.count,
                randomUnit: Double.random(in: 0 ..< 1)
            ) ?? currentIndex
            appendRandomAsset(randomAssets[nextIndex])
        }
    }

    private func persistLibrary() {
        defaults.set(
            assets.map { $0.url.path },
            forKey: Self.assetPathsDefaultsKey
        )
        defaults.set(
            selectedAssetID,
            forKey: Self.selectedAssetDefaultsKey
        )
    }

    private func persistBindings() {
        defaults.set(trackBindings, forKey: Self.bindingsDefaultsKey)
    }

    private func setUserEnabled(_ enabled: Bool) {
        isUserEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
    }

    private static func clampBrightness(_ value: Float) -> Float {
        min(max(value, 0.15), 1)
    }
}
