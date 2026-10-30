import SwiftUI

@main
struct N5PREcasterApp: App {
    @StateObject private var dropbox: Dropbox
    @StateObject private var library: Library
    @StateObject private var player: Player
    @Environment(\.scenePhase) private var phase

    init() {
        URLCache.shared = URLCache(memoryCapacity: 50_000_000, diskCapacity: 300_000_000)
        let d = Dropbox()
        let l = Library(dropbox: d)
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
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background { player.savePosition() }
            if newPhase == .active { Task { await library.refresh(force: false) } }
        }
    }
}
