import SwiftUI
import AVFoundation
import UIKit

@main
struct SeriesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppSettings.shared)
                .environmentObject(LocalStore.shared)
                .environmentObject(DownloadManager.shared)
                .preferredColorScheme(.dark)
                .tint(.orange)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await ServerCleanup.flush() }
            } else {
                LocalStore.shared.saveNow()
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        _ = DownloadManager.shared
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Сериалы", systemImage: "film.stack") }
            ArchiveView()
                .tabItem { Label("Архив", systemImage: "building.columns") }
            DownloadsView()
                .tabItem { Label("Скачано", systemImage: "arrow.down.circle") }
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
        }
    }
}

enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait

    static func set(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                var top = window.rootViewController?.presentedViewController
                while let vc = top {
                    vc.setNeedsUpdateOfSupportedInterfaceOrientations()
                    top = vc.presentedViewController
                }
            }
            scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: newMask)) { _ in }
        }
    }
}

enum PlayerLauncher {
    static func play(_ playlist: [DownloadedEpisode], startAt id: String) {
        guard let index = playlist.firstIndex(where: { $0.id == id }) else { return }
        guard let top = topViewController() else { return }
        let vc = PlayerViewController(playlist: playlist, index: index)
        top.present(vc, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
