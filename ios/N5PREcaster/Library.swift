import Foundation
import CryptoKit

/// Shows, subjects and favorites, from the web app's sync.json in Dropbox.
/// Edits made here are saved straight into Dropbox's current copy (see edit), never from a copy kept here.
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
    /// When each listening spot here was saved (ms), to compare with the web app's posT.
    private var localPosT: [String: Double] = [:]
    /// Episodes whose spot or played mark changed here and haven't reached Dropbox yet.
    private var unsent: Set<String> = []
    private var sendTask: Task<Void, Never>?

    var remotePos: [String: Double] = [:]
    var remotePlayed: [String: Double] = [:]
    var remotePosT: [String: Double] = [:]
    /// The episode last played anywhere, in the web app's format, and when (ms).
    private(set) var remoteNow: [String: Any]?
    private(set) var remoteNowT: Double = 0
    /// When this iPhone last started playing something (ms).
    private var localNowT: Double = UserDefaults.standard.double(forKey: "nowT")
    private var nowToSend: [String: Any]?
    /// The list as last read from Dropbox, the one shown on screen.
    private var lastRoot: [String: Any] = [:]
    var speed: Double = 1
    @Published var skipBack: Double = 15
    @Published var skipFwd: Double = 30
    /// The web app's playback settings, shared through Dropbox.
    @Published var autoNext = true
    @Published var adSkip = true
    @Published var trim = false
    @Published var trimMin: Double = 1
    /// The web app's Past episodes per show (0 means all).
    /// The web app's "Past episodes per show" (0 = all) and episode order ("new" or "old").
    @Published var epCap = 0
    @Published var epSort = "new"
    /// Shows whose transcripts this iPhone makes ahead (kept on this device, like the web app's Make them ahead).
    @Published var txShows: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "tx.shows") ?? []) {
        didSet { UserDefaults.standard.set(Array(txShows), forKey: "tx.shows") }
    }
    /// Quiet shows you chose to keep (web "keep": show id → when, in ms).
    @Published var keepQuiet: [String: Double] = [:]
    /// Shows checked so far while looking for quiet ones (0 when not checking).
    @Published var quietChecked = 0
    /// The episode in the player, which lists always keep.
    var playingGuid = ""
    private(set) var piKey = ""
    private var piSecret = ""
    private var lastRefresh = Date.distantPast
    private var lastFavCheck = Date.distantPast

    let dropbox: Dropbox
    let downloads: Downloads

    init(dropbox: Dropbox, downloads: Downloads) {
        self.dropbox = dropbox
        self.downloads = downloads
        let d = UserDefaults.standard
        localPos = d.dictionary(forKey: "pos") as? [String: Double] ?? [:]
        localPlayed = d.dictionary(forKey: "played") as? [String: Double] ?? [:]
        localPosT = d.dictionary(forKey: "posT") as? [String: Double] ?? [:]
        unsent = Set(d.stringArray(forKey: "unsent") ?? [])
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

    /// The list from Dropbox, then fresh episode lists for Favorites (which starts their downloads).
    func refreshAll(force: Bool = false) async {
        await sendProgress()
        await refresh(force: force)
        await refreshFavorites(force: force)
    }

    func refreshFavorites(force: Bool = false) async {
        if !force && Date().timeIntervalSince(lastFavCheck) < 15 * 60 { return }
        lastFavCheck = Date()
        let tx = allShows.filter { txShows.contains($0.id) && !fav.contains($0.id) }
        for show in favShows + tx { await loadEpisodes(show, force: true) }
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
                            itunesId: J.str(o["itunesId"]),
                            dlKeep: J.num(o["dlKeep"]).map { Int($0) })
        }
        shows = out
        fav = ((root["fav"] as? [Any]) ?? []).map { J.str($0) }.filter { out[$0] != nil }
        keepQuiet = ((root["keep"] as? [String: Any]) ?? [:]).compactMapValues { J.num($0) }

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
        var posT: [String: Double] = [:]
        for (k, v) in (root["posT"] as? [String: Any]) ?? [:] { if let n = J.num(v) { posT[k] = n } }
        remotePosT = posT

        let prefs = (root["prefs"] as? [String: Any]) ?? [:]
        if let s = J.num(prefs["speed"]), s > 0 { speed = s }
        if let s = J.num(prefs["skipBack"]), s > 0 { skipBack = s }
        if let s = J.num(prefs["skipFwd"]), s > 0 { skipFwd = s }
        autoNext = (prefs["autoNext"] as? Bool) ?? true
        adSkip = (prefs["adSkip"] as? Bool) ?? true
        trim = (prefs["trim"] as? Bool) ?? false
        if let m = J.num(prefs["trimMin"]), m > 0 { trimMin = m }
        catOrder = ((prefs["catOrder"] as? [Any]) ?? []).map { J.str($0) }
        epCap = Int(J.num(prefs["epCap"]) ?? 0)
        epSort = J.str(prefs["epSort"]) == "old" ? "old" : "new"
        let pi = (root["pi"] as? [String: Any]) ?? [:]
        piKey = J.str(pi["key"])
        piSecret = J.str(pi["secret"])
        savedBy = J.str(root["by"])
        savedAt = J.str(root["at"])
        remoteNow = root["now"] as? [String: Any]
        remoteNowT = J.num(root["nowT"]) ?? 0
        lastRoot = root
        hideSugg = Set(((root["hideSugg"] as? [String: Any]) ?? [:]).keys)
        let words = (J.strs(prefs["skipWords"]), J.strs(prefs["hiWords"]))
        wordAt = ((prefs["wordAt"] as? [String: Any]) ?? [:]).compactMapValues { J.num($0) }
        if words.0 != skipWords || words.1 != hiWords {
            (skipWords, hiWords) = words
            hits = [:]
            for (id, list) in episodes { indexWords(list, for: id) }
        }
    }

    // MARK: Words (the web app's skip and highlight word lists)

    struct WordHit { var h = ""; var s = ""; var sAt: Double = 0 }
    @Published private(set) var skipWords: [String] = []
    @Published private(set) var hiWords: [String] = []
    private var wordAt: [String: Double] = [:]
    private var hits: [String: WordHit] = [:]
    private var wordRxs: [String: NSRegularExpression] = [:]
    /// Words from before their dates were kept count from when skip words first shipped (web app).
    private static let wordsShipped: Double = 1792980000000

    static func wordKey(_ p: String) -> String {
        p.replacingOccurrences(of: "[\u{2018}\u{2019}\u{02BC}]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[\u{201C}\u{201D}]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Whole words in any capitals; a plain plural or possessive counts too.
    private func matches(_ k: String, _ text: String) -> Bool {
        if wordRxs[k] == nil {
            var body = NSRegularExpression.escapedPattern(for: k).replacingOccurrences(of: " ", with: "\\s+")
            if k.last.map({ $0.isLetter || $0.isNumber }) == true { body += "(?:'s|s|es)?" }
            wordRxs[k] = try? NSRegularExpression(pattern: "(^|[^\\p{L}\\p{N}_])" + body + "(?=$|[^\\p{L}\\p{N}_])",
                                                  options: [.caseInsensitive])
        }
        guard let rx = wordRxs[k] else { return text.contains(k) }
        return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func indexWords(_ list: [Episode], for id: String) {
        guard !skipWords.isEmpty || !hiWords.isEmpty else { return }
        for ep in list {
            let text = Library.wordKey(ep.title + " " + ep.summary)
            var r = WordHit()
            r.h = hiWords.first { let k = Library.wordKey($0); return !k.isEmpty && matches(k, text) } ?? ""
            if r.h.isEmpty {
                for w in skipWords {
                    let k = Library.wordKey(w)
                    guard !k.isEmpty, matches(k, text) else { continue }
                    if r.s.isEmpty { r.s = w }
                    r.sAt = max(r.sAt, wordAt[k] ?? Library.wordsShipped)
                }
            }
            if r.h.isEmpty && r.s.isEmpty { hits[ep.guid] = nil } else { hits[ep.guid] = r }
        }
    }

    private func setEpisodes(_ list: [Episode], for id: String) {
        episodes[id] = list
        indexWords(list, for: id)
    }

    /// The skip word that counts this episode as played right now, or "". Never the one in the player,
    /// one you're partway through, or one marked not played after the word was added.
    func skipBy(_ guid: String) -> String {
        guard !skipWords.isEmpty, let r = hits[guid], !r.s.isEmpty, guid != playingGuid, position(guid) <= 5 else { return "" }
        let v = latestPlayed(guid)
        if v < 0 && -v >= r.sAt { return "" }
        return r.s
    }

    /// Played only because of a skip word.
    func skipWhy(_ guid: String) -> String { markedPlayed(guid) ? "" : skipBy(guid) }

    func hiWord(_ guid: String) -> String { hiWords.isEmpty ? "" : (hits[guid]?.h ?? "") }

    /// Changes a word list in Dropbox, noting when each new word was added.
    func setWords(skip: [String]? = nil, hi: [String]? = nil) async {
        await edit { root in
            var prefs = (root["prefs"] as? [String: Any]) ?? [:]
            var at = (prefs["wordAt"] as? [String: Any]) ?? [:]
            for w in (skip ?? []) + (hi ?? []) where at[Library.wordKey(w)] == nil { at[Library.wordKey(w)] = Library.nowMs }
            if let skip { prefs["skipWords"] = skip }
            if let hi { prefs["hiWords"] = hi }
            prefs["wordAt"] = at
            root["prefs"] = prefs
        }
    }

    // MARK: Suggested shows

    @Published private(set) var hideSugg: Set<String> = []

    /// New shows for a subject from Podcast Index (then Apple), leaving out shows you follow or turned down.
    func suggestions(for subject: String) async throws -> [FoundShow] {
        let titles = Set(shows.values.map { $0.title.lowercased().trimmingCharacters(in: .whitespaces) })
        return try await search(subject).filter { f in
            !hideSugg.contains(f.id) && followedId(f) == nil
                && !titles.contains(f.title.lowercased().trimmingCharacters(in: .whitespaces))
        }
    }

    func hideSuggestion(_ id: String) async {
        await edit { root in
            var h = (root["hideSugg"] as? [String: Any]) ?? [:]
            h[id] = 1
            root["hideSugg"] = h
        }
    }

    // MARK: Podcast Index key (synced through Dropbox, like the web app)

    /// Checks the key with Podcast Index, then saves it. An empty key removes it everywhere.
    func setPodcastIndexKey(_ key: String, _ secret: String) async -> String {
        let k = key.trimmingCharacters(in: .whitespaces), s = secret.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty {
            let old = (piKey, piSecret)
            (piKey, piSecret) = (k, s)
            let ok = (try? await piGet("search/byterm", ["q": "news", "max": "1"])) != nil
            if !ok {
                (piKey, piSecret) = old
                return "Podcast Index turned down that key and secret. Check them and try again."
            }
        }
        let ok = await edit { root in
            root["pi"] = k.isEmpty ? ["key": "", "secret": "", "t": Library.nowMs, "gone": true] as [String: Any]
                                   : ["key": k, "secret": s, "t": Library.nowMs] as [String: Any]
        }
        return ok ? (k.isEmpty ? "Key removed on all your devices." : "Key saved. Your other devices get it the next time they sync.") : ""
    }

    // MARK: Backup and earlier copies

    /// A backup file in the web app's format, made from Dropbox's copy of your list.
    func backupData() -> Data? {
        let r = lastRoot, p = (r["prefs"] as? [String: Any]) ?? [:]
        guard !r.isEmpty else { return nil }
        var d: [String: Any] = ["app": "podcast-player", "v": 1, "at": ISO8601DateFormatter().string(from: Date())]
        for k in ["subs", "fav", "pos", "played"] { d[k] = r[k] ?? [:] }
        for k in ["speed", "skipBack", "skipFwd", "adSkip", "skipWords", "hiWords", "wordAt", "catOrder"] { if let v = p[k] { d[k] = v } }
        return try? JSONSerialization.data(withJSONObject: d)
    }

    /// Puts back a backup file or an earlier copy, the web app's way: its shows join what's there now,
    /// its favorites order and settings win, and listening spots and played marks keep whichever is newer.
    /// Nothing in today's list is removed.
    func putBack(_ data: Data) async -> Bool {
        guard let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any], J.str(old["app"]) == "podcast-player" else {
            status = "That isn't a podcast player backup or list."
            return false
        }
        let ok = await edit { root in
            var subs = Library.subs(root), unf = (root["unf"] as? [String: Any]) ?? [:]
            for (id, v) in Library.subs(old) {
                guard var o = v as? [String: Any] else { continue }
                if var cur = subs[id] as? [String: Any] {
                    if ((cur["cats"] as? [Any]) ?? []).isEmpty, let c = o["cats"] { cur["cats"] = c; subs[id] = cur }
                } else {
                    o["fT"] = Library.nowMs
                    subs[id] = o
                    unf[id] = nil
                }
            }
            root["subs"] = subs
            root["unf"] = unf
            let favOld = ((old["fav"] as? [Any]) ?? []).map { J.str($0) }.filter { subs[$0] != nil }
            let favNow = ((root["fav"] as? [Any]) ?? []).map { J.str($0) }
            root["fav"] = favOld + favNow.filter { !favOld.contains($0) }
            var prefs = (root["prefs"] as? [String: Any]) ?? [:]
            let oldPrefs = (old["prefs"] as? [String: Any]) ?? old
            for k in ["speed", "skipBack", "skipFwd", "adSkip", "epSort", "trim", "trimMin", "autoNext", "epCap",
                      "skipWords", "hiWords", "wordAt", "catOrder"] { if let v = oldPrefs[k] { prefs[k] = v } }
            root["prefs"] = prefs
            // Played marks: the later mark wins. Spots: the newer one wins (a backup file has no times, so it only fills gaps).
            var played = (root["played"] as? [String: Any]) ?? [:]
            for (g, v) in (old["played"] as? [String: Any]) ?? [:] {
                let o = (v as? Bool) == true ? 1 : (J.num(v) ?? 0), n = (played[g] as? Bool) == true ? 1 : (J.num(played[g]) ?? 0)
                if abs(o) > abs(n) { played[g] = v }
            }
            root["played"] = played
            var pos = (root["pos"] as? [String: Any]) ?? [:], posT = (root["posT"] as? [String: Any]) ?? [:]
            let oldT = (old["posT"] as? [String: Any]) ?? [:]
            for (g, v) in (old["pos"] as? [String: Any]) ?? [:] where (J.num(oldT[g]) ?? 0) > (J.num(posT[g]) ?? 0) || pos[g] == nil {
                pos[g] = v
                if let t = oldT[g] { posT[g] = t }
            }
            root["pos"] = pos
            root["posT"] = posT
        }
        if ok { status = "Put back. Your shows, subjects and settings are back." }
        return ok
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

    /// Every unplayed episode from a subject's shows, newest first, once their lists have loaded.
    /// A show's newest episodes up to the Past episodes per show limit, like the web app. Older ones stay
    /// when they're in the player, partway through, or marked not played (Hear again). Nothing is deleted.
    func capped(_ eps: [Episode]) -> [Episode] {
        guard epCap > 0, eps.count > epCap else { return eps }
        let top = Set(eps.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(epCap).map(\.guid))
        return eps.filter { top.contains($0.guid) || keepAnyway($0.guid) }
    }

    func keepAnyway(_ guid: String) -> Bool {
        if guid == playingGuid { return true }
        if isPlayed(guid) { return false }
        let l = localPlayed[guid] ?? 0, r = remotePlayed[guid] ?? 0
        return position(guid) > 5 || (abs(l) >= abs(r) ? l : r) < 0
    }

    /// Episodes in the chosen order.
    func sorted(_ eps: [Episode]) -> [Episode] {
        let old = epSort == "old"
        return eps.sorted { a, b in
            let x = a.date ?? .distantPast, y = b.date ?? .distantPast
            return old ? x < y : x > y
        }
    }

    func unplayed(in subject: String) -> [SubjectItem] {
        var out: [SubjectItem] = []
        for show in showsIn(subject) {
            for ep in capped(episodes[show.id] ?? []) where !isPlayed(ep.guid) { out.append(SubjectItem(episode: ep, show: show)) }
        }
        out.sort { ($0.episode.date ?? .distantPast) > ($1.episode.date ?? .distantPast) }
        return Array(out.prefix(150))
    }

    /// The newest episode not heard yet, once the show's list has loaded.
    func latestUnheard(_ show: Show) -> Episode? {
        episodes[show.id]?.first { !isPlayed($0.guid) }
    }

    func loadEpisodes(_ show: Show, force: Bool = false) async {
        if !force, let list = episodes[show.id], !list.isEmpty { return }
        if loading.contains(show.id) { return }
        if episodes[show.id] == nil, let cached = Feeds.cached(show.id) { setEpisodes(cached, for: show.id) }
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
            setEpisodes(list, for: show.id)
            feedErrors[show.id] = nil
            Feeds.store(list, for: show.id)
            if fav.contains(show.id) || txShows.contains(show.id) { keepDownloads(show.id) }
        } catch {
            feedErrors[show.id] = error.localizedDescription
        }
    }

    // MARK: Downloads kept per show

    /// The show's own limit, else Past episodes per show, else 3.
    func keepCount(_ show: Show) -> Int {
        show.dlKeep ?? (epCap > 0 ? epCap : 3)
    }

    /// Downloads a favorite's newest unplayed episodes up to its limit, and removes
    /// older ones that were downloaded by themselves (ones you downloaded stay).
    /// Shows that make transcripts ahead also download (on Wi-Fi) the newest unplayed episodes that
    /// don't come with the show's own transcript.
    func keepDownloads(_ showId: String) {
        let tx = txShows.contains(showId)
        guard let show = shows[showId], fav.contains(showId) || tx, let list = episodes[showId] else { return }
        let n = max(0, keepCount(show))
        for ep in list.filter({ !isPlayed($0.guid) }).prefix(n) {
            if fav.contains(showId) { downloads.autoStart(ep) }
            if tx && (ep.transcript ?? "").isEmpty && !ep.isVideo { downloads.autoStart(ep, forTranscript: true) }
        }
        let have = list.filter { downloads.isDownloaded($0.guid) || downloads.progress[$0.guid] != nil }
        for ep in have.dropFirst(n) where downloads.auto.contains(ep.guid) {
            if downloads.progress[ep.guid] != nil { downloads.cancel(ep.guid) } else { downloads.remove(ep.guid, byUser: false) }
        }
    }

    // MARK: Changing the list

    /// Saves a change to the list in Dropbox. Each change starts from Dropbox's copy as it is right now
    /// and changes only what you asked. Dropbox takes it only if no other device saved in between
    /// (otherwise it starts again from the newer copy), so an older or partial list is never sent.
    /// Shows can leave only through `removing`, with the dated note the web app uses for unfollowing.
    @discardableResult
    func edit(removing: Set<String> = [], quiet: Bool = false, _ change: (inout [String: Any]) throws -> Void) async -> Bool {
        guard dropbox.signedIn else {
            if !quiet { status = "Sign in with Dropbox in Settings first." }
            return false
        }
        if !quiet { busy = true }
        defer { if !quiet { busy = false } }
        for _ in 0..<4 {
            do {
                guard let got = try await dropbox.downloadSyncWithRev() else {
                    throw AppError("Dropbox has no list from the web app yet.")
                }
                guard var root = try JSONSerialization.jsonObject(with: got.data) as? [String: Any],
                      J.str(root["app"]) == "podcast-player",
                      let before = root["subs"] as? [String: Any], !before.isEmpty else {
                    throw AppError("The list on Dropbox doesn't look right, so nothing was changed.")
                }
                try change(&root)
                let after = (root["subs"] as? [String: Any]) ?? [:]
                let unf = (root["unf"] as? [String: Any]) ?? [:]
                let lost = before.keys.filter { after[$0] == nil && !(removing.contains($0) && unf[$0] != nil) }
                guard lost.isEmpty, after.count >= before.count - removing.count else {
                    throw AppError("Stopped so no other shows were removed from Dropbox. Nothing was changed.")
                }
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                root["at"] = f.string(from: Date())
                root["by"] = "iPhone app"
                let out = try JSONSerialization.data(withJSONObject: root)
                try await dropbox.uploadSync(out, rev: got.rev)
                try apply(out)
                try? out.write(to: Library.cacheURL, options: .atomic)
                lastRefresh = Date()
                status = ""
                return true
            } catch is Dropbox.SyncConflict {
                continue
            } catch {
                if !quiet { status = "Couldn't save to Dropbox: \(error.localizedDescription)" }
                return false
            }
        }
        if !quiet { status = "Couldn't save to Dropbox because another device kept saving. Try again." }
        return false
    }

    private static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func subs(_ root: [String: Any]) -> [String: Any] { (root["subs"] as? [String: Any]) ?? [:] }

    func setKeep(_ showId: String, _ n: Int?) async {
        let ok = await edit { root in
            var subs = Library.subs(root)
            guard var sh = subs[showId] as? [String: Any] else { throw AppError("That show isn't in your list on Dropbox.") }
            if let n { sh["dlKeep"] = n } else { sh.removeValue(forKey: "dlKeep") }
            subs[showId] = sh
            root["subs"] = subs
        }
        if ok { keepDownloads(showId) }
    }

    func isFollowed(_ f: FoundShow) -> Bool { followedId(f) != nil }

    private func followedId(_ f: FoundShow) -> String? {
        if shows[f.id] != nil { return f.id }
        let feed = f.feedUrl.lowercased()
        return shows.values.first { s in
            (f.itunesId != nil && s.itunesId == String(f.itunesId!)) || (!feed.isEmpty && s.feedUrl.lowercased() == feed)
        }?.id
    }

    func addShow(_ f: FoundShow, subject: String) async {
        guard followedId(f) == nil else {
            status = "\(f.title) is already in your list."
            return
        }
        let subj = subject.trimmingCharacters(in: .whitespaces)
        await edit { root in
            var subs = Library.subs(root)
            if subs[f.id] != nil { return }
            var sh: [String: Any] = ["id": f.id, "title": f.title, "author": f.author,
                                     "feedUrl": f.feedUrl, "art": f.art, "fT": Library.nowMs]
            if let i = f.itunesId { sh["itunesId"] = i }
            if let p = f.piId { sh["piId"] = p }
            if !subj.isEmpty { sh["cats"] = [subj] }
            subs[f.id] = sh
            root["subs"] = subs
        }
    }

    func removeShow(_ showId: String) async {
        await edit(removing: [showId]) { root in
            var subs = Library.subs(root)
            subs.removeValue(forKey: showId)
            root["subs"] = subs
            root["fav"] = ((root["fav"] as? [Any]) ?? []).filter { J.str($0) != showId }
            var unf = (root["unf"] as? [String: Any]) ?? [:]
            unf[showId] = Library.nowMs
            root["unf"] = unf
        }
    }

    func setFavorite(_ showId: String, _ on: Bool) async {
        await edit { root in
            guard Library.subs(root)[showId] != nil else { throw AppError("That show isn't in your list on Dropbox.") }
            var list = ((root["fav"] as? [Any]) ?? []).map { J.str($0) }
            if on { if !list.contains(showId) { list.append(showId) } } else { list.removeAll { $0 == showId } }
            root["fav"] = list
        }
    }

    func setSubjects(_ showId: String, _ cats: [String]) async {
        var clean: [String] = []
        for c in cats.map({ $0.trimmingCharacters(in: .whitespaces) }) where !c.isEmpty && !clean.contains(c) { clean.append(c) }
        await edit { root in
            var subs = Library.subs(root)
            guard var sh = subs[showId] as? [String: Any] else { throw AppError("That show isn't in your list on Dropbox.") }
            sh.removeValue(forKey: "cat")
            if clean.isEmpty { sh.removeValue(forKey: "cats") } else { sh["cats"] = clean }
            subs[showId] = sh
            root["subs"] = subs
        }
    }

    func renameSubject(_ old: String, to new: String) async {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        await edit { root in
            var subs = Library.subs(root)
            for (id, raw) in subs {
                guard var sh = raw as? [String: Any] else { continue }
                var cats = ((sh["cats"] as? [Any]) ?? []).map { J.str($0) }
                if J.str(sh["cat"]) == old { cats.append(old) }
                guard cats.contains(old) else { continue }
                var out: [String] = []
                for c in cats.map({ $0 == old ? name : $0 }) where !out.contains(c) { out.append(c) }
                sh.removeValue(forKey: "cat")
                sh["cats"] = out
                subs[id] = sh
            }
            root["subs"] = subs
            var prefs = (root["prefs"] as? [String: Any]) ?? [:]
            if let order = prefs["catOrder"] as? [Any] {
                var out: [String] = []
                for c in order.map({ J.str($0) == old ? name : J.str($0) }) where !out.contains(c) { out.append(c) }
                prefs["catOrder"] = out
                root["prefs"] = prefs
            }
        }
    }

    // MARK: Settings

    /// Changes one of the web app's shared settings (prefs) in Dropbox.
    func setPref(_ key: String, _ value: Any) async {
        await edit { root in
            var prefs = (root["prefs"] as? [String: Any]) ?? [:]
            prefs[key] = value
            root["prefs"] = prefs
        }
    }

    /// What plays when an episode ends: the next unplayed one in the subject it was started from,
    /// or else in its show, in the order the lists show them.
    func nextEpisode(after ep: Episode, subject: String?) -> (Episode, Show)? {
        if let subject {
            return unplayed(in: subject).first { $0.episode.guid != ep.guid }.map { ($0.episode, $0.show) }
        }
        guard let show = shows[ep.showId],
              let next = episodes[ep.showId]?.first(where: { !isPlayed($0.guid) && $0.guid != ep.guid }) else { return nil }
        return (next, show)
    }

    // MARK: Order

    func setFavoriteOrder(_ order: [String]) async {
        await edit { root in
            let remote = ((root["fav"] as? [Any]) ?? []).map { J.str($0) }
            var out = order.filter { remote.contains($0) }
            out += remote.filter { !out.contains($0) }
            root["fav"] = out
        }
    }

    /// Subjects in this order, ahead of any kept from before (the web app keeps old ones so they come back in place).
    func setSubjectOrder(_ order: [String]) async {
        await edit { root in
            var prefs = (root["prefs"] as? [String: Any]) ?? [:]
            let old = ((prefs["catOrder"] as? [Any]) ?? []).map { J.str($0) }
            prefs["catOrder"] = order + old.filter { !order.contains($0) }
            root["prefs"] = prefs
        }
    }

    // MARK: Use this iPhone's list everywhere

    struct ListSummary { var shows = 0, subjects = 0, favorites = 0 }

    static func summary(_ root: [String: Any]) -> ListSummary {
        let subs = (root["subs"] as? [String: Any]) ?? [:]
        var cats = Set<String>()
        for raw in subs.values {
            guard let o = raw as? [String: Any] else { continue }
            for c in (o["cats"] as? [Any]) ?? [] { cats.insert(J.str(c)) }
            if !J.str(o["cat"]).isEmpty { cats.insert(J.str(o["cat"])) }
        }
        return ListSummary(shows: subs.count, subjects: cats.count, favorites: ((root["fav"] as? [Any]) ?? []).count)
    }

    var localSummary: ListSummary { Library.summary(lastRoot) }

    func remoteSummary() async throws -> ListSummary {
        guard let got = try await dropbox.downloadSyncWithRev(),
              let root = try JSONSerialization.jsonObject(with: got.data) as? [String: Any] else { return ListSummary() }
        return Library.summary(root)
    }

    /// Like the web app's "Use this device's list everywhere": Dropbox gets the shows, subjects, favorites
    /// order and settings shown on this iPhone, shows missing here get a dated unfollow note, and the
    /// master mark tells every other device to take the list whole. Spots and played marks are left as they are.
    func useThisListEverywhere() async -> Bool {
        let mine = lastRoot
        let mineSubs = (mine["subs"] as? [String: Any]) ?? [:]
        guard mineSubs.count >= 2 else {
            status = "This iPhone has fewer than 2 shows, so it doesn't look like your full list."
            return false
        }
        guard let got = try? await dropbox.downloadSyncWithRev(),
              let remote = try? JSONSerialization.jsonObject(with: got.data) as? [String: Any] else {
            status = "Couldn't read Dropbox's list."
            return false
        }
        let leaving = Set(((remote["subs"] as? [String: Any]) ?? [:]).keys).subtracting(mineSubs.keys)
        let now = Library.nowMs
        return await edit(removing: leaving) { root in
            var unf = (root["unf"] as? [String: Any]) ?? [:]
            let theirs = (root["subs"] as? [String: Any]) ?? [:]
            var subs: [String: Any] = [:]
            for (id, raw) in mineSubs {
                guard var sh = raw as? [String: Any] else { continue }
                if let u = J.num(unf[id]), u > (J.num(sh["fT"]) ?? 0) { sh["fT"] = now }
                subs[id] = sh
            }
            for (id, raw) in theirs where subs[id] == nil {
                let fT = J.num((raw as? [String: Any])?["fT"]) ?? 0
                if (J.num(unf[id]) ?? 0) <= fT { unf[id] = now }
            }
            root["subs"] = subs
            root["fav"] = mine["fav"] ?? [Any]()
            if let p = mine["prefs"] { root["prefs"] = p }
            root["unf"] = unf
            root["master"] = now
        }
    }

    // MARK: Search

    var hasPodcastIndex: Bool { !piKey.isEmpty && !piSecret.isEmpty }

    /// Podcast Index first when the synced key is there, with Apple's directory as the backup.
    func search(_ term: String) async throws -> [FoundShow] {
        let q = term.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        if hasPodcastIndex, let found = try? await searchPodcastIndex(q), !found.isEmpty { return found }
        return try await searchApple(q)
    }

    private func searchPodcastIndex(_ q: String) async throws -> [FoundShow] {
        let root = try await piGet("search/byterm", ["q": q, "max": "30"])
        return ((root["feeds"] as? [[String: Any]]) ?? []).compactMap(Library.found)
    }

    private static func found(_ f: [String: Any]) -> FoundShow? {
        guard let pid = J.num(f["id"]).map({ Int($0) }) else { return nil }
        let it = J.num(f["itunesId"]).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        let feed = J.str(f["url"]).isEmpty ? J.str(f["originalUrl"]) : J.str(f["url"])
        let art = J.str(f["artwork"]).isEmpty ? J.str(f["image"]) : J.str(f["artwork"])
        let author = J.str(f["author"]).isEmpty ? J.str(f["ownerName"]) : J.str(f["author"])
        return FoundShow(id: it.map { "it:\($0)" } ?? "pi:\(pid)", itunesId: it, piId: pid,
                         title: J.str(f["title"]), author: author, feedUrl: feed, art: art, source: "Podcast Index")
    }

    private func piGet(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        var c = URLComponents(string: "https://api.podcastindex.org/api/1.0/" + path)!
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let date = String(Int(Date().timeIntervalSince1970))
        let hash = Insecure.SHA1.hash(data: Data((piKey + piSecret + date).utf8)).map { String(format: "%02x", $0) }.joined()
        var req = URLRequest(url: c.url!)
        req.setValue(date, forHTTPHeaderField: "X-Auth-Date")
        req.setValue(piKey, forHTTPHeaderField: "X-Auth-Key")
        req.setValue(hash, forHTTPHeaderField: "Authorization")
        req.setValue("N5PREcaster/0.5 (iPhone)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AppError("Podcast Index didn't answer.") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Quiet shows

    /// The newest episode date known for a show.
    func lastEpisode(_ id: String) -> Date? { episodes[id]?.compactMap(\.date).max() }

    /// Shows with no new episode in a year that you haven't chosen to keep since then, quietest first.
    var quietShows: [Show] {
        let year = Date().addingTimeInterval(-365 * 86400)
        return allShows.filter { s in
            guard let d = lastEpisode(s.id), d < year else { return false }
            return !((keepQuiet[s.id] ?? 0) > d.timeIntervalSince1970 * 1000)
        }.sorted { (lastEpisode($0.id) ?? .distantPast) < (lastEpisode($1.id) ?? .distantPast) }
    }

    /// Loads episode lists for shows not loaded yet, so quiet ones can be found.
    func checkAllShows() async {
        let todo = allShows.filter { episodes[$0.id] == nil }
        quietChecked = 0
        for show in todo {
            await loadEpisodes(show)
            quietChecked += 1
        }
        quietChecked = 0
    }

    /// Keeps a quiet show, like the web app's Keep (asked again only if it stays quiet after a new episode).
    func keepQuietShow(_ id: String) async {
        await edit { root in
            var keep = (root["keep"] as? [String: Any]) ?? [:]
            keep[id] = Library.nowMs
            root["keep"] = keep
        }
    }

    // MARK: OPML

    static func normUrl(_ u: String) -> String {
        var s = u.trimmingCharacters(in: .whitespaces).lowercased()
        for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Adds the shows in another app's OPML export that aren't in your list yet, in one save.
    /// Shows found in Podcast Index get their artwork and ids, others are added by their feed.
    func importOPML(_ data: Data) async {
        let feeds = OPMLReader.feeds(data)
        guard !feeds.isEmpty else {
            status = "That file has no podcast feeds in it. Export OPML from your podcast app again."
            return
        }
        var have = Set(shows.values.map { Library.normUrl($0.feedUrl) })
        var add: [[String: Any]] = []
        var done = 0
        for f in feeds {
            done += 1
            status = "Matching \(done) of \(feeds.count) shows…"
            let key = Library.normUrl(f.url)
            if key.isEmpty || have.contains(key) { continue }
            have.insert(key)
            var sh: [String: Any] = ["id": "rss:" + f.url, "title": f.title.isEmpty ? f.url : f.title, "author": "",
                                     "feedUrl": f.url, "art": "", "fT": Library.nowMs]
            if hasPodcastIndex, let r = try? await piGet("podcasts/byfeedurl", ["url": f.url]),
               let feed = r["feed"] as? [String: Any], let m = Library.found(feed) {
                if shows[m.id] != nil { continue }
                sh = ["id": m.id, "title": m.title.isEmpty ? f.title : m.title, "author": m.author,
                      "feedUrl": f.url, "art": m.art, "fT": Library.nowMs]
                if let i = m.itunesId { sh["itunesId"] = i }
                if let p = m.piId { sh["piId"] = p }
            }
            add.append(sh)
        }
        guard !add.isEmpty else {
            status = "All \(feeds.count) shows in that file are already in your list."
            return
        }
        let ok = await edit { root in
            var subs = Library.subs(root)
            let there = Set(subs.values.compactMap { ($0 as? [String: Any]).map { Library.normUrl(J.str($0["feedUrl"])) } })
            for sh in add where subs[J.str(sh["id"])] == nil && !there.contains(Library.normUrl(J.str(sh["feedUrl"]))) {
                subs[J.str(sh["id"])] = sh
            }
            root["subs"] = subs
        }
        if ok { status = "Added \(add.count) new show\(add.count == 1 ? "" : "s") from \(feeds.count) in the file. Star favorites and give them subjects on their pages." }
    }

    private func searchApple(_ q: String) async throws -> [FoundShow] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [URLQueryItem(name: "media", value: "podcast"), URLQueryItem(name: "entity", value: "podcast"),
                        URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "term", value: q)]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((root?["results"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let cid = J.num(r["collectionId"]).map({ Int($0) }) else { return nil }
            let title = J.str(r["collectionName"]).isEmpty ? J.str(r["trackName"]) : J.str(r["collectionName"])
            var art = J.str(r["artworkUrl600"]).isEmpty ? J.str(r["artworkUrl100"]) : J.str(r["artworkUrl600"])
            art = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            return FoundShow(id: "it:\(cid)", itunesId: cid, piId: nil, title: title, author: J.str(r["artistName"]),
                             feedUrl: J.str(r["feedUrl"]), art: art, source: "Apple")
        }
    }

    // MARK: Listening spots and played marks, shared with the web app through Dropbox
    // Same rules as the web app's sync: the newer listening spot wins (posT), and for played
    // marks the latest choice wins (a time in ms, negative when marked not played).

    func position(_ guid: String) -> Double {
        if let p = localPos[guid], (localPosT[guid] ?? 0) >= (remotePosT[guid] ?? 0) { return p }
        if markedPlayed(guid) { return 0 }
        return remotePos[guid] ?? localPos[guid] ?? 0
    }

    func savePosition(_ guid: String, _ t: Double) {
        localPos[guid] = t.rounded()
        localPosT[guid] = Library.nowMsD
        UserDefaults.standard.set(localPos, forKey: "pos")
        UserDefaults.standard.set(localPosT, forKey: "posT")
        markUnsent(guid)
    }

    /// Played: marked played, or counted as played by a skip word.
    func isPlayed(_ guid: String) -> Bool { markedPlayed(guid) || !skipBy(guid).isEmpty }

    func markedPlayed(_ guid: String) -> Bool { latestPlayed(guid) > 0 }

    /// The newer of this iPhone's and Dropbox's mark: positive played, negative not played, 0 none.
    func latestPlayed(_ guid: String) -> Double {
        let l = localPlayed[guid] ?? 0, r = remotePlayed[guid] ?? 0
        return abs(l) >= abs(r) ? l : r
    }

    func setPlayed(_ guid: String, _ on: Bool) {
        let now = Library.nowMsD
        localPlayed[guid] = on ? now : -now
        localPos[guid] = 0
        localPosT[guid] = now
        UserDefaults.standard.set(localPlayed, forKey: "played")
        UserDefaults.standard.set(localPos, forKey: "pos")
        UserDefaults.standard.set(localPosT, forKey: "posT")
        if on { downloads.listened(guid) }
        markUnsent(guid)
        sendProgressSoon(delay: 3)
    }

    /// Notes that this iPhone started playing an episode, for the web app to pick up.
    func notePlaying(_ ep: Episode, showTitle: String, art: String) {
        playingGuid = ep.guid
        localNowT = Library.nowMsD
        UserDefaults.standard.set(localNowT, forKey: "nowT")
        var d: [String: Any] = ["g": ep.guid, "s": ep.showId, "t": ep.title, "u": ep.audioUrl,
                                "a": ep.image.isEmpty ? art : ep.image, "show": showTitle,
                                "len": ep.duration, "ch": ep.chaptersUrl]
        if let date = ep.date { d["d"] = ISO8601DateFormatter().string(from: date) }
        if let f = shows[ep.showId]?.feedUrl, !f.isEmpty { d["f"] = f }
        nowToSend = d
        sendProgressSoon(delay: 5)
    }

    /// The episode last played on another device, when that was after anything played here.
    func episodeFromOtherDevice() -> (Episode, String, String)? {
        guard let n = remoteNow, remoteNowT > localNowT else { return nil }
        let g = J.str(n["g"]), u = J.str(n["u"])
        guard !g.isEmpty, !u.isEmpty else { return nil }
        let date = ISO8601DateFormatter().date(from: J.str(n["d"])) ?? RSSParser.parseDate(J.str(n["d"]))
        let ep = Episode(guid: g, showId: J.str(n["s"]), title: J.str(n["t"]), date: date, audioUrl: u,
                         duration: J.num(n["len"]) ?? 0, summary: "", image: J.str(n["a"]),
                         chaptersUrl: J.str(n["ch"]), transcript: nil)
        return (ep, J.str(n["show"]), J.str(n["a"]))
    }

    /// Taken up here, so it isn't offered again or sent back.
    func tookOtherDevicesEpisode() {
        localNowT = remoteNowT
        UserDefaults.standard.set(localNowT, forKey: "nowT")
    }

    private static var nowMsD: Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    /// Marks many episodes played at once (Mark all played), sent in one save.
    func setPlayed(all guids: [String]) {
        let now = Library.nowMsD
        for g in guids {
            localPlayed[g] = now
            localPos[g] = 0
            localPosT[g] = now
            downloads.listened(g)
            unsent.insert(g)
        }
        UserDefaults.standard.set(localPlayed, forKey: "played")
        UserDefaults.standard.set(localPos, forKey: "pos")
        UserDefaults.standard.set(localPosT, forKey: "posT")
        UserDefaults.standard.set(Array(unsent), forKey: "unsent")
        sendProgressSoon(delay: 1)
    }

    private func markUnsent(_ guid: String) {
        if unsent.insert(guid).inserted { UserDefaults.standard.set(Array(unsent), forKey: "unsent") }
    }

    /// Sends progress a little later, so a burst of changes goes in one save.
    func sendProgressSoon(delay: Double = 20) {
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await sendProgress()
        }
    }

    /// Puts this iPhone's listening spots and played marks into Dropbox's list, where newer.
    /// Only the episodes changed here are touched; everything else in the file stays as it is.
    func sendProgress() async {
        guard !unsent.isEmpty || nowToSend != nil, dropbox.signedIn else { return }
        let guids = unsent
        let nowItem = nowToSend, nowT = localNowT
        let lp = localPos, lt = localPosT, lpl = localPlayed
        let ok = await edit(quiet: true) { root in
            var pos = (root["pos"] as? [String: Any]) ?? [:]
            var posT = (root["posT"] as? [String: Any]) ?? [:]
            var played = (root["played"] as? [String: Any]) ?? [:]
            for g in guids {
                if let mine = lpl[g] {
                    let theirs: Double = (played[g] as? Bool) == true ? 1 : (J.num(played[g]) ?? 0)
                    if abs(mine) > abs(theirs) { played[g] = Int64(mine) }
                }
                if let spot = lp[g], let t = lt[g], t > (J.num(posT[g]) ?? 0) {
                    pos[g] = spot
                    posT[g] = Int64(t)
                }
            }
            root["pos"] = pos
            root["posT"] = posT
            root["played"] = played
            if let nowItem, nowT > (J.num(root["nowT"]) ?? 0) {
                root["now"] = nowItem
                root["nowT"] = Int64(nowT)
            }
        }
        if ok {
            if nowToSend.map({ J.str($0["g"]) }) == nowItem.map({ J.str($0["g"]) }) { nowToSend = nil }
            unsent.subtract(guids)
            UserDefaults.standard.set(Array(unsent), forKey: "unsent")
        }
    }
}
