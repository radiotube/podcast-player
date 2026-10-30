import AVFoundation
import MediaPlayer
import UIKit

struct NowItem: Codable {
    var episode: Episode
    var showTitle: String
    var showArt: String
}

/// Playback with background audio, lock screen controls and Podcasting 2.0 chapters.
@MainActor
final class Player: ObservableObject {
    @Published private(set) var now: NowItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Double = 1
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var artwork: UIImage?
    @Published var showFull = false
    @Published var errorText = ""

    private let player = AVPlayer()
    private let library: Library
    private var timeObserver: Any?
    private var statusObs: NSKeyValueObservation?
    private var controlObs: NSKeyValueObservation?
    private var pendingSeek: Double?
    private var loaded = false
    private var lastSave = Date.distantPast
    private var artKey = ""
    private var artCache: [String: UIImage] = [:]
    private var lastChapterStart: Double?

    var skipBack: Double { library.skipBack }
    var skipFwd: Double { library.skipFwd }

    init(library: Library) {
        self.library = library
        let saved = UserDefaults.standard.double(forKey: "speed")
        rate = saved > 0 ? saved : library.speed
        if let data = UserDefaults.standard.data(forKey: "now"),
           let item = try? JSONDecoder().decode(NowItem.self, from: data) {
            now = item
            time = library.position(item.episode.guid)
            duration = item.episode.duration
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        setupRemote()
        observe()
        updateChapterArt()
        if let item = now {
            Task { await self.loadChapters(item.episode) }
        }
    }

    // MARK: Controls

    func play(_ ep: Episode, show: Show) {
        if now?.episode.guid == ep.guid {
            if !isPlaying { play() }
            return
        }
        savePosition()
        now = NowItem(episode: ep, showTitle: show.title, showArt: show.art)
        if let data = try? JSONEncoder().encode(now) { UserDefaults.standard.set(data, forKey: "now") }
        chapters = []
        artwork = nil
        artKey = ""
        lastChapterStart = nil
        errorText = ""
        duration = ep.duration
        let start = library.position(ep.guid)
        time = (duration > 0 && start > duration - 10) ? 0 : start
        loaded = false
        play()
    }

    func play() {
        guard let item = now else { return }
        if !isPlaying { library.notePlaying(item.episode, showTitle: item.showTitle, art: item.showArt) }
        if !loaded { loadItem() }
        try? AVAudioSession.sharedInstance().setActive(true)
        let c = MPRemoteCommandCenter.shared()
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBack)]
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skipFwd)]
        player.defaultRate = Float(rate)
        player.play()
    }

    /// Loads (without playing) the episode last played on another device, when nothing is playing here.
    func takeOtherDevicesEpisode() {
        guard !isPlaying, let other = library.episodeFromOtherDevice() else { return }
        let (ep, showTitle, art) = other
        library.tookOtherDevicesEpisode()
        if now?.episode.guid == ep.guid {
            let t = library.position(ep.guid)
            if abs(t - time) > 3 {
                if loaded { seek(t) } else { time = t }
            }
            return
        }
        savePosition()
        now = NowItem(episode: ep, showTitle: showTitle, showArt: art)
        if let data = try? JSONEncoder().encode(now) { UserDefaults.standard.set(data, forKey: "now") }
        chapters = []
        artwork = nil
        artKey = ""
        lastChapterStart = nil
        errorText = ""
        duration = ep.duration
        time = library.position(ep.guid)
        loaded = false
        player.replaceCurrentItem(with: nil)
        library.downloads.inUse = nil
        updateNowPlaying()
        Task { await loadChapters(ep) }
    }

    func pause() {
        player.pause()
        savePosition()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seek(_ t: Double) {
        let end = duration > 0 ? duration - 1 : t
        let target = max(0, min(t, end))
        time = target
        guard loaded else {
            if let n = now, target > 5 { library.savePosition(n.episode.guid, target) }
            updateChapterArt()
            return
        }
        if pendingSeek != nil {
            pendingSeek = target
            return
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
        updateChapterArt()
        updateNowPlaying()
    }

    func skip(_ d: Double) { seek(time + d) }

    func setRate(_ r: Double) {
        rate = r
        UserDefaults.standard.set(r, forKey: "speed")
        player.defaultRate = Float(r)
        if isPlaying { player.rate = Float(r) }
        updateNowPlaying()
    }

    // MARK: Chapters

    var currentChapterIndex: Int? { chapters.lastIndex { $0.start <= time + 0.5 } }
    var currentChapter: Chapter? { currentChapterIndex.map { chapters[$0] } }

    func nextChapter() {
        if let i = currentChapterIndex {
            if i + 1 < chapters.count { seek(chapters[i + 1].start) }
        } else if let first = chapters.first {
            seek(first.start)
        }
    }

    func previousChapter() {
        guard let i = currentChapterIndex else { return }
        if i == 0 || time - chapters[i].start > 3 { seek(chapters[i].start) } else { seek(chapters[i - 1].start) }
    }

    private func loadChapters(_ ep: Episode) async {
        guard !ep.chaptersUrl.isEmpty else { return }
        guard let list = try? await Feeds.chapters(ep.chaptersUrl) else { return }
        guard now?.episode.guid == ep.guid else { return }
        chapters = list
        updateChapterArt()
    }

    // MARK: Internals

    private func loadItem() {
        guard let ep = now?.episode else { return }
        let local = library.downloads.localURL(ep.guid)
        guard let url = local ?? URL(string: ep.audioUrl) else { return }
        library.downloads.inUse = local == nil ? nil : ep.guid
        let item = AVPlayerItem(url: url)
        pendingSeek = time > 5 ? time : nil
        statusObs = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.itemStatusChanged() }
        }
        player.replaceCurrentItem(with: item)
        loaded = true
        if chapters.isEmpty {
            Task { await self.loadChapters(ep) }
        }
        updateChapterArt()
        updateNowPlaying()
    }

    private func itemStatusChanged() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            let d = item.duration.seconds
            if d.isFinite && d > 0 { duration = d }
            if let s = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            updateNowPlaying()
        case .failed:
            pendingSeek = nil
            errorText = item.error?.localizedDescription ?? "This episode won't play."
        default:
            break
        }
    }

    private func observe() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] t in
            let s = t.seconds
            MainActor.assumeIsolated { self?.tick(s) }
        }
        controlObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.setPlaying(playing) }
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let id = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated { self?.itemEnded(id) }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            let opts = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                if type == .began { self?.savePosition() }
                if type == .ended && opts.contains(.shouldResume) { self?.play() }
            }
        }
    }

    private func tick(_ s: Double) {
        guard loaded, pendingSeek == nil, s.isFinite else { return }
        time = s
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, d != duration { duration = d }
        updateChapterArt()
        if isPlaying && Date().timeIntervalSince(lastSave) > 10 { savePosition() }
    }

    private func setPlaying(_ p: Bool) {
        guard p != isPlaying else { return }
        isPlaying = p
        if !p {
            savePosition()
            library.sendProgressSoon()
        }
        updateNowPlaying()
    }

    private func itemEnded(_ id: ObjectIdentifier?) {
        guard let item = player.currentItem, id == ObjectIdentifier(item), let n = now else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        loaded = false
        library.downloads.inUse = nil
        time = 0
        library.setPlayed(n.episode.guid, true)
        updateNowPlaying()
    }

    func savePosition() {
        guard let n = now, loaded, pendingSeek == nil else { return }
        let t = player.currentTime().seconds
        guard t.isFinite, t > 5 else { return }
        library.savePosition(n.episode.guid, t)
        lastSave = Date()
    }

    private func updateChapterArt() {
        guard let n = now else { return }
        let ch = currentChapter
        let key = [ch?.img ?? "", n.episode.image, n.showArt].first { !$0.isEmpty } ?? ""
        if key != artKey {
            artKey = key
            if key.isEmpty {
                artwork = nil
            } else if let img = artCache[key] {
                artwork = img
            } else if let url = URL(string: key) {
                Task { [weak self] in
                    guard let result = try? await URLSession.shared.data(from: url),
                          let img = UIImage(data: result.0), let self else { return }
                    self.artCache[key] = img
                    if self.artKey == key {
                        self.artwork = img
                        self.updateNowPlaying()
                    }
                }
            }
            updateNowPlaying()
        } else if ch?.start != lastChapterStart {
            updateNowPlaying()
        }
        lastChapterStart = ch?.start
    }

    private func updateNowPlaying() {
        guard let n = now else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [:]
        if let ch = currentChapter, !ch.title.isEmpty {
            info[MPMediaItemPropertyTitle] = ch.title
            info[MPMediaItemPropertyAlbumTitle] = n.episode.title
        } else {
            info[MPMediaItemPropertyTitle] = n.episode.title
            info[MPMediaItemPropertyAlbumTitle] = n.showTitle
        }
        info[MPMediaItemPropertyArtist] = n.showTitle
        let t = loaded && pendingSeek == nil ? player.currentTime().seconds : time
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t.isFinite ? t : time
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rate
        if let img = artwork { info[MPMediaItemPropertyArtwork] = Player.makeArtwork(img) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    nonisolated private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBack)]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skip(-self.skipBack)
            }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skipFwd)]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skip(self.skipFwd)
            }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(t) }
            return .success
        }
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
    }
}
