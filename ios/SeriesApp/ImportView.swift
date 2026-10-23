import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Видео, скопированное с телефона в приложение, ещё без названия сериала.
struct ImportedFile: Identifiable {
    let id = UUID()
    var fileName: String
    var originalName: String
    var size: Int64
    var show: String
    var season: String
    var episode: String
    var title: String
}

enum LocalImport {
    static let playableExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// Название сериала, сезон и серия из имени вроде Show.Name.S01E05.1080p.mp4
    static func parse(_ name: String) -> (show: String, season: Int?, episode: Int?) {
        let stem = (name as NSString).deletingPathExtension
        let patterns = [#"(?i)^(.*?)[\s._\-\[\(]*s(\d{1,2})[\s._\-]*e(\d{1,3})"#,
                        #"(?i)^(.*?)[\s._\-\[\(]*(\d{1,2})x(\d{1,3})(?!\d)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
                  let showRange = Range(m.range(at: 1), in: stem),
                  let sRange = Range(m.range(at: 2), in: stem),
                  let eRange = Range(m.range(at: 3), in: stem) else { continue }
            return (clean(String(stem[showRange])), Int(stem[sRange]), Int(stem[eRange]))
        }
        return (clean(stem), nil, nil)
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -[]()"))
    }

    enum ImportError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            if case .unsupported(let name) = self {
                return "«\(name)»: айфон не умеет играть этот формат. Загрузи его на сервер, там он переделается в mp4."
            }
            return nil
        }
    }

    /// Копирует выбранный файл в память приложения и проверяет, что его можно воспроизвести.
    static func copy(_ url: URL) async throws -> ImportedFile {
        let original = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard playableExtensions.contains(ext) else { throw ImportError.unsupported(original) }

        let fileName = UUID().uuidString.lowercased() + "." + ext
        let dest = LocalStore.videosDir.appendingPathComponent(fileName)
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                do { try FileManager.default.copyItem(at: readURL, to: dest) } catch { copyError = error }
            }
            if let error = coordError ?? copyError { throw error }
        }.value

        let playable = (try? await AVURLAsset(url: dest).load(.isPlayable)) ?? false
        guard playable else {
            try? FileManager.default.removeItem(at: dest)
            throw ImportError.unsupported(original)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let parsed = parse(original)
        return ImportedFile(fileName: fileName, originalName: original, size: size,
                            show: parsed.show,
                            season: parsed.season.map { String($0) } ?? "1",
                            episode: parsed.episode.map { String($0) } ?? "",
                            title: "")
    }

    /// Сохраняет скопированные файлы как скачанные серии.
    @MainActor
    static func save(_ files: [ImportedFile]) {
        let store = LocalStore.shared
        // Серии без номера нумеруем по порядку внутри своего сериала и сезона
        var nextNumber: [String: Int] = [:]
        for file in files {
            let show = file.show.trimmingCharacters(in: .whitespaces).isEmpty ? "Мои видео" : file.show.trimmingCharacters(in: .whitespaces)
            let showId = "local-" + show.lowercased().fileSafeHash
            let season = Int(file.season) ?? 1
            let key = "\(showId)-\(season)"
            let number: Int
            if let n = Int(file.episode) {
                number = n
            } else {
                let existing = store.downloadedEpisodes(showId: showId).filter { $0.season == season }.map(\.episode).max() ?? 0
                number = max(existing, nextNumber[key] ?? 0) + 1
            }
            nextNumber[key] = max(nextNumber[key] ?? 0, number)
            let ep = Episode(id: "local-" + UUID().uuidString.lowercased(), showId: showId, showTitle: show,
                             season: season, episode: number, title: file.title,
                             size: file.size, ext: (file.fileName as NSString).pathExtension)
            store.addDownloaded(DownloadedEpisode(episode: ep, fileName: file.fileName, size: file.size))
        }
    }

    static func discard(_ files: [ImportedFile]) {
        for file in files {
            try? FileManager.default.removeItem(at: LocalStore.videosDir.appendingPathComponent(file.fileName))
        }
    }
}

/// Кнопка «+» и весь процесс импорта: выбор файлов → копирование → названия.
struct ImportButton: View {
    @State private var picking = false
    @State private var copying = false
    @State private var copiedCount = 0
    @State private var totalCount = 0
    @State private var imported: [ImportedFile] = []
    @State private var errors: [String] = []
    @State private var showSheet = false
    @State private var showErrors = false

    var body: some View {
        Button {
            picking = true
        } label: {
            if copying {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("\(copiedCount)/\(totalCount)").font(.caption)
                }
            } else {
                Image(systemName: "plus")
            }
        }
        .disabled(copying)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { await copy(urls) }
        }
        .sheet(isPresented: $showSheet, onDismiss: {
            // Закрыли окно без сохранения: убираем скопированные файлы, чтобы не занимали место
            if !imported.isEmpty {
                LocalImport.discard(imported)
                imported = []
            }
        }) {
            ImportSheet(files: $imported) {
                LocalImport.save(imported)
                imported = []
                showSheet = false
            }
        }
        .alert("Не все файлы добавлены", isPresented: $showErrors) {
            Button("OK", role: .cancel) {
                if !imported.isEmpty { showSheet = true }
            }
        } message: {
            Text(errors.joined(separator: "\n\n"))
        }
    }

    private func copy(_ urls: [URL]) async {
        copying = true
        copiedCount = 0
        totalCount = urls.count
        errors = []
        var result: [ImportedFile] = []
        for url in urls {
            do {
                result.append(try await LocalImport.copy(url))
            } catch {
                errors.append(error.localizedDescription)
            }
            copiedCount += 1
        }
        copying = false
        imported = result
        if !errors.isEmpty {
            showErrors = true
        } else if !result.isEmpty {
            showSheet = true
        }
    }
}

struct ImportSheet: View {
    @Binding var files: [ImportedFile]
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var commonShow = ""

    var body: some View {
        NavigationStack {
            Form {
                if files.count > 1 {
                    Section {
                        HStack {
                            TextField("Сериал для всех файлов", text: $commonShow)
                            Button("Применить") {
                                for i in files.indices { files[i].show = commonShow }
                            }
                            .disabled(commonShow.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } footer: {
                        Text("Можно задать одно название сразу для всех файлов.")
                    }
                }
                ForEach($files) { $file in
                    Section {
                        TextField("Сериал или фильм", text: $file.show)
                        HStack {
                            Text("Сезон")
                            TextField("1", text: $file.season)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Divider()
                            Text("Серия")
                            TextField("авто", text: $file.episode)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        TextField("Название серии (необязательно)", text: $file.title)
                    } header: {
                        Text(file.originalName).textCase(nil)
                    } footer: {
                        Text(Format.bytes(file.size))
                    }
                }
            }
            .navigationTitle("Добавить видео")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { onSave() }
                        .disabled(files.isEmpty)
                }
            }
            .onAppear {
                if commonShow.isEmpty { commonShow = files.first?.show ?? "" }
            }
        }
        .interactiveDismissDisabled()
    }
}
