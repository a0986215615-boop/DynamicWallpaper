import AppKit
import AVFoundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct RegressionTests {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw TestFailure(description: message) }
    }

    @MainActor static func main() async {
        do {
            try await run()
            print("PASS: all regression checks")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        var policy = PlaybackPolicy()
        policy.isPaused = true
        policy.suspensions.insert(.screenSleep)
        policy.suspensions.remove(.screenSleep)
        try require(!policy.shouldPlay, "Waking the display must preserve manual pause")
        policy.isPaused = false
        policy.suspensions = [.screenSleep, .systemSleep, .inactiveSession, .lowPower]
        policy.suspensions.remove(.screenSleep)
        policy.suspensions.remove(.systemSleep)
        try require(!policy.shouldPlay, "Waking must not override another suspension")
        policy.suspensions.remove(.inactiveSession)
        try require(!policy.shouldPlay, "Low power must keep playback suspended")
        policy.suspensions.remove(.lowPower)
        try require(policy.shouldPlay, "Playback should recover once every suspension ends")
        print("PASS: overlapping sleep, session and power transitions")

        let suite = "DynamicWallpaper.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WallpaperStateStore(defaults: defaults)
        let oldJSON = Data(#"{"fileURL":"file:///tmp/old.mov","isMuted":false,"isPaused":true,"volume":0.5}"#.utf8)
        defaults.set(oldJSON, forKey: WallpaperStateStore.key)
        try require(store.load() == SavedState(fileURL: "file:///tmp/old.mov", isMuted: false, isPaused: true, volume: 0.5), "Version 1 state compatibility")
        defaults.set(Data("invalid".utf8), forKey: WallpaperStateStore.key)
        try require(store.load() == nil, "Invalid saved data should not crash")
        store.remove()
        print("PASS: legacy and damaged preference data")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicWallpaperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.mov")
        let secondURL = directory.appendingPathComponent("second.mov")
        try await makeVideo(at: firstURL)
        try FileManager.default.copyItem(at: firstURL, to: secondURL)
        let manager = WallpaperManager(defaults: defaults, observesSystemEvents: false, screenProvider: { [] })
        var errors: [String] = []
        manager.onError = { errors.append($0) }
        await manager.applyVideoWallpaper(from: firstURL).value
        try require(manager.currentVideoURL == firstURL && errors.isEmpty, "A valid local video must load")
        manager.setMuted(false)
        manager.setVolume(0.5)
        manager.pause()
        manager.shutdown()
        try require(store.load()?.isPaused == true, "Quit must retain pause")
        try require(store.load()?.isMuted == false, "Quit must retain mute choice")
        try require(store.load()?.fileURL == firstURL.absoluteString, "Quit must retain the video")

        let restored = WallpaperManager(defaults: defaults, observesSystemEvents: false, screenProvider: { [] })
        restored.onError = { errors.append($0) }
        await restored.restoreIfNeeded()?.value
        try require(restored.currentVideoURL == firstURL && restored.isPaused && !restored.isMuted && restored.volume == 0.5, "Relaunch must restore all settings")
        await restored.applyVideoWallpaper(from: firstURL).value
        try require(!restored.isPaused && store.load()?.isPaused == false, "Selecting the same file must persist resume")
        await restored.applyVideoWallpaper(from: secondURL).value
        try require(!restored.isMuted && restored.volume == 0.5, "Changing video must retain audio preferences")
        print("PASS: quit/relaunch, same-video resume and audio preferences")

        let previousState = store.load()
        await restored.applyVideoWallpaper(from: directory.appendingPathComponent("missing.mp4")).value
        try require(restored.currentVideoURL == secondURL && store.load() == previousState && errors.count == 1, "Missing file must preserve the previous wallpaper and report an error")
        let invalidURL = directory.appendingPathComponent("corrupt.mov")
        try Data("this is not a movie".utf8).write(to: invalidURL)
        await restored.applyVideoWallpaper(from: invalidURL).value
        try require(restored.currentVideoURL == secondURL && store.load() == previousState && errors.count == 2, "Unsupported video must preserve the previous wallpaper")
        print("PASS: missing and corrupt files preserve the previous wallpaper")

        let firstLoad = restored.applyVideoWallpaper(from: firstURL)
        let secondLoad = restored.applyVideoWallpaper(from: secondURL)
        await firstLoad.value
        await secondLoad.value
        try require(restored.currentVideoURL == secondURL && !restored.isLoading, "Latest selection must win")
        let cancelledLoad = restored.applyVideoWallpaper(from: firstURL)
        restored.stop()
        await cancelledLoad.value
        try require(restored.currentVideoURL == nil && store.load() == nil && !restored.isLoading, "Removing wallpaper must cancel pending loads")
        restored.shutdown()
        try require(store.load() == nil, "Quitting after removal must not recreate saved state")
        print("PASS: concurrent selections, cancellation and explicit removal")

        let missingState = SavedState(fileURL: directory.appendingPathComponent("unplugged.mov").absoluteString, isMuted: true, isPaused: true, volume: 1)
        store.save(missingState)
        await restored.restoreIfNeeded()?.value
        try require(store.load() == missingState, "An unavailable external disk must not erase saved state")
        restored.setVolume(-4)
        try require(restored.volume == 0, "Negative volume must clamp")
        restored.setVolume(8)
        try require(restored.volume == 1, "Large volume must clamp")
        restored.setVolume(.nan)
        try require(restored.volume == 1, "Nonfinite volume must be ignored")
        restored.setPauseInLowPowerMode(false)
        let preferenceReader = WallpaperManager(defaults: defaults, observesSystemEvents: false, screenProvider: { [] })
        try require(!preferenceReader.pauseInLowPowerMode, "Low power preference must persist")
        try require(preferenceReader.usesLowMemoryPlayback, "Memory saving should default on")
        preferenceReader.setLowMemoryPlayback(false)
        let modeReader = WallpaperManager(defaults: defaults, observesSystemEvents: false, screenProvider: { [] })
        try require(!modeReader.usesLowMemoryPlayback, "Memory mode preference must persist")
        modeReader.shutdown()
        preferenceReader.setLowMemoryPlayback(true)
        preferenceReader.shutdown()
        restored.shutdown()
        print("PASS: unavailable disk, volume bounds and power preference")

        if CommandLine.arguments.contains("--display") {
            try await testDisplay(videoURL: firstURL, defaults: defaults)
        }
    }

    @MainActor static func testDisplay(videoURL: URL, defaults: UserDefaults) async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let screens = NSScreen.screens
        try require(!screens.isEmpty, "No display is available for the live smoke test")
        var simulatedScreens = screens
        let manager = WallpaperManager(defaults: defaults, screenProvider: { simulatedScreens })
        manager.setPauseInLowPowerMode(false)
        defer { manager.stop(); manager.shutdown() }
        var errors: [String] = []
        manager.onError = { errors.append($0) }
        await manager.applyVideoWallpaper(from: videoURL).value
        try require(manager.screenCount == screens.count, "Each display needs one player")
        let windows = app.windows.filter { $0.contentView?.layer is AVPlayerLayer }
        let layers = windows.compactMap { $0.contentView?.layer as? AVPlayerLayer }
        try require(layers.count == screens.count, "Every wallpaper window must have a direct video layer")
        for _ in 0..<100 {
            if layers.allSatisfy({ $0.isReadyForDisplay }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(layers.allSatisfy { $0.isReadyForDisplay }, "Video layers must decode and present frames")
        try require(layers.allSatisfy { !($0.player is AVQueuePlayer) }, "Low memory mode must use a single-item player")
        // Observe several wraps in currentTime: being readyToPlay alone does not
        // prove that the new seek-based loop actually continues at the end.
        var previousTime = layers.first?.player?.currentTime().seconds ?? 0
        var wraps = 0
        for _ in 0..<65 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let time = layers.first?.player?.currentTime().seconds ?? 0
            if previousTime - time > 0.3 { wraps += 1 }
            previousTime = time
        }
        try require(wraps >= 2, "Single-item playback must actually loop multiple times")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try require(errors.isEmpty && layers.allSatisfy { $0.player?.currentItem?.status == .readyToPlay }, "The short fixture must loop without errors")
        manager.setMuted(false)
        try require(layers.filter { $0.player?.isMuted == false }.count == 1, "Only one display may output audio")
        let windowIDs = Set(windows.map { $0.windowNumber })
        manager.pause()
        for _ in 0..<8 {
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let remaining = app.windows.filter { $0.contentView?.layer is AVPlayerLayer }
        try require(Set(remaining.map { $0.windowNumber }) == windowIDs, "Screen notification bursts must reuse windows")
        try require(manager.isPaused && layers.allSatisfy { $0.player?.rate == 0 }, "Screen notifications must preserve manual pause")
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        manager.resume()
        try require(layers.allSatisfy { $0.player?.rate == 0 }, "Resume while the screen sleeps must remain suspended")
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try require(layers.allSatisfy { ($0.player?.rate ?? 0) > 0 }, "Wake must resume a non-paused wallpaper")
        manager.pause()
        simulatedScreens = []
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(nanoseconds: 500_000_000)
        try require(manager.screenCount == 0, "Disconnected display resources must be removed")
        simulatedScreens = screens
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(nanoseconds: 500_000_000)
        try require(manager.screenCount == screens.count && manager.isPaused, "Reconnected displays must preserve pause")
        let reconnectedLayers = app.windows.compactMap { $0.contentView?.layer as? AVPlayerLayer }
        try require(reconnectedLayers.allSatisfy { $0.player?.rate == 0 }, "A recreated player must not start while paused")
        manager.setLowMemoryPlayback(false)
        var activeLayers = app.windows.compactMap { $0.contentView?.layer as? AVPlayerLayer }
        try require(activeLayers.count == screens.count && activeLayers.allSatisfy { $0.player is AVQueuePlayer && $0.player?.rate == 0 }, "Seamless mode must remain available and preserve pause")
        manager.setLowMemoryPlayback(true)
        activeLayers = app.windows.compactMap { $0.contentView?.layer as? AVPlayerLayer }
        try require(activeLayers.count == screens.count && activeLayers.allSatisfy { !($0.player is AVQueuePlayer) && $0.player?.rate == 0 }, "Mode changes must preserve pause and not leave duplicate windows")

        // No real system pressure is generated. Inject events into the same
        // handler used by DispatchSourceMemoryPressure.
        manager.handleMemoryPressure(.warning)
        try require(manager.screenCount == 0 && activeLayers.allSatisfy { $0.player == nil }, "Memory warning must immediately detach and release players")
        try require(manager.currentVideoURL == videoURL && manager.isPaused, "Memory warning must preserve selection and user pause")
        manager.setLowMemoryPlayback(false)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        try require(manager.screenCount == 0, "Mode or screen changes must not recreate players under pressure")
        manager.handleMemoryPressure(.normal)
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(manager.screenCount == 0 && manager.isPaused, "Normal memory must not override manual pause")
        manager.setLowMemoryPlayback(true)
        manager.resume()
        try await waitUntil { !manager.isLoading && manager.screenCount == screens.count }
        manager.stop()
        let pendingSelection = manager.applyVideoWallpaper(from: videoURL)
        manager.handleMemoryPressure(.warning)
        await pendingSelection.value
        try require(manager.currentVideoURL == videoURL && manager.screenCount == 0, "Pressure during a load must retain the selection without creating decoders")
        manager.handleMemoryPressure(.normal)
        try await waitUntil { !manager.isLoading && manager.screenCount == screens.count }
        manager.handleMemoryPressure(.critical)
        manager.resume()
        try require(manager.screenCount == 0 && manager.currentVideoURL == videoURL, "Resume during pressure must not allocate decoders")
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        manager.handleMemoryPressure(.normal)
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(manager.screenCount == 0, "Memory recovery while sleeping must defer decoder allocation")
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await waitUntil { !manager.isLoading && manager.screenCount == screens.count }
        manager.handleMemoryPressure(.critical)
        manager.handleMemoryPressure(.normal)
        manager.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        try require(manager.screenCount == 0 && manager.currentVideoURL == nil, "Stop must cancel pending memory recovery")

        // Every replaced player must detach its item immediately and deallocate;
        // measuring this catches retained loop callbacks and observers.
        let alternate = videoURL.deletingLastPathComponent().appendingPathComponent("alternate.mov")
        try FileManager.default.copyItem(at: videoURL, to: alternate)
        var retiredPlayers: [WeakPlayer] = []
        for index in 0..<30 {
            let oldPlayers = app.windows.compactMap { ($0.contentView?.layer as? AVPlayerLayer)?.player }
            retiredPlayers.append(contentsOf: oldPlayers.map(WeakPlayer.init))
            await manager.applyVideoWallpaper(from: index.isMultiple(of: 2) ? videoURL : alternate).value
            try require(oldPlayers.allSatisfy { $0.currentItem == nil }, "Switching must release each old player's video item immediately")
        }
        manager.stop()
        try await waitUntil { retiredPlayers.allSatisfy { $0.value == nil } }
        try require(app.windows.allSatisfy { !($0.contentView?.layer is AVPlayerLayer) }, "Stop must leave no wallpaper windows")
        try require(errors.isEmpty, "Live playback must not emit errors")
        print("PASS: single-item looping, mode switching, memory pressure recovery and 30-switch object-release stress test")
        print("PASS: actual frame rendering, looping, audio routing, screen reuse, sleep/wake and simulated disconnect/reconnect (\(screens.count) display(s))")
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(condition(), "Timed out waiting for resource lifecycle transition")
    }

    static func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TestFailure(description: "Could not start fixture writer") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw TestFailure(description: "Could not allocate fixture frame") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(40 + frame * 4), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? TestFailure(description: "Fixture writer failed") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? TestFailure(description: "Fixture frame failed")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestFailure(description: "Fixture did not complete") }
    }
}

private final class WeakPlayer {
    weak var value: AVPlayer?
    init(_ value: AVPlayer) { self.value = value }
}
