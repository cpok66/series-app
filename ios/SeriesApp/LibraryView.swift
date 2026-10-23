import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: LocalStore
    @State private var library: Library?
    @State private var error: String?
    @State private var loading = false
    @State private var query = ""

    private var shows: [Show] { (library ?? store.cachedLibrary)?.shows ?? [] }
    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 14)]

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredShows: [Show] {
        let q = trimmedQuery
        guard !q.isEmpty else { return shows }
        return shows.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var matchingEpisodes: [Episode] {
        let q = trimmedQuery
        guard !q.isEmpty else { return [] }
        return Array(shows.flatMap(\.allEpisodes)
            .filter { !$0.title.isEmpty && $0.title.localizedCaseInsensitiveContains(q) }
            .prefix(50))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if !settings.isConfigured {
                    ContentUnavailableView("Сервер не настроен",
                                           systemImage: "server.rack",
                                           description: Text("Укажи адрес и пароль во вкладке «Настройки»."))
                        .padding(.top, 80)
                } else if shows.isEmpty {
                    if loading {
                        ProgressView().padding(.top, 120)
                    } else {
                        ContentUnavailableView("Пока пусто",
                                               systemImage: "film.stack",
                                               description: Text(error ?? "Загрузи серии на сервер через браузер, потом потяни экран вниз."))
                            .padding(.top, 80)
                    }
                } else if !trimmedQuery.isEmpty && filteredShows.isEmpty && matchingEpisodes.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                        .padding(.top, 60)
                } else {
                    content
                }
            }
            .refreshable { await load() }
            .searchable(text: $query, prompt: "Сериал или название серии")
            .navigationTitle("Сериалы")
            .navigationDestination(for: String.self) { id in
                ShowDetailView(showId: id, library: $library, reload: { await load() })
            }
            .task(id: settings.serverURL + settings.password) {
                // Не дёргаем сервер на каждую букву, пока адрес или пароль печатаются.
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error {
                Label("Нет связи с сервером: \(error)", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if trimmedQuery.isEmpty, let disk = (library ?? store.cachedLibrary)?.disk {
                Text("На сервере свободно \(Format.bytes(disk.free)) из \(Format.bytes(disk.total))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !filteredShows.isEmpty {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(filteredShows) { show in
                        NavigationLink(value: show.id) {
                            ShowCard(show: show)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !matchingEpisodes.isEmpty {
                Text("Серии")
                    .font(.headline)
                    .padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(matchingEpisodes) { ep in
                        NavigationLink(value: ep.showId) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ep.title).lineLimit(2)
                                    Text("\(ep.showTitle) · S\(ep.season)E\(ep.episode)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.isDownloaded(ep.id) {
                                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .padding()
    }

    private func load() async {
        guard settings.isConfigured else { return }
        loading = true
        defer { loading = false }
        do {
            let lib = try await APIClient.fetchLibrary()
            library = lib
            store.cachedLibrary = lib
            store.save()
            error = nil
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            self.error = error.localizedDescription
        }
    }
}

struct ShowCard: View {
    let show: Show
    @EnvironmentObject var store: LocalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(showId: show.id)
                .overlay(alignment: .topTrailing) {
                    let count = store.downloadedEpisodes(showId: show.id).count
                    if count > 0 {
                        Label("\(count)", systemImage: "arrow.down.circle.fill")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
            Text(show.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
            Text("\(show.episodeCount) сер.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
