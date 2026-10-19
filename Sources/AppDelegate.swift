import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let manager = WallpaperManager.shared
    private var playPauseItem: NSMenuItem!
    private var muteItem: NSMenuItem!
    private var removeItem: NSMenuItem!
    private var currentFileItem: NSMenuItem!
    private var statusTextItem: NSMenuItem!
    private var revealItem: NSMenuItem!
    private var lowPowerItem: NSMenuItem!
    private var lowMemoryItem: NSMenuItem!
    private var volumeItem: NSMenuItem!
    private var volumeOptions: [NSMenuItem] = []
    private var openPanel: NSOpenPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        manager.onStateChange = { [weak self] in self?.refreshMenuState() }
        manager.onError = { [weak self] message in self?.showError(message) }
        manager.restoreIfNeeded()
        refreshMenuState()
    }

    func applicationWillTerminate(_ notification: Notification) { manager.shutdown() }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        currentFileItem = NSMenuItem(title: "未設定桌布", action: nil, keyEquivalent: "")
        currentFileItem.isEnabled = false
        menu.addItem(currentFileItem)
        statusTextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusTextItem.isEnabled = false
        menu.addItem(statusTextItem)
        menu.addItem(.separator())
        menu.addItem(item("選擇影片…", #selector(chooseVideo), "o", "film"))
        revealItem = item("在 Finder 中顯示", #selector(revealVideo), "", "folder")
        menu.addItem(revealItem)
        menu.addItem(.separator())
        playPauseItem = item("暫停", #selector(togglePlayPause), "p", "pause.fill")
        muteItem = item("取消靜音", #selector(toggleMute), "m", "speaker.wave.2")
        menu.addItem(playPauseItem)
        menu.addItem(muteItem)
        volumeItem = NSMenuItem(title: "音量", action: nil, keyEquivalent: "")
        let volumeMenu = NSMenu()
        volumeMenu.autoenablesItems = false
        for percent in [25, 50, 75, 100] {
            let option = item("\(percent)%", #selector(changeVolume(_:)), "", nil)
            option.tag = percent
            volumeOptions.append(option)
            volumeMenu.addItem(option)
        }
        volumeItem.submenu = volumeMenu
        menu.addItem(volumeItem)
        menu.addItem(.separator())
        lowPowerItem = item("低耗電模式時暫停", #selector(toggleLowPower), "", nil)
        menu.addItem(lowPowerItem)
        lowMemoryItem = item("省記憶體模式", #selector(toggleLowMemory), "", nil)
        lowMemoryItem.toolTip = "減少循環預載；循環接點可能略有停頓。取消勾選可恢復無縫循環。"
        menu.addItem(lowMemoryItem)
        menu.addItem(.separator())
        removeItem = item("移除桌布", #selector(removeWallpaper), "", "xmark.circle")
        menu.addItem(removeItem)
        menu.addItem(item("結束動態桌布", #selector(quitApp), "q", nil))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ symbol: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func chooseVideo() {
        if let openPanel {
            NSApp.activate(ignoringOtherApps: true)
            openPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        openPanel = panel
        panel.title = "選擇桌布影片"
        panel.message = "建議使用 MP4、MOV 或 M4V；實際支援依影片編碼而定。"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.directoryURL = manager.currentVideoURL?.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.openPanel = nil
            guard response == .OK, let url = panel.url else { return }
            self.manager.applyVideoWallpaper(from: url)
        }
    }

    @objc private func togglePlayPause() {
        if manager.isPaused { manager.resume() } else { manager.pause() }
    }

    @objc private func toggleMute() { manager.setMuted(!manager.isMuted) }
    @objc private func toggleLowPower() { manager.setPauseInLowPowerMode(!manager.pauseInLowPowerMode) }
    @objc private func toggleLowMemory() { manager.setLowMemoryPlayback(!manager.usesLowMemoryPlayback) }
    @objc private func changeVolume(_ sender: NSMenuItem) { manager.setVolume(Double(sender.tag) / 100) }
    @objc private func removeWallpaper() { manager.stop() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func revealVideo() {
        guard let url = manager.currentVideoURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "無法播放影片"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func refreshMenuState() {
        let hasWallpaper = manager.currentVideoURL != nil
        let fileName = manager.currentVideoURL?.lastPathComponent
        currentFileItem.title = fileName.map { name in
            name.count > 52 ? String(name.prefix(49)) + "…" : name
        } ?? "未設定桌布"
        currentFileItem.toolTip = manager.currentVideoURL?.path
        statusTextItem.title = manager.statusText
        playPauseItem.isEnabled = hasWallpaper && !manager.isLoading
        playPauseItem.title = manager.isPaused ? "播放" : "暫停"
        playPauseItem.image = NSImage(systemSymbolName: manager.isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        muteItem.isEnabled = hasWallpaper && !manager.isLoading
        muteItem.title = manager.isMuted ? "取消靜音" : "靜音"
        muteItem.image = NSImage(systemSymbolName: manager.isMuted ? "speaker.wave.2" : "speaker.slash", accessibilityDescription: nil)
        volumeItem.isEnabled = hasWallpaper && !manager.isLoading
        for item in volumeOptions { item.state = abs(Double(item.tag) / 100 - manager.volume) < 0.001 ? .on : .off }
        lowPowerItem.state = manager.pauseInLowPowerMode ? .on : .off
        lowMemoryItem.state = manager.usesLowMemoryPlayback ? .on : .off
        lowMemoryItem.isEnabled = !manager.isLoading
        removeItem.isEnabled = hasWallpaper || manager.isLoading
        revealItem.isEnabled = hasWallpaper
        let symbol = hasWallpaper && !manager.policy.shouldPlay ? "pause.rectangle" : "play.rectangle.fill"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "動態桌布") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "DW"
        }
        statusItem.button?.toolTip = "動態桌布 1.2\n\(manager.statusText)"
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenuState() }
}
