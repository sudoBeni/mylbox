import Foundation

/// Finds links in a plain-text body so they can be shown short instead of as long tracking URLs.
/// Plain-text parts of newsletters write links as "Label (https://…)" or "<https://…>"; both collapse
/// to just the link. Only http(s) links are recognised, and a link always shows its real host, never a
/// label the sender chose, so what you see is where clicking takes you.
public enum LinkText {
    public enum Segment: Equatable {
        case text(String)
        case link(URL, host: String)
    }

    // A URL in parentheses or angle brackets may be hard-wrapped onto several lines; a bare one may not.
    private static let pattern = try! NSRegularExpression(pattern:
        #"\(\s*(https?://[^\s()<>]+(?:\n[^\s()<>]+)*)\s*\)|<(https?://[^\s<>]+(?:\n[^\s<>]+)*)>|(https?://[^\s<>"]+)"#,
        options: [.caseInsensitive])

    public static func segments(_ text: String) -> [Segment] {
        let ns = text as NSString
        var result: [Segment] = []
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let group = (1...3).first { match.range(at: $0).location != NSNotFound }!
            var raw = ns.substring(with: match.range(at: group)).replacingOccurrences(of: "\n", with: "")
            var end = match.range.location + match.range.length
            if group == 3 {
                // Sentence punctuation after a bare URL belongs to the sentence.
                while let last = raw.last, ".,;:!?)]'\"".contains(last) {
                    raw.removeLast()
                    end -= 1
                }
            }
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty else { continue }
            var before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if group == 1, before.hasSuffix(" ") { before.removeLast() }
            if !before.isEmpty { result.append(.text(before)) }
            result.append(.link(url, host: displayHost(host)))
            cursor = end
        }
        if cursor < ns.length { result.append(.text(ns.substring(from: cursor))) }
        return result
    }

    static func displayHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }
}
