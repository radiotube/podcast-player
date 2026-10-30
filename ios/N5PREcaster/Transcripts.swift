import Foundation
import CryptoKit
import AVFoundation
import Speech

/// One timed line: start, end, text. Stored as [s, e, "text"], the web app's format.
struct Seg: Codable, Hashable {
    var s: Double
    var e: Double
    var b: String

    init(s: Double, e: Double, b: String) {
        self.s = s
        self.e = e
        self.b = b
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        s = try c.decodeNil() ? 0 : c.decode(Double.self)
        e = try c.decodeNil() ? s : c.decode(Double.self)
        b = try c.decodeNil() ? "" : c.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(s)
        try c.encode(e)
        try c.encode(b)
    }
}

/// The same file the web app writes to Dropbox /transcripts/<key>.json.
struct TranscriptFile: Codable {
    var v: Int?
    var g: String?
    var sid: String?
    var t: String?
    var show: String?
    var made: String?
    var by: String?
    var dur: Double?
    var segs: [Seg]
    var src: String?
    var size: Int?
}

/// Makes transcripts on the iPhone for downloaded episodes that have none, with Apple's
/// on-device speech recognition, and shares them with the web app through Dropbox.
@MainActor
final class Transcripts: ObservableObject {
    @Published var auto: Bool {
        didSet { UserDefaults.standard.set(auto, forKey: "tx.auto") }
    }
    @Published private(set) var working: String?
    @Published private(set) var failed: [String: String] = [:]
    @Published private(set) var current: TranscriptFile?
    @Published private(set) var currentGuid = ""
    @Published private(set) var loadingCurrent = false
    @Published private(set) var note = ""

    private var queue: [Episode] = []
    private var running = false
    private var flushing = false
    private var pending: Set<String>
    private var checked: [String: Date] = [:]
    private let library: Library

    init(library: Library) {
        self.library = library
        auto = UserDefaults.standard.object(forKey: "tx.auto") as? Bool ?? true
        pending = Set(UserDefaults.standard.stringArray(forKey: "tx.pending") ?? [])
        library.downloads.onFinished = { [weak self] _ in self?.scan() }
    }

    nonisolated static func key(sid: String, guid: String) -> String {
        SHA256.hash(data: Data((sid + "|" + guid).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func localData(_ key: String) -> Data? {
        try? Data(contentsOf: Transcripts.folder.appendingPathComponent("\(key).json"))
    }

    private func localFile(_ key: String) -> TranscriptFile? {
        guard let data = localData(key) else { return nil }
        return try? JSONDecoder().decode(TranscriptFile.self, from: data)
    }

    private func saveLocal(_ key: String, _ data: Data) {
        try? data.write(to: Transcripts.folder.appendingPathComponent("\(key).json"), options: .atomic)
    }

    func isQueued(_ guid: String) -> Bool { queue.contains { $0.guid == guid } }

    /// On the phone first, then in Dropbox (made by the web app or another device).
    func find(_ ep: Episode) async -> TranscriptFile? {
        let k = Transcripts.key(sid: ep.showId, guid: ep.guid)
        if let f = localFile(k) { return f }
        guard library.dropbox.signedIn else { return nil }
        if let at = checked[k], Date().timeIntervalSince(at) < 600 { return nil }
        checked[k] = Date()
        guard let data = try? await library.dropbox.downloadFile("/transcripts/\(k).json"),
              let f = try? JSONDecoder().decode(TranscriptFile.self, from: data), !f.segs.isEmpty else { return nil }
        saveLocal(k, data)
        return f
    }

    func loadCurrent(_ ep: Episode?) async {
        guard let ep else {
            current = nil
            currentGuid = ""
            return
        }
        if currentGuid == ep.guid && current != nil { return }
        currentGuid = ep.guid
        current = nil
        loadingCurrent = true
        let f = await find(ep)
        loadingCurrent = false
        if currentGuid == ep.guid { current = f }
    }

    /// Make this one next.
    func make(_ ep: Episode) {
        queue.removeAll { $0.guid == ep.guid }
        queue.insert(ep, at: 0)
        failed[ep.guid] = nil
        runQueue()
    }

    /// Queues every downloaded episode with no transcript, and sends finished ones to Dropbox.
    func scan() {
        flushPending()
        guard auto else { return }
        for list in library.episodes.values {
            for ep in list where library.downloads.isDownloaded(ep.guid) && (ep.transcript ?? "").isEmpty {
                if failed[ep.guid] != nil || working == ep.guid || isQueued(ep.guid) { continue }
                if localData(Transcripts.key(sid: ep.showId, guid: ep.guid)) != nil { continue }
                queue.append(ep)
            }
        }
        runQueue()
    }

    private func runQueue() {
        guard !running else { return }
        running = true
        Task {
            while !queue.isEmpty {
                let ep = queue.removeFirst()
                await process(ep)
            }
            running = false
        }
    }

    private func process(_ ep: Episode) async {
        let k = Transcripts.key(sid: ep.showId, guid: ep.guid)
        if localData(k) != nil { return }
        if let f = await find(ep) {
            if currentGuid == ep.guid { current = f }
            return
        }
        guard let file = library.downloads.localURL(ep.guid) else { return }
        guard #available(iOS 26.0, *) else {
            failed[ep.guid] = "Making transcripts needs iOS 26 or later."
            return
        }
        working = ep.guid
        library.downloads.protected.insert(ep.guid)
        defer {
            working = nil
            library.downloads.protected.remove(ep.guid)
        }
        do {
            let made = try await AppleSpeech.transcribe(file: file)
            guard !made.segs.isEmpty else { throw AppError("No speech was found in this episode.") }
            let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
            let f = TranscriptFile(v: 1, g: ep.guid, sid: ep.showId, t: ep.title,
                                   show: library.shows[ep.showId]?.title ?? "",
                                   made: ISO8601DateFormatter().string(from: Date()),
                                   by: "apple-speech", dur: made.duration.rounded(),
                                   segs: made.segs, src: ep.audioUrl, size: size)
            let data = try JSONEncoder().encode(f)
            saveLocal(k, data)
            if currentGuid == ep.guid { current = f }
            pending.insert(k)
            savePending()
            await upload(k)
        } catch {
            failed[ep.guid] = error.localizedDescription
        }
    }

    private func upload(_ key: String) async {
        guard library.dropbox.signedIn, let data = localData(key) else { return }
        do {
            try await library.dropbox.uploadTranscript(key: key, data: data)
            pending.remove(key)
            savePending()
            note = ""
        } catch {
            note = error.localizedDescription
        }
    }

    private func flushPending() {
        guard !flushing, !pending.isEmpty, library.dropbox.signedIn else { return }
        flushing = true
        Task {
            for k in Array(pending) { await upload(k) }
            flushing = false
        }
    }

    private func savePending() {
        UserDefaults.standard.set(Array(pending), forKey: "tx.pending")
    }
}

/// Apple's on-device speech recognition (SpeechAnalyzer, iOS 26). Free, and nothing leaves the phone.
@available(iOS 26.0, *)
enum AppleSpeech {
    static func transcribe(file: URL) async throws -> (segs: [Seg], duration: Double) {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audio = try AVAudioFile(forReading: file)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate

        let collect = Task { () throws -> [Seg] in
            var out: [Seg] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                let s = result.range.start.seconds
                let e = result.range.end.seconds
                let start = s.isFinite ? (s * 100).rounded() / 100 : 0
                let end = e.isFinite ? (max(s, e) * 100).rounded() / 100 : start
                out.append(Seg(s: start, e: end, b: text))
            }
            return out
        }

        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let segs = try await collect.value
        return (segs, duration)
    }
}
