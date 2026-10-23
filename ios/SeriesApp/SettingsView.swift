import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: LocalStore
    @State private var checking = false
    @State private var checkResult: (ok: Bool, text: String)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("например 1-2-3-4.sslip.io:8443", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Пароль", text: $settings.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            Text("Проверить подключение")
                            Spacer()
                            if checking {
                                ProgressView()
                            } else if let checkResult {
                                Image(systemName: checkResult.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(checkResult.ok ? .green : .red)
                            }
                        }
                    }
                    .disabled(checking || !settings.isConfigured)
                } header: {
                    Text("Сервер")
                } footer: {
                    if let checkResult {
                        Text(checkResult.text)
                    } else {
                        Text("Адрес и пароль показал скрипт установки сервера.")
                    }
                }

                Section {
                    Toggle("Сразу включать следующую серию", isOn: $settings.autoNext)
                    Toggle("После просмотра удалять с телефона", isOn: $settings.deleteWatched)
                    Toggle("После просмотра удалять с сервера", isOn: $settings.deleteWatchedOnServer)
                } header: {
                    Text("Просмотр")
                } footer: {
                    Text("Серия считается просмотренной после 90%. Если в этот момент нет интернета, с сервера она удалится, когда связь появится.")
                }

                Section {
                    Toggle("Скачивать только по Wi-Fi", isOn: $settings.wifiOnly)
                } header: {
                    Text("Загрузки")
                } footer: {
                    Text("Действует на новые загрузки. По мобильному интернету серии в хорошем качестве съедают много трафика.")
                }

                Section("Память") {
                    LabeledContent("Скачано", value: Format.bytes(store.totalDownloadedSize))
                    LabeledContent("Свободно на телефоне", value: Format.bytes(Format.deviceFreeSpace()))
                }

                Section {
                    LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                }
            }
            .navigationTitle("Настройки")
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            try await APIClient.ping()
            checkResult = (true, "Подключение есть.")
        } catch {
            checkResult = (false, error.localizedDescription)
        }
    }
}
