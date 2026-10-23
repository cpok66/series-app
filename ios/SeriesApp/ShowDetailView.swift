import SwiftUI

struct ShowDetailView: View {
    let showId: String
    @Binding var library: Library?
    var reload: () async -> Void

    @EnvironmentObject var store: LocalStore
    @EnvironmentObject var downloads: DownloadManager
    @State private var seasonNumber: Int?
    @State private var showIntroSettings = false
    @State private var toDeleteOnServer: Episode?
    @State private var errorText: String?
    @State private var confirmDeleteWatched = false
    @State private var confirmDeleteShow = false
    @Environment(\.dismiss) private var dismiss

    private var show: Show? {
        (library ?? store.cachedLibrary)?.shows.first { $0.id == showId }
    }

    private var season: Season? {
        guard let show else { return nil }
        return show.seasons.first { $0.number == seasonNumber } ?? show.seasons.first
    }

    var body: some View {
        Group {
            if let show {
                List {
                    header(show)
                    if show.seasons.count > 1 {
                        Picker("Сезон", selection: Binding(
                            get: { season?.number ?? 1 },
                            set: { seasonNumber = $0 })) {
                            ForEach(show.seasons) { s in
                                Text("Сезон \(s.number)").tag(s.number)
                            }
                        }
                    }
                    if let season {
                        Section {
                            ForEach(season.episodes) { ep in
                                EpisodeRow(episode: ep) { play(ep) }
                                    .swipeActions(edge: .trailing) {
                                        if store.isDownloaded(ep.id) {
                                            Button(role: .destructive) {
                                                store.removeDownloaded(ep.id)
                                            } label: {
                                                Label("С телефона", systemImage: "iphone.slash")
                                            }
                                        }
                                        Button {
                                            toDeleteOnServer = ep
                                        } label: {
                                            Label("С сервера", systemImage: "server.rack")
                                        }
                                        .tint(.orange)
                                    }
                                    .swipeActions(edge: .leading) {
                                        let watched = store.playback[ep.id]?.watched == true
                                        Button {
                                            store.setWatched(ep.id, !watched)
                                        } label: {
                                            Label(watched ? "Не смотрел" : "Просмотрено",
                                                  systemImage: watched ? "eye.slash" : "eye")
                                        }
                                        .tint(.blue)
                                    }
                            }
                        } header: {
                            HStack {
                                Text("Серии")
                                Spacer()
                                let missing = season.episodes.filter {
                                    !store.isDownloaded($0.id) && downloads.active[$0.id] == nil
                                }
                                if !missing.isEmpty {
                                    Button("Скачать сезон") { downloads.download(missing) }
                                        .font(.caption.weight(.semibold))
                                        .textCase(nil)
                                }
                            }
                        }
                    }
                }
                .navigationTitle(show.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showIntroSettings = true } label: {
                                Label("Заставка", systemImage: "forward.end.alt")
                            }
                            let watched = store.watchedOnServer(showId: show.id)
                            Section("Сервер") {
                                Button(role: .destructive) { confirmDeleteWatched = true } label: {
                                    Label("Удалить просмотренные (\(watched.count))", systemImage: "eye.slash")
                                }
                                .disabled(watched.isEmpty)
                                Button(role: .destructive) { confirmDeleteShow = true } label: {
                                    Label("Удалить сериал целиком", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showIntroSettings) {
                    IntroSettingsView(showId: show.id, showTitle: show.title)
                }
            } else {
                ContentUnavailableView("Сериал удалён", systemImage: "film")
            }
        }
        .refreshable { await reload() }
        .confirmationDialog("Удалить просмотренные серии с сервера?", isPresented: $confirmDeleteWatched,
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                let ids = store.watchedOnServer(showId: showId).map(\.id)
                Task {
                    await ServerCleanup.delete(ids)
                    await reload()
                }
            }
        } message: {
            Text("На телефоне скачанные серии останутся.")
        }
        .confirmationDialog("Удалить весь сериал с сервера?", isPresented: $confirmDeleteShow,
                            titleVisibility: .visible) {
            Button("Удалить сериал", role: .destructive) {
                Task {
                    do {
                        try await APIClient.deleteShow(showId)
                        await reload()
                        dismiss()
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Все серии будут удалены с сервера. На телефоне скачанные серии останутся.")
        }
        .alert("Удалить с сервера?", isPresented: Binding(
            get: { toDeleteOnServer != nil },
            set: { if !$0 { toDeleteOnServer = nil } }),
               presenting: toDeleteOnServer) { ep in
            Button("Удалить", role: .destructive) {
                Task {
                    do {
                        try await APIClient.deleteOnServer(ep.id)
                        await reload()
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { ep in
            Text("Серия S\(ep.season)E\(ep.episode) будет удалена с сервера. Если она скачана на телефон, там она останется.")
        }
        .alert("Ошибка", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private func header(_ show: Show) -> some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                PosterImage(showId: show.id)
                    .frame(width: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(show.title).font(.title3.bold())
                    Text("\(show.seasons.count) сез. · \(show.episodeCount) сер.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let overview = show.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(7)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func play(_ ep: Episode) {
        PlayerLauncher.play(store.downloadedEpisodes(showId: showId), startAt: ep.id)
    }
}

struct EpisodeRow: View {
    let episode: Episode
    var onPlay: () -> Void
    @EnvironmentObject var store: LocalStore
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title.isEmpty ? "Серия \(episode.episode)" : "\(episode.episode). \(episode.title)")
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(Format.bytes(episode.size))
                    if let st = store.playback[episode.id] {
                        if st.watched {
                            Label("просмотрено", systemImage: "checkmark")
                        } else if st.position > 10 {
                            Text("· \(Int(st.fraction * 100))%")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let d = downloads.active[episode.id] {
                    if let err = d.error {
                        Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    } else {
                        ProgressView(value: d.progress)
                            .tint(.orange)
                        Text("\(Format.bytes(d.received)) из \(Format.bytes(d.total))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            status
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if store.isDownloaded(episode.id) { onPlay() }
        }
    }

    @ViewBuilder
    private var status: some View {
        if store.isDownloaded(episode.id) {
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill").font(.title)
            }
            .buttonStyle(.borderless)
            .tint(.orange)
        } else if let d = downloads.active[episode.id] {
            if d.error != nil {
                Button { downloads.retry(episode.id) } label: {
                    Image(systemName: "arrow.clockwise.circle").font(.title)
                }
                .buttonStyle(.borderless)
                .tint(.red)
            } else {
                Button { downloads.cancel(episode.id) } label: {
                    ProgressRing(progress: d.progress)
                }
                .buttonStyle(.borderless)
            }
        } else {
            Button { downloads.download(episode) } label: {
                Image(systemName: "arrow.down.circle").font(.title)
            }
            .buttonStyle(.borderless)
            .tint(.orange)
        }
    }
}

struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "stop.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
        }
        .frame(width: 28, height: 28)
        .animation(.linear(duration: 0.3), value: progress)
    }
}

struct IntroSettingsView: View {
    let showId: String
    let showTitle: String
    @EnvironmentObject var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    @State private var start: Double = 0
    @State private var end: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Начало: \(Format.time(start))", value: $start, in: 0...1800, step: 5)
                    Stepper("Конец: \(Format.time(end))", value: $end, in: 0...1800, step: 5)
                } footer: {
                    Text("Пока идёт этот отрезок, в плеере будет кнопка «Пропустить заставку». Удобнее отметить заставку прямо в плеере через меню «⋯». Поставь 0:00 и 0:00, чтобы выключить.")
                }
                Section {
                    Button("Сбросить", role: .destructive) { start = 0; end = 0 }
                }
            }
            .navigationTitle("Заставка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        store.setPrefs(ShowPrefs(introStart: start, introEnd: end), showId: showId)
                        dismiss()
                    }
                }
            }
            .onAppear {
                let p = store.prefs(showId: showId)
                start = p.introStart
                end = p.introEnd
            }
        }
        .presentationDetents([.medium])
    }
}
