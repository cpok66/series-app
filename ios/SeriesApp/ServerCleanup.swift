import Foundation

/// Удаляет серии с сервера. Если интернета нет (например, в самолёте), удаление ждёт
/// в очереди и выполняется, когда связь появится.
enum ServerCleanup {
    private static var running = false

    @MainActor
    static func delete(_ ids: [String]) async {
        LocalStore.shared.queueServerDelete(ids)
        await flush()
    }

    @MainActor
    static func flush() async {
        guard !running, AppSettings.shared.isConfigured else { return }
        running = true
        defer { running = false }
        var changed = false
        for id in LocalStore.shared.pendingServerDeletes {
            do {
                try await APIClient.deleteOnServer(id)
                LocalStore.shared.serverDeleteDone(id)
                changed = true
            } catch APIError.server(404) {
                LocalStore.shared.serverDeleteDone(id)  // уже удалено
                changed = true
            } catch {
                break  // нет связи: попробуем позже
            }
        }
        if changed {
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
    }
}
