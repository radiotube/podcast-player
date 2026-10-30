import SwiftUI
import BackgroundTasks

@main
struct N5PREcasterApp: App {
    @StateObject private var dropbox: Dropbox
    @StateObject private var library: Library
    @StateObject private var player: Player
    @Environment(\.scenePhase) private var phase

    init() {
        URLCache.shared = URLCache(memoryCapacity: 50_000_000, diskCapacity: 300_000_000)
        let d = Dropbox()
        let l = Library(dropbox: d, downloads: Downloads())
        let p = Player(library: l)
        _dropbox = StateObject(wrappedValue: d)
        _library = StateObject(wrappedValue: l)
        _player = StateObject(wrappedValue: p)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dropbox)
                .environmentObject(library)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .environmentObject(library.downloads)
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background {
                player.savePosition()
                N5PREcasterApp.scheduleRefresh()
            }
            if newPhase == .active { Task { await library.refreshAll() } }
        }
        .backgroundTask(.appRefresh(N5PREcasterApp.refreshId)) {
            N5PREcasterApp.scheduleRefresh()
            await refreshInBackground()
        }
    }

    nonisolated static let refreshId = "n5pre.refresh"

    /// Asks iOS to wake the app now and then to look for new Favorites episodes.
    nonisolated static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private func refreshInBackground() async {
        await library.refreshAll(force: true)
    }
}
