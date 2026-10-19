import AppKit
import AVFoundation

@MainActor
final class WallpaperManager: NSObject {
    static let shared = WallpaperManager()

    private(set) var currentVideoURL: URL?
    private(set) var isMuted = true
    private(set) var volume = 1.0
    private(set) var isLoading = false
    private(set) var policy = PlaybackPolicy()
    private(set) var pauseInLowPowerMode: Bool
    private(set) var usesLowMemoryPlayback: Bool
    var isPaused: Bool { policy.isPaused }
    var screenCount: Int { playbacks.count }
    var onStateChange: (() -> Void)?
    var onError: ((String) -> Void)?

    private var asset: AVURLAsset?
    private var playbacks: [String: ScreenPlayback] = [:]
    private var loadingTask: Task<Void, Never>?
    private var pendingAsset: AVURLAsset?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var loadGeneration = 0
    private var screenUpdate: DispatchWorkItem?
    private var reportedPlaybackFailure = false
    private let store: WallpaperStateStore
    private let screenProvider: () -> [NSScreen]
    private let observesSystemEvents: Bool
    private static let lowPowerKey = "dw_pause_in_low_power_mode"
    private static let lowMemoryKey = "dw_low_memory_playback"

    init(defaults: UserDefaults = .standard,
         observesSystemEvents: Bool = true,
         screenProvider: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        store = WallpaperStateStore(defaults: defaults)
        self.screenProvider = screenProvider
        self.observesSystemEvents = observesSystemEvents
        pauseInLowPowerMode = defaults.object(forKey: Self.lowPowerKey) as? Bool ?? true
        usesLowMemoryPlayback = defaults.object(forKey: Self.lowMemoryKey) as? Bool ?? true
        super.init()
        if observesSystemEvents {
            setupNotifications()
            setupMemoryPressureMonitoring()
            refreshPowerState()
        }
    }

    var statusText: String {
        if policy.suspensions.contains(.memoryPressure) { return "記憶體吃緊，已釋放影片資源" }
        if isLoading { return "正在載入影片…" }
        guard currentVideoURL != nil else { return "選擇影片，開始使用動態桌布" }
        if reportedPlaybackFailure { return "播放失敗，按「播放」重試" }
        if isPaused { return "已暫停" }
        if policy.suspensions.contains(.lowPower) { return "低耗電模式，已自動暫停" }
        if !policy.suspensions.isEmpty { return "系統休眠或使用者切換，已自動暫停" }
        if playbacks.isEmpty { return "等待可用的螢幕" }
        return "正在播放 · \(playbacks.count) 個螢幕"
    }

    @discardableResult
    func applyVideoWallpaper(from url: URL) -> Task<Void, Never> {
        loadVideo(url: url, restoredState: nil)
    }

    @discardableResult
    private func loadVideo(url: URL, restoredState: SavedState?) -> Task<Void, Never> {
        cancelLoading()
        let generation = loadGeneration
        isLoading = true
        onStateChange?()
        let candidate = AVURLAsset(url: url)
        pendingAsset = candidate
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.loadGeneration {
                    self.loadingTask = nil
                    self.pendingAsset = nil
                }
            }
            do {
                try Task.checkCancellation()
                let validatedAsset: AVURLAsset
                if url == self.currentVideoURL, let existing = self.asset, !self.reportedPlaybackFailure {
                    validatedAsset = existing
                } else {
                    validatedAsset = try await Self.validateVideo(candidate)
                }
                try Task.checkCancellation()
                guard generation == self.loadGeneration else { return }

                // Keep the previous wallpaper until the replacement is validated.
                let reusesPlayback = url == self.currentVideoURL && !self.reportedPlaybackFailure && !self.playbacks.isEmpty
                if !reusesPlayback { self.teardownPlaybacks() }
                self.currentVideoURL = url
                self.asset = self.policy.suspensions.contains(.memoryPressure) ? nil : validatedAsset
                self.reportedPlaybackFailure = false
                if let state = restoredState {
                    self.isMuted = state.isMuted
                    self.volume = min(1, max(0, state.volume.isFinite ? state.volume : 1))
                    self.policy.isPaused = state.isPaused
                } else {
                    self.policy.isPaused = false
                }
                self.isLoading = false
                self.reconcileScreens()
                self.persistState()
                self.onStateChange?()
            } catch {
                guard generation == self.loadGeneration, !Task.isCancelled else { return }
                self.isLoading = false
                self.onStateChange?()
                self.onError?("\(url.lastPathComponent)\n\(error.localizedDescription)")
            }
        }
        loadingTask = task
        return task
    }

    private static func validateVideo(_ asset: AVURLAsset) async throws -> AVURLAsset {
        let url = asset.url
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw VideoError.unreadable
        }
        let playable = try await asset.load(.isPlayable)
        try Task.checkCancellation()
        let protected = try await asset.load(.hasProtectedContent)
        try Task.checkCancellation()
        let duration = try await asset.load(.duration)
        try Task.checkCancellation()
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard playable, !protected, !tracks.isEmpty,
              duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw VideoError.unsupported
        }
        return asset
    }

    @discardableResult
    func restoreIfNeeded() -> Task<Void, Never>? {
        // A temporarily unavailable external drive must not erase saved settings.
        guard let state = store.load(), let url = URL(string: state.fileURL) else { return nil }
        return loadVideo(url: url, restoredState: state)
    }

    func pause() {
        policy.isPaused = true
        synchronizePlayback()
        persistState()
    }

    func resume() {
        guard let url = currentVideoURL else { return }
        policy.isPaused = false
        persistState()
        if policy.suspensions.contains(.memoryPressure) {
            synchronizePlayback()
            return
        }
        if reportedPlaybackFailure || asset == nil {
            loadVideo(url: url, restoredState: savedState())
        } else { reconcileScreens() }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        synchronizePlayback()
        persistState()
    }

    func setVolume(_ newVolume: Double) {
        guard newVolume.isFinite else { return }
        volume = min(1, max(0, newVolume))
        synchronizePlayback()
        persistState()
    }

    func setPauseInLowPowerMode(_ enabled: Bool) {
        pauseInLowPowerMode = enabled
        store.defaults.set(enabled, forKey: Self.lowPowerKey)
        refreshPowerState()
    }

    func setLowMemoryPlayback(_ enabled: Bool) {
        guard enabled != usesLowMemoryPlayback else { return }
        usesLowMemoryPlayback = enabled
        store.defaults.set(enabled, forKey: Self.lowMemoryKey)
        teardownPlaybacks()
        reconcileScreens()
        onStateChange?()
    }

    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let events = self.memoryPressureSource?.data else { return }
            self.handleMemoryPressure(events)
        }
        memoryPressureSource = source
        source.resume()
    }

    /// Internal so tests can inject notifications without stressing system RAM.
    func handleMemoryPressure(_ events: DispatchSource.MemoryPressureEvent) {
        if !events.intersection([.warning, .critical]).isEmpty {
            policy.suspensions.insert(.memoryPressure)
            // Let any pending metadata validation finish so a startup restore or
            // new selection is not lost. Its commit drops the asset and cannot
            // create decoders while the memory-pressure suspension is present.
            screenUpdate?.cancel()
            screenUpdate = nil
            teardownPlaybacks()
            asset = nil
            onStateChange?()
        } else if events.contains(.normal) {
            guard policy.suspensions.remove(.memoryPressure) != nil else { return }
            recoverReleasedPlayback()
            onStateChange?()
        }
    }

    private func recoverReleasedPlayback() {
        guard policy.shouldPlay, asset == nil, !isLoading, !reportedPlaybackFailure,
              let url = currentVideoURL else { return }
        loadVideo(url: url, restoredState: savedState())
    }

    private func savedState() -> SavedState? {
        guard let url = currentVideoURL else { return nil }
        return SavedState(fileURL: url.absoluteString, isMuted: isMuted, isPaused: isPaused, volume: volume)
    }

    /// Removing a wallpaper is the only action that clears the saved selection.
    func stop() {
        cancelLoading()
        screenUpdate?.cancel()
        screenUpdate = nil
        teardownPlaybacks()
        asset = nil
        currentVideoURL = nil
        policy.isPaused = false
        reportedPlaybackFailure = false
        store.remove()
        onStateChange?()
    }

    /// Quitting releases resources but preserves the next launch's state.
    func shutdown() {
        persistState()
        cancelLoading()
        screenUpdate?.cancel()
        screenUpdate = nil
        teardownPlaybacks()
        asset = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        if observesSystemEvents {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
    }

    private func cancelLoading() {
        loadGeneration += 1
        loadingTask?.cancel()
        pendingAsset?.cancelLoading()
        pendingAsset = nil
        loadingTask = nil
        isLoading = false
    }

    private func persistState() {
        if let state = savedState() { store.save(state) }
    }

    private func reconcileScreens() {
        guard let asset, !reportedPlaybackFailure, !policy.suspensions.contains(.memoryPressure) else { return }
        let screens = screenProvider()
        let desiredIDs = Set(screens.map(\.wallpaperIdentifier))
        for id in Array(playbacks.keys) where !desiredIDs.contains(id) {
            if let retired = playbacks.removeValue(forKey: id) { retire(retired) }
        }
        for screen in screens {
            let id = screen.wallpaperIdentifier
            if let existing = playbacks[id] {
                existing.update(screen: screen)
            } else {
                let playback = ScreenPlayback(screen: screen, asset: asset, lowMemory: usesLowMemoryPlayback)
                playbacks[id] = playback
                playback.onFailure = { [weak self, weak playback] error in
                    guard let self, let playback, self.playbacks[id] === playback,
                          !self.reportedPlaybackFailure else { return }
                    self.reportedPlaybackFailure = true
                    self.policy.isPaused = true
                    self.teardownPlaybacks()
                    self.persistState()
                    self.onStateChange?()
                    self.onError?("影片播放中斷。請重新選擇影片或按「播放」重試。\n\(error)")
                }
                playback.observeFailures()
            }
        }
        synchronizePlayback()
    }

    private func synchronizePlayback() {
        // NSScreen.screens.first is the display with the menu bar. Only this
        // player's audio is audible, preventing echo on multi-display setups.
        let audioID = screenProvider().first?.wallpaperIdentifier
        for (id, playback) in playbacks {
            playback.player.isMuted = isMuted || id != audioID
            playback.player.volume = Float(volume)
            playback.setPlaying(policy.shouldPlay)
        }
        onStateChange?()
    }

    private func teardownPlaybacks() {
        let retired = Array(playbacks.values)
        playbacks.removeAll()
        for playback in retired { playback.shutdown() }
    }

    private func retire(_ playback: ScreenPlayback) {
        playback.shutdown()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshPowerState),
            name: .NSProcessInfoPowerStateDidChange, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func screenChanged() {
        screenUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcileScreens() }
        screenUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.screensDidSleepNotification: policy.suspensions.insert(.screenSleep)
        case NSWorkspace.screensDidWakeNotification: policy.suspensions.remove(.screenSleep)
        case NSWorkspace.willSleepNotification: policy.suspensions.insert(.systemSleep)
        case NSWorkspace.didWakeNotification: policy.suspensions.remove(.systemSleep)
        case NSWorkspace.sessionDidResignActiveNotification: policy.suspensions.insert(.inactiveSession)
        case NSWorkspace.sessionDidBecomeActiveNotification: policy.suspensions.remove(.inactiveSession)
        default: return
        }
        synchronizePlayback()
        if policy.suspensions.isEmpty {
            recoverReleasedPlayback()
            screenChanged()
        }
    }

    @objc private func refreshPowerState() {
        if pauseInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled {
            policy.suspensions.insert(.lowPower)
        } else {
            policy.suspensions.remove(.lowPower)
        }
        synchronizePlayback()
        recoverReleasedPlayback()
    }
}

private enum VideoError: LocalizedError {
    case unreadable, unsupported
    var errorDescription: String? {
        switch self {
        case .unreadable: return "無法讀取檔案。請確認檔案仍存在，且所在磁碟已連接。"
        case .unsupported: return "macOS 無法播放這個影片。請使用含視訊軌的 MP4、MOV 或 M4V 檔案。"
        }
    }
}

@MainActor
private final class ScreenPlayback {
    let player: AVPlayer
    let window: WallpaperWindow
    private var looper: AVPlayerLooper?
    private let view: VideoContainerView
    private let templateItem: AVPlayerItem
    private var observations: [NSKeyValueObservation] = []
    private var nativeSize = CGSize.zero
    private var loopNotification: NSObjectProtocol?
    private var failureNotification: NSObjectProtocol?
    private var wantsPlayback = false
    private var isSeeking = false
    private var isShutDown = false
    var onFailure: ((String) -> Void)?

    init(screen: NSScreen, asset: AVURLAsset, lowMemory: Bool) {
        templateItem = AVPlayerItem(asset: asset)
        // A buffering preference, not a hard memory limit for local decoders.
        templateItem.preferredForwardBufferDuration = lowMemory ? 1 : 0
        templateItem.appliesPerFrameHDRDisplayMetadata = true
        templateItem.preferredMaximumResolution = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor)
        if lowMemory {
            // One item, no preloaded loop replicas. Seeking may introduce a
            // small gap at the loop boundary; seamless mode remains available.
            player = AVPlayer(playerItem: templateItem)
            player.actionAtItemEnd = .pause
        } else {
            let queue = AVQueuePlayer()
            player = queue
            looper = AVPlayerLooper(player: queue, templateItem: templateItem)
        }
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false

        window = WallpaperWindow(contentRect: screen.frame, styleMask: .borderless,
                                 backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.animationBehavior = .none
        view = VideoContainerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        view.playerLayer.player = player
        window.contentView = view
        update(screen: screen)
        window.orderBack(nil)
        if lowMemory {
            loopNotification = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: templateItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.loopToBeginning() }
            }
            failureNotification = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: templateItem, queue: .main
            ) { [weak self] notification in
                let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "影片無法播放到結尾。"
                Task { @MainActor [weak self] in self?.onFailure?(message) }
            }
        }
        // The manager applies user pause and system suspension before playing.
    }

    func setPlaying(_ playing: Bool) {
        wantsPlayback = playing
        guard !isShutDown else { return }
        if playing {
            if !isSeeking, player.rate == 0 { player.play() }
        } else { player.pause() }
    }

    private func loopToBeginning() {
        guard !isShutDown, !isSeeking else { return }
        isSeeking = true
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, !self.isShutDown else { return }
                self.isSeeking = false
                if finished, self.wantsPlayback { self.player.play() }
            }
        }
    }

    func update(screen: NSScreen) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        view.playerLayer.contentsScale = screen.backingScaleFactor
        let size = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                          height: screen.frame.height * screen.backingScaleFactor)
        guard size != nativeSize else { return }
        nativeSize = size
        templateItem.preferredMaximumResolution = size
        for item in looper?.loopingPlayerItems ?? [] { item.preferredMaximumResolution = size }
    }

    func observeFailures() {
        observations = [
            player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
                guard player.status == .failed else { return }
                let message = player.error?.localizedDescription ?? "播放器無法播放此影片。"
                Task { @MainActor [weak self] in self?.onFailure?(message) }
            },
            templateItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "影片無法解碼。"
                Task { @MainActor [weak self] in self?.onFailure?(message) }
            }
        ]
        if let looper {
            observations.append(looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                let message = looper.error?.localizedDescription ?? "影片無法循環播放。"
                Task { @MainActor [weak self] in self?.onFailure?(message) }
            })
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        wantsPlayback = false
        onFailure = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let loopNotification { NotificationCenter.default.removeObserver(loopNotification) }
        if let failureNotification { NotificationCenter.default.removeObserver(failureNotification) }
        loopNotification = nil
        failureNotification = nil
        player.pause()
        view.playerLayer.player = nil
        looper?.disableLooping()
        looper = nil
        if let queue = player as? AVQueuePlayer { queue.removeAllItems() }
        player.replaceCurrentItem(with: nil)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

private final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class VideoContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private extension NSScreen {
    var wallpaperIdentifier: String {
        if let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return "\(localizedName):\(frame.origin.x):\(frame.origin.y)"
    }
}
