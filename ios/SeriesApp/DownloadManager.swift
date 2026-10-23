import Foundation
import Combine

struct ActiveDownload: Identifiable {
    var episode: Episode
    var received: Int64 = 0
    var total: Int64 = 0
    var error: String?

    var id: String { episode.id }
    var progress: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
}

/// Фоновые загрузки: продолжаются, даже если приложение свернуто.
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    @Published private(set) var active: [String: ActiveDownload] = [:]
    var backgroundCompletionHandler: (() -> Void)?

    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    private var lastUIUpdate: [String: Date] = [:]

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.cpok66.series.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session.getAllTasks { [weak self] all in
            DispatchQueue.main.async {
                guard let self else { return }
                for case let task as URLSessionDownloadTask in all {
                    guard let ep = Self.decode(task.taskDescription) else { task.cancel(); continue }
                    self.tasks[ep.id] = task
                    let expected = task.countOfBytesExpectedToReceive
                    self.active[ep.id] = ActiveDownload(episode: ep,
                                                        received: task.countOfBytesReceived,
                                                        total: expected > 0 ? expected : ep.size)
                }
            }
        }
    }

    var sortedActive: [ActiveDownload] {
        active.values.sorted {
            ($0.episode.showTitle, $0.episode.season, $0.episode.episode) <
            ($1.episode.showTitle, $1.episode.season, $1.episode.episode)
        }
    }

    // MARK: - Управление

    func download(_ ep: Episode) {
        guard !LocalStore.shared.isDownloaded(ep.id), tasks[ep.id] == nil else { return }
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: ep.id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            guard var req = try? APIClient.fileRequest(ep.id) else { return }
            req.allowsCellularAccess = !AppSettings.shared.wifiOnly
            task = session.downloadTask(with: req)
        }
        task.taskDescription = Self.encode(ep)
        tasks[ep.id] = task
        active[ep.id] = ActiveDownload(episode: ep, total: ep.size)
        task.resume()
    }

    func download(_ episodes: [Episode]) {
        episodes.forEach { download($0) }
    }

    func retry(_ id: String) {
        guard let ep = active[id]?.episode else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
        active[id] = nil
        download(ep)
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        active[id] = nil
        resumeData[id] = nil
        lastUIUpdate[id] = nil
    }

    private func fail(_ id: String, _ message: String) {
        tasks[id] = nil
        lastUIUpdate[id] = nil
        guard var d = active[id] else { return }
        d.error = message
        active[id] = d
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let ep = Self.decode(downloadTask.taskDescription) else { return }
        DispatchQueue.main.async {
            let now = Date()
            if let last = self.lastUIUpdate[ep.id], now.timeIntervalSince(last) < 0.3 { return }
            self.lastUIUpdate[ep.id] = now
            guard var d = self.active[ep.id], d.error == nil else { return }
            d.received = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { d.total = totalBytesExpectedToWrite }
            self.active[ep.id] = d
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let ep = Self.decode(downloadTask.taskDescription) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            DispatchQueue.main.async {
                self.fail(ep.id, status == 401 ? "Неверный пароль" : "Ошибка сервера (\(status))")
            }
            return
        }
        let fileName = ep.id.fileSafeHash + "." + (ep.ext.isEmpty ? "mp4" : ep.ext)
        let dest = LocalStore.videosDir.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            DispatchQueue.main.async { self.fail(ep.id, "Не удалось сохранить файл") }
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? ep.size
        DispatchQueue.main.async {
            LocalStore.shared.addDownloaded(DownloadedEpisode(episode: ep, fileName: fileName, size: size))
            self.active[ep.id] = nil
            self.tasks[ep.id] = nil
            self.lastUIUpdate[ep.id] = nil
            self.resumeData[ep.id] = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let ep = Self.decode(task.taskDescription) else { return }
        let ns = error as NSError
        let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled && data == nil { return }
        DispatchQueue.main.async {
            guard self.active[ep.id] != nil else { return }
            if let data { self.resumeData[ep.id] = data }
            self.fail(ep.id, error.localizedDescription)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    // MARK: - Метаданные задачи

    static func encode(_ ep: Episode) -> String? {
        guard let data = try? JSONEncoder().encode(ep) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ s: String?) -> Episode? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Episode.self, from: data)
    }
}
