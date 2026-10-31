import Foundation

public struct TerminalWebLink: Equatable, Sendable {
    public let range: NSRange
    public let text: String
    public let url: URL
}

public enum TerminalWebLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    public static func isWebURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }
    public static func find(in text: String) -> [TerminalWebLink] {
        let string = text as NSString
        return (detector?.matches(in: text, range: NSRange(location: 0, length: string.length)) ?? []).compactMap { match in
            guard let url = match.url, isWebURL(url) else { return nil }
            return TerminalWebLink(range: match.range, text: string.substring(with: match.range), url: url)
        }
    }
    /// Resolve a tapped terminal cell against complete links from tmux's joined
    /// capture. The rendered grid may split a URL across physical rows.
    public static func url(in rendered: String, atUTF16Offset offset: Int, links: [TerminalWebLink]) -> URL? {
        let string = rendered as NSString
        guard offset >= 0, offset < string.length else { return nil }
        var best: (length: Int, url: URL)?
        for link in links where !link.text.isEmpty {
            var start = 0
            while start < string.length {
                let range = string.range(of: link.text, range: NSRange(location: start, length: string.length - start))
                if range.location == NSNotFound { break }
                if NSLocationInRange(offset, range), range.length > (best?.length ?? 0) { best = (range.length, link.url) }
                start = NSMaxRange(range)
            }
        }
        return best?.url
    }
}
