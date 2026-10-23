import SwiftUI

struct ArchiveView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var jobs = ArchiveJobs.shared
    @State private var query = ""
    @State private var results: [ArchiveItem] = []
    @State private var total = 0
    @State private var searching = false
    @State private var searched = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if !jobs.jobs.isEmpty {
                    Section("Загрузка на сервер") {
                        ForEach(jobs.jobs) { job in
                            ArchiveJobRow(job: job) { jobs.cancel(job) }
                        }
                    }
                }

                if !settings.isConfigured {
                    Section {
                        Text("Сначала укажи адрес сервера во вкладке «Настройки».")
                            .foregroundStyle(.secondary)
                    }
                } else if searching {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } else if results.isEmpty {
                    Section {
                        if searched {
                            Text("Ничего не нашлось. Попробуй по-английски: в архиве почти всё подписано на английском.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Internet Archive", systemImage: "building.columns")
                                    .font(.headline)
                                Text("Фильмы, мультфильмы и телешоу, которые разрешено свободно смотреть и скачивать: в основном старое и классическое кино. Выбранное сначала скачивается на твой сервер, потом появляется во вкладке «Сериалы», откуда его можно скачать на телефон.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Попробуй: Chaplin, Nosferatu, Buster Keaton, Night of the Living Dead.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else {
                    Section {
                        ForEach(results) { item in
                            NavigationLink(value: item) {
                                ArchiveRow(item: item)
                            }
                        }
                    } header: {
                        Text("Найдено: \(total)")
                    }
                }
            }
            .navigationTitle("Архив")
            .searchable(text: $query, prompt: "Название фильма или передачи")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationDestination(for: ArchiveItem.self) { item in
                ArchiveDetailView(item: item)
            }
            .refreshable { await jobs.refresh() }
            .task {
                while !Task.isCancelled {
                    await jobs.refresh()
                    let active = jobs.jobs.contains { $0.isActive }
                    try? await Task.sleep(nanoseconds: active ? 2_000_000_000 : 10_000_000_000)
                }
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        error = nil
        defer { searching = false; searched = true }
        do {
            let r = try await ArchiveAPI.search(q)
            results = r.items
            total = r.total
        } catch {
            results = []
            self.error = error.localizedDescription
        }
    }
}

struct ArchiveRow: View {
    let item: ArchiveItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(path: "/api/archive/thumb/\(item.id)", aspect: 1)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let year = item.year {
                    Text(year).font(.caption).foregroundStyle(.secondary)
                }
                if let d = item.description {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ArchiveJobRow: View {
    let job: ArchiveJob
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(job.title) · \(job.episode)")
                    .lineLimit(1)
                switch job.state {
                case "queued":
                    Text("В очереди").font(.caption).foregroundStyle(.secondary)
                case "downloading":
                    ProgressView(value: job.progress).tint(.orange)
                    Text("\(Format.bytes(job.received)) из \(Format.bytes(job.total))")
                        .font(.caption2).foregroundStyle(.secondary)
                case "done":
                    Label("Готово, есть во вкладке «Сериалы»", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case "cancelled":
                    Text("Отменено").font(.caption).foregroundStyle(.secondary)
                default:
                    Text(job.error ?? "Ошибка").font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: job.isActive ? "xmark.circle" : "trash").font(.title3)
            }
            .buttonStyle(.borderless)
            .tint(.secondary)
        }
    }
}

struct ArchiveDetailView: View {
    let item: ArchiveItem
    @State private var details: ArchiveDetails?
    @State private var error: String?
    @State private var selected = Set<String>()
    @State private var title = ""
    @State private var sending = false
    @State private var sentMessage: String?

    private var selectedFiles: [ArchiveFile] {
        (details?.files ?? []).filter { selected.contains($0.name) }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    RemoteImage(path: "/api/archive/thumb/\(item.id)", aspect: 1)
                        .frame(width: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(details?.title ?? item.title).font(.title3.bold())
                        if let year = details?.year ?? item.year {
                            Text(year).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let d = details?.description ?? item.description {
                    Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(10)
                }
            }

            if let details {
                if details.files.isEmpty {
                    Section {
                        Text("Здесь нет видео в формате, который понимает айфон (mp4, m4v, mov).")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField("Название", text: $title)
                    } header: {
                        Text("Как назвать в библиотеке")
                    }

                    Section {
                        ForEach(details.files) { file in
                            Button {
                                if selected.contains(file.name) { selected.remove(file.name) } else { selected.insert(file.name) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected.contains(file.name) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(file.name) ? Color.orange : Color.secondary)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name).lineLimit(2)
                                        Text(fileInfo(file)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Файлы")
                    } footer: {
                        Text(details.files.count > 1
                             ? "Часто один и тот же фильм лежит в нескольких качествах: бери самый большой файл. Если выбрать несколько разных файлов, они станут сериями по порядку."
                             : "")
                    }

                    Section {
                        Button {
                            Task { await send(details) }
                        } label: {
                            HStack {
                                Spacer()
                                if sending { ProgressView() } else {
                                    Label(selectedFiles.isEmpty ? "Выбери файл" : "Скачать на сервер (\(Format.bytes(selectedFiles.reduce(0) { $0 + $1.size })))",
                                          systemImage: "icloud.and.arrow.down")
                                        .font(.headline)
                                }
                                Spacer()
                            }
                        }
                        .disabled(selectedFiles.isEmpty || sending || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    } footer: {
                        if let sentMessage { Text(sentMessage) }
                    }
                }
            } else if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            } else {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard details == nil else { return }
            do {
                let d = try await ArchiveAPI.details(item.id)
                details = d
                title = d.title
                if let best = d.files.max(by: { $0.size < $1.size }) { selected = [best.name] }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func fileInfo(_ f: ArchiveFile) -> String {
        var parts = [Format.bytes(f.size)]
        if let len = f.length, len > 0 { parts.append(Format.time(len)) }
        if !f.format.isEmpty { parts.append(f.format) }
        return parts.joined(separator: " · ")
    }

    private func send(_ details: ArchiveDetails) async {
        sending = true
        defer { sending = false }
        do {
            try await ArchiveAPI.download(item: details, title: title.trimmingCharacters(in: .whitespaces), files: selectedFiles)
            sentMessage = "Загрузка на сервер началась. Прогресс виден на главном экране вкладки «Архив», а когда закончится, фильм появится во вкладке «Сериалы»."
            await ArchiveJobs.shared.refresh()
        } catch {
            sentMessage = "Не получилось: \(error.localizedDescription)"
        }
    }
}
