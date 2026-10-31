import Foundation

/// Reads the feeds out of an OPML file exported by another podcast app.
final class OPMLReader: NSObject, XMLParserDelegate {
    private var out: [(url: String, title: String)] = []

    static func feeds(_ data: Data) -> [(url: String, title: String)] {
        let r = OPMLReader()
        let p = XMLParser(data: data)
        p.delegate = r
        p.parse()
        return r.out
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        guard elementName.lowercased() == "outline" else { return }
        let url = a["xmlUrl"] ?? a["xmlurl"] ?? a["XMLURL"] ?? ""
        if !url.isEmpty { out.append((url, a["title"] ?? a["text"] ?? "")) }
    }
}
