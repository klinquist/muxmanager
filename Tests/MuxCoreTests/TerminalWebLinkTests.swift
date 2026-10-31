import XCTest
@testable import MuxCore

final class TerminalWebLinkTests: XCTestCase {
    func testDetectsWebLinksWithUnicodePrefixesQueriesAndPunctuation() {
        let text = "🙂 See (https://example.com/docs?a=1&b=2#part), then http://localhost:3000/test."
        let links = TerminalWebLinks.find(in: text)
        XCTAssertEqual(links.map(\.url.absoluteString), ["https://example.com/docs?a=1&b=2#part", "http://localhost:3000/test"])
        for link in links { XCTAssertEqual((text as NSString).substring(with: link.range), link.text) }
    }
    func testDoesNotTurnNonWebSchemesIntoActions() {
        for string in ["file:///etc/passwd", "mailto:person@example.com", "tel:5551234", "ssh://example.com", "javascript:alert(1)"] {
            XCTAssertFalse(TerminalWebLinks.isWebURL(URL(string: string)!))
        }
        XCTAssertTrue(TerminalWebLinks.find(in: "person@example.com file:///etc/passwd ftp://example.com").isEmpty)
    }
    func testGridLookupUsesFullJoinedURLAndOnlyTheTappedRange() {
        let text = "https://example.com/very/long/path?a=1&b=2"
        let links = TerminalWebLinks.find(in: text)
        let rendered = "前 🙂 " + text + "  ordinary text " + text
        let ns = rendered as NSString
        let first = ns.range(of: text)
        XCTAssertEqual(TerminalWebLinks.url(in: rendered, atUTF16Offset: first.location + 20, links: links)?.absoluteString, text)
        XCTAssertNil(TerminalWebLinks.url(in: rendered, atUTF16Offset: 0, links: links))
        XCTAssertNil(TerminalWebLinks.url(in: rendered, atUTF16Offset: NSMaxRange(first), links: links))
        XCTAssertEqual(TerminalWebLinks.url(in: rendered, atUTF16Offset: ns.length - 1, links: links)?.absoluteString, text)
    }
}
