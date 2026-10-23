import SwiftUI
import UIKit

/// Картинки с сервера (постеры, обложки архива) кешируются на диске, чтобы были видны и без интернета.
actor ImageCache {
    static let shared = ImageCache()

    private var memory: [String: UIImage] = [:]
    private var failedAt: [String: Date] = [:]
    private let dir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func image(path: String) async -> UIImage? {
        let key = path.fileSafeHash
        if let img = memory[key] { return img }
        let file = dir.appendingPathComponent(key + ".img")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory[key] = img
            return img
        }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 60 { return nil }
        guard let req = try? APIClient.request(path) else { return nil }
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: result.0) else {
            failedAt[key] = Date()
            return nil
        }
        try? result.0.write(to: file)
        memory[key] = img
        return img
    }
}

struct RemoteImage: View {
    let path: String
    var placeholder: String = "film"
    var aspect: CGFloat = 2.0 / 3.0
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.16)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: placeholder)
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: path) {
                image = await ImageCache.shared.image(path: path)
            }
    }
}

struct PosterImage: View {
    let showId: String

    var body: some View {
        RemoteImage(path: "/api/poster/\(showId)")
    }
}
