import XCTest
@testable import MDRCore

final class ReviewTests: XCTestCase {
    func snapshot(_ text: String) -> SourceSnapshot { SourceSnapshot(text: text, modifiedAt: "2026-09-23T12:34:56.123Z") }
    func comment(_ source: SourceSnapshot, quote: String, body: String = "Please clarify.") throws -> Feedback {
        let r = (source.text as NSString).range(of: quote)
        return try Feedback(kind: .comment, author: "Maya", body: body, snapshot: source, start: r.location, end: r.location + r.length)
    }
    func testPortableRoundTripPreservesExactSourceAndProvenance() throws {
        let source = snapshot("# Café 🪴\r\n\r\nA **good** idea.\r\n```mermaid\r\ngraph LR\r\n A-->B\r\n```\r\n")
        var review = Review(sourcePath: "/spec.md", snapshot: source)
        review.feedback = [try comment(source, quote: "**good**", body: "Try </script> --> and {~~a~>b~~} instead."),
                           try Feedback(kind: .suggestion, author: "Maya", body: "wonderful", snapshot: source, start: 15, end: 15)]
        let encoded = try ReviewFile.encode(review)
        XCTAssertEqual(try ReviewFile.decode(encoded), review)
        XCTAssertEqual(try ReviewFile.decode(encoded).source.data(using: .utf8), source.text.data(using: .utf8))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("mdr:review v2"))
    }
    func testRebaseAfterInsertionKeepsOriginalRevision() throws {
        let source = snapshot("# Spec\n\nThe reader should be calm and fast.\n\n## Notes\nDetails.")
        var review = Review(sourcePath: "/spec.md", snapshot: source)
        let original = try comment(source, quote: "calm and fast")
        review.feedback = [original]
        let next = snapshot("Intro.\n\n" + source.text)
        XCTAssertEqual(review.rebase(to: next), 0)
        XCTAssertEqual(review.feedback[0].anchor.start, original.anchor.start + 8)
        XCTAssertEqual(review.feedback[0].createdAgainst, original.createdAgainst)
        XCTAssertEqual(review.feedback[0].originalAnchor, original.originalAnchor)
        XCTAssertEqual(try ReviewFile.decode(ReviewFile.encode(review)), review)
    }
    func testChangedSelectionBecomesConflictWithoutDroppingFeedback() throws {
        let source = snapshot("# Spec\n\nKeep the source untouched.")
        var review = Review(sourcePath: "/spec.md", snapshot: source)
        review.feedback = [try comment(source, quote: "source untouched")]
        XCTAssertEqual(review.rebase(to: snapshot("# Spec\n\nKeep the source safe.")), 1)
        XCTAssertEqual(review.feedback[0].state, .conflict)
        XCTAssertEqual(review.feedback[0].originalAnchor.exact, "source untouched")
        XCTAssertEqual(try ReviewFile.decode(ReviewFile.encode(review)), review)
    }
    func testAmbiguousRepeatedTextIsNeverGuessed() throws {
        let source = snapshot(String(repeating: "x", count: 80) + "target" + String(repeating: "y", count: 80))
        let item = try comment(source, quote: "target")
        XCTAssertNil(Review.locate(item.anchor, in: source.text + "\n" + source.text))
    }
    func testSourceAndSidecarAreSeparateAndStaleWritesAreRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("spec.md")
        let source = snapshot("# A spec\n\nSome ideas.\n")
        try Data(source.text.utf8).write(to: sourceURL)
        var review = Review(sourcePath: sourceURL.path, snapshot: source)
        review.feedback = [try comment(source, quote: "Some ideas")]
        let sidecar = ReviewFile.url(for: sourceURL)
        let hash = try ReviewFile.save(review, to: sidecar, expectedDiskHash: nil)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data(source.text.utf8))
        XCTAssertEqual(try ReviewFile.save(review, to: sidecar, expectedDiskHash: hash), hash)
        try Data("external edit".utf8).write(to: sidecar)
        XCTAssertThrowsError(try ReviewFile.save(review, to: sidecar, expectedDiskHash: hash))
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "external edit")
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data(source.text.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".spec.feedback.md.mdr-lock").path))
    }
    func testMalformedSourceIsRejectedAndInlineFeedbackCanBeEdited() throws {
        let source = snapshot("# Spec\nOriginal text.")
        var review = Review(sourcePath: "/spec.md", snapshot: source)
        review.feedback = [try comment(source, quote: "Original")]
        let encoded = String(decoding: try ReviewFile.encode(review), as: UTF8.self)
        XCTAssertThrowsError(try ReviewFile.decode(Data("unrelated file".utf8)))
        XCTAssertThrowsError(try ReviewFile.decode(Data((encoded + "external text").utf8)))
        let edited = try ReviewFile.decode(Data(encoded.replacingOccurrences(of: "Please clarify.", with: "Changed").utf8))
        XCTAssertEqual(edited.feedback[0].body, "Changed")
        XCTAssertEqual(edited.source, source.text)
    }
    func testSuggestionCanDeleteAndOverlappingNotesRoundTrip() throws {
        let source = snapshot("# Spec\n\nA longer sentence here.")
        var review = Review(sourcePath: "/spec.md", snapshot: source)
        review.feedback = [try comment(source, quote: "longer sentence"), try comment(source, quote: "sentence")]
        let range = (source.text as NSString).range(of: "A longer sentence here.")
        review.feedback.append(try Feedback(kind: .suggestion, author: "Maya", body: "", snapshot: source, start: range.location, end: range.location + range.length))
        XCTAssertEqual(try ReviewFile.decode(ReviewFile.encode(review)), review)
    }
    func testDraftCreatedBeforeExternalEditRebasesOrConflicts() throws {
        let old = snapshot("# Spec\n\nReview this paragraph.")
        let next = snapshot("# Spec\n\nThe agent rewrote it.")
        var review = Review(sourcePath: "/spec.md", snapshot: next)
        let item = try comment(old, quote: "this paragraph")
        review.add(item, against: next)
        XCTAssertEqual(review.feedback[0].state, .conflict)
        XCTAssertEqual(review.feedback[0].createdAgainst.sha256, old.revision.sha256)
    }
    func testUnicodeAndCRLFAreHashedWithoutNormalization() throws {
        let a = snapshot("é 🐈\r\n")
        let b = snapshot("é 🐈\n")
        XCTAssertNotEqual(a.revision.sha256, b.revision.sha256)
        let range = (a.text as NSString).range(of: "🐈")
        let anchor = try TextAnchor(text: a.text, start: range.location, end: range.location + range.length)
        XCTAssertEqual(anchor.exact, "🐈")
        XCTAssertThrowsError(try TextAnchor(text: a.text, start: range.location, end: range.location + 1))
    }
    func testCrashedWriterLockRecoversButLiveWriterLockIsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("spec.feedback.md")
        let lock = dir.appendingPathComponent(".spec.feedback.md.mdr-lock")
        let review = Review(sourcePath: "/spec.md", snapshot: snapshot("A spec."))
        try Data("2147483647".utf8).write(to: lock)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: lock.path)
        let hash = try ReviewFile.save(review, to: destination, expectedDiskHash: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: lock)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: lock.path)
        XCTAssertThrowsError(try ReviewFile.save(review, to: destination, expectedDiskHash: hash))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }
}
