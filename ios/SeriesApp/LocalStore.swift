import Foundation
import Combine

/// Всё, что хранится на телефоне: скачанные серии, прогресс просмотра, настройки заставок.
/// Вызывать только с главного потока.
final class LocalStore: ObservableObject {
    static let shared = LocalStore()

    @Published private(set) var downloaded: [String: DownloadedEpisode] = [:]
    @Published private(set) var playback: [String: PlaybackState] = [:]
    @Published private(set) var showPrefs: [String: ShowPrefs] = [:]
    @Published var cachedLibrary: Library?
    @Published private(set) var pendingServerDeletes: [String] = []

    private struct State: Codable {
        var downloaded: [String: DownloadedEpisode] = [:]
        var playback: [String: PlaybackState] = [:]
        var showPrefs: [String: ShowPrefs] = [:]
        var cachedLibrary: Library?
        var pendingServerDeletes: [String]?
    }

    static let videosDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var dir = docs.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    private let stateURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    private var pendingSave: DispatchWorkItem?

    private init() {
        load()
        removeMissingFiles()
    }

    // MARK: - Сохранение

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        downloaded = state.downloaded
        playback = state.playback
        showPrefs = state.showPrefs
        cachedLibrary = state.cachedLibrary
        pendingServerDeletes = state.pendingServerDeletes ?? []
    }

    func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let state = State(downloaded: downloaded, playback: playback, showPrefs: showPrefs,
                          cachedLibrary: cachedLibrary, pendingServerDeletes: pendingServerDeletes)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func removeMissingFiles() {
        var changed = false
        for (id, ep) in downloaded where !FileManager.default.fileExists(atPath: fileURL(for: ep).path) {
            downloaded[id] = nil
            changed = true
        }
        if changed { save() }

        // Файлы, о которых ничего не известно (обрыв посреди сохранения), только зря занимают место.
        let known = Set(downloaded.values.map(\.fileName))
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.videosDir,
                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where !known.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > 600 {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - Скачанные серии

    func fileURL(for ep: DownloadedEpisode) -> URL {
        Self.videosDir.appendingPathComponent(ep.fileName)
    }

    func isDownloaded(_ id: String) -> Bool { downloaded[id] != nil }

    func addDownloaded(_ ep: DownloadedEpisode) {
        downloaded[ep.id] = ep
        // Сразу на диск: загрузка могла закончиться в фоне, и система вот-вот усыпит приложение.
        saveNow()
    }

    func removeDownloaded(_ id: String) {
        guard let ep = downloaded[id] else { return }
        try? FileManager.default.removeItem(at: fileURL(for: ep))
        downloaded[id] = nil
        save()
    }

    @discardableResult
    func removeWatched() -> Int {
        let ids = downloaded.keys.filter { playback[$0]?.watched == true }
        ids.forEach(removeDownloaded)
        return ids.count
    }

    var totalDownloadedSize: Int64 { downloaded.values.reduce(0) { $0 + $1.size } }

    func downloadedEpisodes(showId: String) -> [DownloadedEpisode] {
        downloaded.values
            .filter { $0.showId == showId }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    var downloadedShows: [ShowGroup] {
        let groups = Dictionary(grouping: downloaded.values, by: { $0.showId })
        return groups.map { id, eps in
            ShowGroup(id: id,
                      title: eps.first?.showTitle ?? "",
                      episodes: eps.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) })
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Прогресс просмотра

    func updateProgress(id: String, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        let watchedNow = position / duration >= 0.9
        let wasWatched = playback[id]?.watched ?? false
        playback[id] = PlaybackState(position: position, duration: duration,
                                     watched: wasWatched || watchedNow, updatedAt: Date())
        save()
    }

    func setWatched(_ id: String, _ watched: Bool) {
        var st = playback[id] ?? PlaybackState(position: 0, duration: 0, watched: false, updatedAt: Date())
        st.watched = watched
        if !watched { st.position = 0 }
        st.updatedAt = Date()
        playback[id] = st
        save()
    }

    // MARK: - Удаление с сервера

    /// Просмотренные серии из кеша библиотеки, которые ещё лежат на сервере.
    func watchedOnServer(showId: String? = nil) -> [Episode] {
        let all = cachedLibrary?.shows.filter { showId == nil || $0.id == showId }.flatMap(\.allEpisodes) ?? []
        return all.filter { playback[$0.id]?.watched == true }
    }

    func queueServerDelete(_ ids: [String]) {
        let new = ids.filter { !pendingServerDeletes.contains($0) }
        guard !new.isEmpty else { return }
        pendingServerDeletes += new
        saveNow()
    }

    func serverDeleteDone(_ id: String) {
        pendingServerDeletes.removeAll { $0 == id }
        if var lib = cachedLibrary {
            for i in lib.shows.indices {
                for j in lib.shows[i].seasons.indices {
                    lib.shows[i].seasons[j].episodes.removeAll { $0.id == id }
                }
                lib.shows[i].seasons.removeAll { $0.episodes.isEmpty }
            }
            lib.shows.removeAll { $0.seasons.isEmpty }
            cachedLibrary = lib
        }
        save()
    }

    // MARK: - Заставки

    func prefs(showId: String) -> ShowPrefs { showPrefs[showId] ?? ShowPrefs() }

    func setPrefs(_ prefs: ShowPrefs, showId: String) {
        showPrefs[showId] = prefs
        save()
    }
}
