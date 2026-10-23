import SwiftUI
import UIKit

/// Постеры кешируются на диске, чтобы были видны и без интернета.
actor PosterCache {
    static let shared = PosterCache()

    private var memory: [String: UIImage] = [:]
    private var failedAt: [String: Date] = [:]
    private let dir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func image(for showId: String) async -> UIImage? {
        if let img = memory[showId] { return img }
        let file = dir.appendingPathComponent(showId.fileSafeHash + ".jpg")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory[showId] = img
            return img
        }
        if let failed = failedAt[showId], Date().timeIntervalSince(failed) < 60 { return nil }
        guard let req = try? APIClient.request("/api/poster/\(showId)") else { return nil }
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: result.0) else {
            failedAt[showId] = Date()
            return nil
        }
        try? result.0.write(to: file)
        memory[showId] = img
        return img
    }
}

struct PosterImage: View {
    let showId: String
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.16)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: showId) {
                image = await PosterCache.shared.image(for: showId)
            }
    }
}
