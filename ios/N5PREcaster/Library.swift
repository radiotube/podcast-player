import Foundation

/// Shows, subjects and favorites, read from the web app's sync.json in Dropbox.
/// This build only reads Dropbox. It never uploads, so it can't change the web app's list.
@MainActor
final class Library: ObservableObject {
    @Published var shows: [String: Show] = [:]
    @Published var fav: [String] = []
    @Published var catOrder: [String] = []
    @Published var savedBy = ""
    @Published var savedAt = ""
    @Published var status = ""
    @Published var busy = false
    @Published var episodes: [String: [Episode]] = [:]
    @Published var feedErrors: [String: String] = [:]
    @Published var loading: Set<String> = []
    @Published private var localPos: [String: Double] = [:]
    @Published private var localPlayed: [String: Double] = [:]

    var remotePos: [String: Double] = [:]
    var remotePlayed: [String: Double] = [:]
    var speed: Double = 1
    var skipBack: Double = 15
    var skipFwd: Double = 30
    private var lastRefresh = Date.distantPast

    let dropbox: Dropbox

    init(dropbox: Dropbox) {
        self.dropbox = dropbox
        let d = UserDefaults.standard
        localPos = d.dictionary(forKey: "pos") as? [String: Double] ?? [:]
        localPlayed = d.dictionary(forKey: "played") as? [String: Double] ?? [:]
        if let data = try? Data(contentsOf: Library.cacheURL) { try? apply(data) }
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync.json")
    }

    // MARK: Dropbox

    func refresh(force: Bool = true) async {
        if !force && Date().timeIntervalSince(lastRefresh) < 120 { return }
        guard dropbox.signedIn else {
            status = "Sign in with Dropbox in Settings to bring in your shows."
            return
        }
        if busy { return }
        busy = true
        defer { busy = false }
        do {
            guard let data = try await dropbox.downloadSync() else {
                status = "Dropbox has no list from the web app yet."
                return
            }
            try apply(data)
            try? data.write(to: Library.cacheURL, options: .atomic)
            lastRefresh = Date()
            status = ""
        } catch {
            status = "Couldn't read your list from Dropbox: \(error.localizedDescription)"
        }
    }

    func apply(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              J.str(root["app"]) == "podcast-player" else {
            throw AppError("The file in Dropbox isn't the podcast player's list.")
        }
        var out: [String: Show] = [:]
        for (key, raw) in (root["subs"] as? [String: Any]) ?? [:] {
            guard let o = raw as? [String: Any] else { continue }
            var cats: [String] = []
            for c in (o["cats"] as? [Any]) ?? [] {
                let s = J.str(c).trimmingCharacters(in: .whitespaces)
                if !s.isEmpty && !cats.contains(s) { cats.append(s) }
            }
            let one = J.str(o["cat"]).trimmingCharacters(in: .whitespaces)
            if !one.isEmpty && !cats.contains(one) { cats.append(one) }
            out[key] = Show(id: key,
                            title: J.str(o["title"]).isEmpty ? "Untitled show" : J.str(o["title"]),
                            author: J.str(o["author"]),
                            feedUrl: J.str(o["feedUrl"]),
                            art: J.str(o["art"]),
                            cats: cats,
                            itunesId: J.str(o["itunesId"]))
        }
        shows = out
        fav = ((root["fav"] as? [Any]) ?? []).map { J.str($0) }.filter { out[$0] != nil }

        var pos: [String: Double] = [:]
        for (k, v) in (root["pos"] as? [String: Any]) ?? [:] where !k.hasSuffix("#len") {
            if let n = J.num(v) { pos[k] = n }
        }
        remotePos = pos
        var played: [String: Double] = [:]
        for (k, v) in (root["played"] as? [String: Any]) ?? [:] {
            if let b = v as? Bool { played[k] = b ? 1 : 0 } else if let n = J.num(v) { played[k] = n }
        }
        remotePlayed = played

        let prefs = (root["prefs"] as? [String: Any]) ?? [:]
        if let s = J.num(prefs["speed"]), s > 0 { speed = s }
        if let s = J.num(prefs["skipBack"]), s > 0 { skipBack = s }
        if let s = J.num(prefs["skipFwd"]), s > 0 { skipFwd = s }
        catOrder = ((prefs["catOrder"] as? [Any]) ?? []).map { J.str($0) }
        savedBy = J.str(root["by"])
        savedAt = J.str(root["at"])
    }

    // MARK: Lists

    var subjects: [String] {
        let all = Set(shows.values.flatMap { $0.cats })
        var seen = Set<String>()
        var out = catOrder.filter { all.contains($0) && seen.insert($0).inserted }
        out += all.subtracting(out).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return out
    }

    var favShows: [Show] { fav.compactMap { shows[$0] } }

    var allShows: [Show] {
        shows.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func showsIn(_ subject: String) -> [Show] {
        allShows.filter { $0.cats.contains(subject) }
    }

    // MARK: Episodes

    func loadEpisodes(_ show: Show, force: Bool = false) async {
        if !force, let list = episodes[show.id], !list.isEmpty { return }
        if loading.contains(show.id) { return }
        if episodes[show.id] == nil, let cached = Feeds.cached(show.id) { episodes[show.id] = cached }
        loading.insert(show.id)
        defer { loading.remove(show.id) }
        do {
            var feed = show.feedUrl
            if feed.isEmpty {
                guard !show.itunesId.isEmpty else { throw AppError("This show has no feed address.") }
                feed = try await Feeds.lookupFeed(itunesId: show.itunesId)
                shows[show.id]?.feedUrl = feed
            }
            let list = try await Feeds.fetch(feed, showId: show.id)
            episodes[show.id] = list
            feedErrors[show.id] = nil
            Feeds.store(list, for: show.id)
        } catch {
            feedErrors[show.id] = error.localizedDescription
        }
    }

    // MARK: Listening spots and played marks (kept on this iPhone for now)

    func position(_ guid: String) -> Double {
        if let p = localPos[guid] { return p }
        if isPlayed(guid) { return 0 }
        return remotePos[guid] ?? 0
    }

    func savePosition(_ guid: String, _ t: Double) {
        localPos[guid] = t.rounded()
        UserDefaults.standard.set(localPos, forKey: "pos")
    }

    func isPlayed(_ guid: String) -> Bool {
        if let v = localPlayed[guid] { return v > 0 }
        return (remotePlayed[guid] ?? 0) > 0
    }

    func setPlayed(_ guid: String, _ on: Bool) {
        let now = Date().timeIntervalSince1970 * 1000
        localPlayed[guid] = on ? now : -now
        localPos[guid] = 0
        UserDefaults.standard.set(localPlayed, forKey: "played")
        UserDefaults.standard.set(localPos, forKey: "pos")
    }
}
