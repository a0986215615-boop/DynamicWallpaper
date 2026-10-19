import Foundation

/// User intent is separate from temporary system suspensions. Screen changes
/// must never turn a user's paused wallpaper back on.
struct PlaybackPolicy {
    enum Suspension: Hashable {
        case screenSleep, systemSleep, inactiveSession, lowPower, memoryPressure
    }

    var isPaused = false
    var suspensions: Set<Suspension> = []
    var shouldPlay: Bool { !isPaused && suspensions.isEmpty }
}

struct SavedState: Codable, Equatable {
    let fileURL: String
    let isMuted: Bool
    let isPaused: Bool
    let volume: Double
}

struct WallpaperStateStore {
    static let key = "dw_video_wallpaper_state"
    let defaults: UserDefaults

    func load() -> SavedState? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    func save(_ state: SavedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func remove() { defaults.removeObject(forKey: Self.key) }
}
