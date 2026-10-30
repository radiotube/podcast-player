import Foundation

/// Episode lists straight from each show's RSS feed, with a copy kept on the phone.
enum Feeds {
    static func fetch(_ address: String, showId: String) async throws -> [Episode] {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)) else {
            throw AppError("The feed address isn't valid.")
        }
        var req = URLRequest(url: url)
        req.setValue("N5PREcaster/0.1 (iPhone)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError("The feed answered with error \(http.statusCode).")
        }
        let parser = RSSParser(showId: showId)
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        if parser.items.isEmpty {
            throw AppError("No episodes found in the feed.")
        }
        return parser.items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func lookupFeed(itunesId: String) async throws -> String {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(itunesId)") else {
            throw AppError("Bad Apple id.")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = root?["results"] as? [[String: Any]] ?? []
        let feed = results.map { J.str($0["feedUrl"]) }.first { !$0.isEmpty }
        guard let feed else { throw AppError("Apple has no feed address for this show.") }
        return feed
    }

    private static func cacheFile(_ showId: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = showId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "show"
        return dir.appendingPathComponent("eps-\(name).json")
    }

    static func cached(_ showId: String) -> [Episode]? {
        guard let data = try? Data(contentsOf: cacheFile(showId)) else { return nil }
        return try? JSONDecoder().decode([Episode].self, from: data)
    }

    static func store(_ list: [Episode], for showId: String) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: cacheFile(showId), options: .atomic)
        }
    }

    static func chapters(_ address: String) async throws -> [Chapter] {
        guard let url = URL(string: address) else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let raw = root?["chapters"] as? [[String: Any]] ?? []
        return raw.compactMap { c -> Chapter? in
            if let toc = c["toc"] as? Bool, toc == false { return nil }
            guard let start = J.num(c["startTime"]) else { return nil }
            return Chapter(start: start, title: J.str(c["title"]), img: J.str(c["img"]))
        }.sorted { $0.start < $1.start }
    }
}

final class RSSParser: NSObject, XMLParserDelegate {
    private let showId: String
    var items: [Episode] = []
    private var inItem = false
    private var text = ""
    private var fields: [String: String] = [:]
    private var enclosure = ""
    private var chaptersUrl = ""
    private var itemImage = ""
    private var transcriptUrl = ""

    init(showId: String) { self.showId = showId }

    /// A name with a fixed prefix for the namespaces we care about, whatever prefix the feed uses.
    private func key(_ local: String, _ ns: String?) -> String {
        let n = (ns ?? "").lowercased()
        if n.isEmpty { return local }
        if n.contains("itunes") { return "itunes:" + local }
        if n.contains("podcastindex") { return "podcast:" + local }
        if n.contains("purl.org/rss/1.0/modules/content") { return "content:" + local }
        return "x:" + local
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let k = key(elementName, namespaceURI)
        text = ""
        switch k {
        case "item":
            inItem = true
            fields = [:]
            enclosure = ""
            chaptersUrl = ""
            itemImage = ""
            transcriptUrl = ""
        case "enclosure":
            if inItem && enclosure.isEmpty { enclosure = attributeDict["url"] ?? "" }
        case "podcast:chapters":
            if inItem { chaptersUrl = attributeDict["url"] ?? "" }
        case "itunes:image":
            if inItem { itemImage = attributeDict["href"] ?? "" }
        case "podcast:transcript":
            if inItem && transcriptUrl.isEmpty { transcriptUrl = attributeDict["url"] ?? "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let k = key(elementName, namespaceURI)
        if inItem {
            if k == "item" {
                finishItem()
                inItem = false
            } else if ["title", "guid", "pubDate", "description", "itunes:duration", "itunes:summary"].contains(k) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if (fields[k] ?? "").isEmpty { fields[k] = t }
            }
        }
        text = ""
    }

    private func finishItem() {
        guard !enclosure.isEmpty else { return }
        let guid = (fields["guid"] ?? "").isEmpty ? enclosure : fields["guid"]!
        let desc = (fields["description"] ?? "").isEmpty ? (fields["itunes:summary"] ?? "") : fields["description"]!
        items.append(Episode(guid: guid,
                             showId: showId,
                             title: (fields["title"] ?? "").isEmpty ? "Episode" : fields["title"]!,
                             date: RSSParser.parseDate(fields["pubDate"] ?? ""),
                             audioUrl: enclosure,
                             duration: RSSParser.parseDuration(fields["itunes:duration"] ?? ""),
                             summary: RSSParser.plain(desc),
                             image: itemImage,
                             chaptersUrl: chaptersUrl,
                             transcript: transcriptUrl.isEmpty ? nil : transcriptUrl))
    }

    static func parseDuration(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static let dateFormatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z",
         "EEE, d MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy"].map { f in
            let d = DateFormatter()
            d.locale = Locale(identifier: "en_US_POSIX")
            d.dateFormat = f
            return d
        }
    }()

    static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        for f in dateFormatters {
            if let d = f.date(from: t) { return d }
        }
        return ISO8601DateFormatter().date(from: t)
    }

    /// The show notes as plain text, keeping paragraph breaks.
    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</li>|</h[1-6]>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#8217;": "'", "&#8220;": "\"", "&#8221;": "\""]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "[ \\t\\r\\f]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ?\n ?", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(s.prefix(6000))
    }
}
