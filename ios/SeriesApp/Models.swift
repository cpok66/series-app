import Foundation
import CryptoKit

extension String {
    /// Короткое безопасное имя файла: id серии бывает длиннее лимита в 255 символов.
    var fileSafeHash: String {
        let digest = SHA256.hash(data: Data(utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }
}

struct Library: Codable {
    var shows: [Show]
    var disk: DiskInfo?
}

struct DiskInfo: Codable {
    var total: Int64
    var used: Int64
    var free: Int64
}

struct Show: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var overview: String?
    var hasPoster: Bool
    var seasons: [Season]

    var episodeCount: Int { seasons.reduce(0) { $0 + $1.episodes.count } }
    var allEpisodes: [Episode] { seasons.flatMap { $0.episodes } }
}

struct Season: Codable, Identifiable, Hashable {
    var number: Int
    var episodes: [Episode]
    var id: Int { number }
}

struct Episode: Codable, Identifiable, Hashable {
    var id: String
    var showId: String
    var showTitle: String
    var season: Int
    var episode: Int
    var title: String
    var size: Int64
    var ext: String
}

struct DownloadedEpisode: Codable, Identifiable, Hashable {
    var id: String
    var showId: String
    var showTitle: String
    var season: Int
    var episode: Int
    var title: String
    var fileName: String
    var size: Int64
    var addedAt: Date

    init(episode ep: Episode, fileName: String, size: Int64) {
        id = ep.id
        showId = ep.showId
        showTitle = ep.showTitle
        season = ep.season
        episode = ep.episode
        title = ep.title
        self.fileName = fileName
        self.size = size
        addedAt = Date()
    }

    var code: String { "S\(season)E\(episode)" }
    var label: String { title.isEmpty ? "Серия \(episode)" : title }
}

struct PlaybackState: Codable, Hashable {
    var position: Double
    var duration: Double
    var watched: Bool
    var updatedAt: Date

    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
}

struct ShowPrefs: Codable, Hashable {
    var introStart: Double = 0
    var introEnd: Double = 0

    var hasIntro: Bool { introEnd > introStart }
}

struct ShowGroup: Identifiable {
    var id: String
    var title: String
    var episodes: [DownloadedEpisode]
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func deviceFreeSpace() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        return 0
    }
}
