import Foundation

struct Show: Identifiable, Hashable {
    let id: String
    var title: String
    var author: String
    var feedUrl: String
    var art: String
    var cats: [String]
    var itunesId: String
}

struct Episode: Identifiable, Hashable, Codable {
    var id: String { guid }
    let guid: String
    let showId: String
    let title: String
    let date: Date?
    let audioUrl: String
    let duration: Double
    let summary: String
    let image: String
    let chaptersUrl: String
    let transcript: String?
}

struct SubjectItem: Identifiable {
    let episode: Episode
    let show: Show
    var id: String { show.id + "|" + episode.guid }
}

struct Chapter: Identifiable, Hashable {
    var id: Double { start }
    let start: Double
    let title: String
    let img: String
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Reads loosely typed JSON values, since the web app stores ids as numbers or strings.
enum J {
    static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
