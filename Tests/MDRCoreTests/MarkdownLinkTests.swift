import XCTest
@testable import MDRCore

final class MarkdownLinkTests: XCTestCase {
    let source = URL(fileURLWithPath: "/specs/project/index.md")

    func testRelativeDocumentsResolveFromSourceAndDecodePathsOnce() throws {
        XCTAssertEqual(try MarkdownLink.resolve("./details/Design%20notes.MD#api-contract", from: source),
                       .document(URL(fileURLWithPath: "/specs/project/details/Design notes.MD"), fragment: "api-contract"))
        XCTAssertEqual(try MarkdownLink.resolve("../Caf%C3%A9.markdown?view=1#d%C3%A9tails", from: source),
                       .document(URL(fileURLWithPath: "/specs/Café.markdown"), fragment: "détails"))
        XCTAssertEqual(try MarkdownLink.resolve("100%25%20ready.md#", from: source),
                       .document(URL(fileURLWithPath: "/specs/project/100% ready.md"), fragment: ""))
        XCTAssertEqual(try MarkdownLink.resolve("encoded%2520name.md", from: source),
                       .document(URL(fileURLWithPath: "/specs/project/encoded%20name.md"), fragment: nil))
    }

    func testCurrentDocumentAnchorsAndExternalLinksStayDistinct() throws {
        XCTAssertEqual(try MarkdownLink.resolve("#d%C3%A9tails", from: nil), .heading("détails"))
        XCTAssertEqual(try MarkdownLink.resolve("#", from: source), .heading(""))
        XCTAssertEqual(try MarkdownLink.resolve("https://example.com/spec.md#read", from: source),
                       .external(URL(string: "https://example.com/spec.md#read")!))
        XCTAssertEqual(try MarkdownLink.resolve("mailto:review@example.com", from: source),
                       .external(URL(string: "mailto:review@example.com")!))
        XCTAssertEqual(try MarkdownLink.resolve("//example.com/read.md", from: source),
                       .external(URL(string: "https://example.com/read.md")!))
    }

    func testUnsupportedDestinationsDoNotLaunchOtherApplications() throws {
        for href in ["", "#%zz", "script.sh", "data:text/plain,hello", "javascript:alert(1)",
                     "someapp://action", "file://server/share/spec.md"] {
            XCTAssertThrowsError(try MarkdownLink.resolve(href, from: source), href)
        }
        XCTAssertThrowsError(try MarkdownLink.resolve("relative.md", from: nil))
    }

    func testAbsoluteAndSymlinkedDocumentsHaveCanonicalWindowIdentity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.md")
        try Data("# Target".utf8).write(to: target)
        let alias = dir.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let expected = MarkdownLink.document(target.resolvingSymlinksInPath(), fragment: "target")
        XCTAssertEqual(try MarkdownLink.resolve(alias.absoluteString + "#target", from: source), expected)
        XCTAssertEqual(try MarkdownLink.resolve(target.path + "#target", from: source), expected)
    }
}
