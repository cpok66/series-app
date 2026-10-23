import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    @Published var password: String { didSet { defaults.set(password, forKey: "password") } }
    @Published var autoNext: Bool { didSet { defaults.set(autoNext, forKey: "autoNext") } }
    @Published var deleteWatched: Bool { didSet { defaults.set(deleteWatched, forKey: "deleteWatched") } }

    private init() {
        serverURL = defaults.string(forKey: "serverURL") ?? ""
        password = defaults.string(forKey: "password") ?? ""
        autoNext = defaults.object(forKey: "autoNext") as? Bool ?? true
        deleteWatched = defaults.object(forKey: "deleteWatched") as? Bool ?? false
    }

    var isConfigured: Bool { baseURL != nil && !password.isEmpty }

    var baseURL: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}

enum APIError: LocalizedError {
    case notConfigured
    case unauthorized
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Сервер не настроен"
        case .unauthorized: return "Неверный пароль"
        case .server(let code): return "Ошибка сервера (\(code))"
        }
    }
}

enum APIClient {
    static func request(_ path: String, method: String = "GET", timeout: TimeInterval = 20) throws -> URLRequest {
        let settings = AppSettings.shared
        guard let base = settings.baseURL, let url = URL(string: base.absoluteString + path) else {
            throw APIError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer \(settings.password)", forHTTPHeaderField: "Authorization")
        return req
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if !(200..<300).contains(http.statusCode) { throw APIError.server(http.statusCode) }
    }

    static func ping() async throws {
        let (_, response) = try await URLSession.shared.data(for: request("/api/ping", timeout: 10))
        try check(response)
    }

    static func fetchLibrary() async throws -> Library {
        let (data, response) = try await URLSession.shared.data(for: request("/api/library"))
        try check(response)
        return try JSONDecoder().decode(Library.self, from: data)
    }

    static func deleteOnServer(_ episodeId: String) async throws {
        let (_, response) = try await URLSession.shared.data(for: request("/api/file/\(episodeId)", method: "DELETE"))
        try check(response)
    }

    static func fileRequest(_ episodeId: String) throws -> URLRequest {
        try request("/api/file/\(episodeId)", timeout: 120)
    }
}
