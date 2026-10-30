import Foundation
import CryptoKit
import Network

/// Episodes saved on the iPhone. Downloads run in a background session, so they
/// keep going when the app is closed, and the new episodes of Favorites download
/// by themselves on Wi-Fi.
@MainActor
final class Downloads: ObservableObject {
    static let sessionId = "n5pre.downloads"

    @Published private(set) var files: [String: String] = [:]      // episode guid -> file name
    @Published private(set) var progress: [String: Double] = [:]   // downloads under way, 0...1
    @Published private(set) var failed: [String: String] = [:]
    @Published var autoFavorites: Bool {
        didSet { UserDefaults.standard.set(autoFavorites, forKey: "dl.auto") }
    }
    @Published var deleteAfter: Bool {
        didSet { UserDefaults.standard.set(deleteAfter, forKey: "dl.deleteAfter") }
    }

    /// The episode the player is using from a file, which must not be deleted mid-play.
    var inUse: String?
    /// Episodes whose files a transcript is being made from.
    var protected: Set<String> = []
    /// Told when a download finishes, so a transcript can be made for it.
    var onFinished: ((String) -> Void)?
    private var skipped: Set<String>
    private var session: URLSession!
    private let delegate = DownloadDelegate()
    private let monitor = NWPathMonitor()
    private var onWifi = false

    init() {
        let d = UserDefaults.standard
        autoFavorites = d.object(forKey: "dl.auto") as? Bool ?? true
        deleteAfter = d.object(forKey: "dl.deleteAfter") as? Bool ?? true
        skipped = Set(d.stringArray(forKey: "dl.skipped") ?? [])
        let saved = d.dictionary(forKey: "dl.files") as? [String: String] ?? [:]
        files = saved.filter { FileManager.default.fileExists(atPath: Downloads.folder.appendingPathComponent($0.value).path) }

        delegate.owner = self
        let config = URLSessionConfiguration.background(withIdentifier: Downloads.sessionId)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        session.getAllTasks { tasks in
            let guids = tasks.compactMap { $0.state == .running ? $0.taskDescription : nil }
            Task { @MainActor in
                for g in guids where self.progress[g] == nil { self.progress[g] = 0 }
            }
        }

        monitor.pathUpdateHandler = { path in
            let wifi = path.status == .satisfied && !path.isExpensive
            Task { @MainActor in self.onWifi = wifi }
        }
        monitor.start(queue: DispatchQueue(label: "n5pre.net"))
    }

    nonisolated static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Episodes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            var u = dir
            try? u.setResourceValues(v)
        }
        return dir
    }

    // MARK: Asking

    func localURL(_ guid: String) -> URL? {
        guard let name = files[guid] else { return nil }
        let url = Downloads.folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isDownloaded(_ guid: String) -> Bool { files[guid] != nil }

    var bytesUsed: Int64 {
        files.values.reduce(0) { sum, name in
            let path = Downloads.folder.appendingPathComponent(name).path
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    // MARK: Doing

    func start(_ ep: Episode) {
        guard files[ep.guid] == nil, progress[ep.guid] == nil, let url = URL(string: ep.audioUrl) else { return }
        let task = session.downloadTask(with: url)
        task.taskDescription = ep.guid
        progress[ep.guid] = 0
        failed[ep.guid] = nil
        skipped.remove(ep.guid)
        saveSkipped()
        task.resume()
    }

    /// Called for a favorite's newest unplayed episode after its list loads.
    func autoStart(_ ep: Episode) {
        guard autoFavorites, onWifi, !skipped.contains(ep.guid), failed[ep.guid] == nil else { return }
        if let d = ep.date, Date().timeIntervalSince(d) > 30 * 86400 { return }
        start(ep)
    }

    func cancel(_ guid: String) {
        session.getAllTasks { tasks in
            for t in tasks where t.taskDescription == guid { t.cancel() }
        }
        progress[guid] = nil
        skipped.insert(guid)
        saveSkipped()
    }

    /// Removes the file. A download the user removes isn't fetched again by itself.
    func remove(_ guid: String, byUser: Bool = true) {
        guard inUse != guid, !protected.contains(guid), let name = files[guid] else { return }
        try? FileManager.default.removeItem(at: Downloads.folder.appendingPathComponent(name))
        files[guid] = nil
        saveFiles()
        if byUser {
            skipped.insert(guid)
            saveSkipped()
        }
    }

    /// After an episode is finished or marked played.
    func listened(_ guid: String) {
        if deleteAfter { remove(guid, byUser: false) }
    }

    func removeAll() {
        for g in Array(files.keys) where g != inUse { remove(g, byUser: false) }
    }

    // MARK: From the delegate

    fileprivate func finished(_ guid: String, name: String) {
        progress[guid] = nil
        files[guid] = name
        saveFiles()
        onFinished?(guid)
    }

    fileprivate func progressed(_ guid: String, _ p: Double) {
        if files[guid] == nil { progress[guid] = p }
    }

    fileprivate func ended(_ guid: String, error: String?) {
        progress[guid] = nil
        if let error { failed[guid] = error }
    }

    private func saveFiles() { UserDefaults.standard.set(files, forKey: "dl.files") }
    private func saveSkipped() { UserDefaults.standard.set(Array(skipped), forKey: "dl.skipped") }

    nonisolated static func fileName(guid: String, mime: String?, url: URL?) -> String {
        let hash = SHA256.hash(data: Data(guid.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        var ext = url?.pathExtension.lowercased() ?? ""
        let m = (mime ?? "").lowercased()
        if m.contains("mpeg") || m.contains("mp3") { ext = "mp3" }
        else if m.contains("m4a") || m.contains("audio/mp4") || m.contains("aac") { ext = "m4a" }
        else if m.contains("video/mp4") { ext = "mp4" }
        if !["mp3", "m4a", "mp4", "aac", "wav", "m4v", "mov", "ogg", "opus"].contains(ext) { ext = "mp3" }
        return "\(hash).\(ext)"
    }
}

/// Runs on the session's own queue. The finished file has to be moved before
/// the callback returns, so that happens here, then the app is told.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var owner: Downloads?
    private var lastSent: [String: Double] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let guid = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { return }
        let name = Downloads.fileName(guid: guid, mime: downloadTask.response?.mimeType,
                                      url: downloadTask.originalRequest?.url)
        let dest = Downloads.folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            return
        }
        let o = owner
        Task { @MainActor in o?.finished(guid, name: name) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let guid = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if p - (lastSent[guid] ?? -1) < 0.02 { return }
        lastSent[guid] = p
        let o = owner
        Task { @MainActor in o?.progressed(guid, p) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let guid = task.taskDescription else { return }
        lastSent[guid] = nil
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 200
        var message: String?
        if let error = error as NSError? {
            message = error.code == NSURLErrorCancelled ? nil : error.localizedDescription
        } else if !(200..<300).contains(status) {
            message = "The show's server answered \(status)."
        }
        let o = owner
        Task { @MainActor in o?.ended(guid, error: message) }
    }
}
