import Foundation
import Combine

struct ArchiveItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var year: String?
    var description: String?
    var downloads: Int?
}

struct ArchiveSearchResult: Codable {
    var items: [ArchiveItem]
    var total: Int
}

struct ArchiveFile: Codable, Identifiable, Hashable {
    var name: String
    var format: String
    var size: Int64
    var length: Double?
    var id: String { name }
}

struct ArchiveDetails: Codable {
    var id: String
    var title: String
    var description: String?
    var year: String?
    var files: [ArchiveFile]
}

struct ArchiveJob: Codable, Identifiable, Hashable {
    var id: String
    var identifier: String
    var title: String
    var file: String
    var episode: Int
    var received: Int64
    var total: Int64
    var state: String
    var error: String?

    var progress: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    var isActive: Bool { state == "queued" || state == "downloading" }
}

private struct ArchiveDownloadRequest: Encodable {
    var identifier: String
    var title: String
    var files: [String]
    var sizes: [Int64]
    var description: String
}

private struct JobsResponse: Decodable { var jobs: [ArchiveJob] }

extension Notification.Name {
    static let libraryChanged = Notification.Name("libraryChanged")
}

enum ArchiveAPI {
    private static func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: APIClient.request(path, timeout: 30))
        try check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Сервер присылает понятный текст ошибки в поле detail, показываем его.
    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = obj["detail"] as? String {
            throw NSError(domain: "Server", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        throw APIError.server(http.statusCode)
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func search(_ query: String) async throws -> ArchiveSearchResult {
        try await get("/api/archive/search?q=\(encode(query))", as: ArchiveSearchResult.self)
    }

    static func details(_ id: String) async throws -> ArchiveDetails {
        try await get("/api/archive/item/\(id)", as: ArchiveDetails.self)
    }

    static func jobs() async throws -> [ArchiveJob] {
        try await get("/api/archive/jobs", as: JobsResponse.self).jobs
    }

    static func download(item: ArchiveDetails, title: String, files: [ArchiveFile]) async throws {
        var req = try APIClient.request("/api/archive/download", method: "POST", timeout: 30)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ArchiveDownloadRequest(
            identifier: item.id, title: title, files: files.map(\.name),
            sizes: files.map(\.size), description: item.description ?? ""))
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
    }

    static func cancel(_ jobId: String) async throws {
        let (data, response) = try await URLSession.shared.data(for: APIClient.request("/api/archive/jobs/\(jobId)", method: "DELETE"))
        try check(response, data)
    }
}

/// Следит за загрузками с архива на сервер, пока открыта вкладка.
final class ArchiveJobs: ObservableObject {
    static let shared = ArchiveJobs()
    @Published private(set) var jobs: [ArchiveJob] = []
    private var finished = Set<String>()

    func refresh() async {
        guard AppSettings.shared.isConfigured, let new = try? await ArchiveAPI.jobs() else { return }
        await MainActor.run {
            let justDone = new.filter { $0.state == "done" && !finished.contains($0.id) }
            justDone.forEach { finished.insert($0.id) }
            jobs = new
            if !justDone.isEmpty {
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
            }
        }
    }

    func cancel(_ job: ArchiveJob) {
        Task {
            try? await ArchiveAPI.cancel(job.id)
            await refresh()
        }
    }
}
