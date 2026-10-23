import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var store: LocalStore
    @EnvironmentObject var downloads: DownloadManager
    @State private var confirmDeleteWatched = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Скачано", value: Format.bytes(store.totalDownloadedSize))
                    LabeledContent("Свободно на телефоне", value: Format.bytes(Format.deviceFreeSpace()))
                }

                if !downloads.active.isEmpty {
                    Section("Загружается") {
                        ForEach(downloads.sortedActive) { d in
                            ActiveDownloadRow(download: d)
                        }
                    }
                }

                ForEach(store.downloadedShows) { group in
                    Section(group.title) {
                        ForEach(group.episodes) { ep in
                            Button {
                                PlayerLauncher.play(group.episodes, startAt: ep.id)
                            } label: {
                                DownloadedRow(episode: ep)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.removeDownloaded(ep.id)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
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
                    }
                }

                if store.downloaded.isEmpty && downloads.active.isEmpty {
                    Section {
                        Text("Здесь будут серии, которые ты скачаешь. Их можно смотреть без интернета.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Скачано")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            confirmDeleteWatched = true
                        } label: {
                            Label("Удалить просмотренные", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Удалить все просмотренные серии с телефона?",
                                isPresented: $confirmDeleteWatched,
                                titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { store.removeWatched() }
            }
        }
    }
}

struct DownloadedRow: View {
    let episode: DownloadedEpisode
    @EnvironmentObject var store: LocalStore

    var body: some View {
        HStack(spacing: 12) {
            let st = store.playback[episode.id]
            Image(systemName: st?.watched == true ? "checkmark.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(st?.watched == true ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(episode.code) · \(episode.label)").lineLimit(2)
                Text(Format.bytes(episode.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let st, !st.watched, st.position > 10 {
                    ProgressView(value: st.fraction).tint(.orange)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

struct ActiveDownloadRow: View {
    let download: ActiveDownload
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(download.episode.showTitle) · S\(download.episode.season)E\(download.episode.episode)")
                    .lineLimit(1)
                if let err = download.error {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    ProgressView(value: download.progress).tint(.orange)
                    Text("\(Format.bytes(download.received)) из \(Format.bytes(download.total))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if download.error != nil {
                Button { downloads.retry(download.id) } label: {
                    Image(systemName: "arrow.clockwise.circle").font(.title2)
                }
                .buttonStyle(.borderless)
            }
            Button(role: .destructive) { downloads.cancel(download.id) } label: {
                Image(systemName: "xmark.circle").font(.title2)
            }
            .buttonStyle(.borderless)
        }
    }
}
