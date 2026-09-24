import XCTest
@testable import MDRCore

final class LiveFeedbackTests: XCTestCase {
    let source = SourceSnapshot(text: "# Spec\r\n\r\nCafé 🐈 stays intact.\r\n")

    func edit(_ id: String, body: String, base: String? = nil, draft: Bool = true, existing: Bool = false) throws -> FeedbackEdit {
        var fields: [String: Any] = ["id": id, "kind": "comment", "body": body, "isDraft": draft,
                                     "start": 10, "end": 14, "exact": "Café", "sourceHash": source.revision.sha256, "editExisting": existing]
        fields["baseBody"] = base
        return try JSONDecoder().decode(FeedbackEdit.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testDraftRoundTripAndPostingPreserveIdentityAndProvenance() throws {
        var review = Review(sourcePath: "/spec.md", snapshot: source)
        let id = UUID().uuidString.lowercased()
        try review.saveFeedback(edit(id, body: ""), author: "Maya", original: source, current: source)
        review = try ReviewFile.decode(ReviewFile.encode(review))
        let original = review.feedback[0]
        try review.saveFeedback(edit(id, body: "Clarify the café.", base: "", draft: false), author: "Different preference", original: nil, current: source)
        XCTAssertEqual(review.feedback.count, 1)
        XCTAssertFalse(review.feedback[0].isDraft)
        XCTAssertEqual(review.feedback[0].id, original.id)
        XCTAssertEqual(review.feedback[0].author, original.author)
        XCTAssertEqual(review.feedback[0].createdAt, original.createdAt)
        XCTAssertEqual(review.feedback[0].createdAgainst, original.createdAgainst)
        XCTAssertEqual(review.feedback[0].originalAnchor, original.originalAnchor)
    }

    func testIndependentReplyAndDraftChangesMergeButSameTextConflicts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("spec.feedback.md"), id = UUID().uuidString.lowercased()
        var review = Review(sourcePath: "/spec.md", snapshot: source)
        try review.saveFeedback(edit(id, body: "First"), author: "Maya", original: source, current: source)
        try ReviewFile.save(review, to: file, expectedDiskHash: nil)
        let reply = FeedbackReply(author: "Agent", body: "A reply with </script> and -->.", revision: source.revision)
        _ = try ReviewFile.update(at: file) { $0.feedback[0].replies.append(reply); $0.feedback[0].addressed = true }
        let result = try ReviewFile.update(at: file) { try $0.saveFeedback(edit(id, body: "Second", base: "First"), author: "Maya", original: nil, current: source) }
        XCTAssertEqual(result.review.feedback[0].replies, [reply])
        XCTAssertTrue(result.review.feedback[0].addressed)
        XCTAssertEqual(result.review.source, source.text)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try ReviewFile.update(at: file) { try $0.saveFeedback(edit(id, body: "Stale", base: "First"), author: "Maya", original: nil, current: source) })
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testAgentCanEditInlineRepliesWithoutChangingHeaderOrSnapshot() throws {
        var review = Review(sourcePath: "/spec.md", snapshot: source)
        review.feedback = [try Feedback(kind: .comment, author: "Maya", body: "Clarify", snapshot: source, start: 10, end: 14)]
        let bytes = try ReviewFile.encode(review), old = review.feedback[0]
        var new = old
        new.replies = [FeedbackReply(author: "Agent", body: "Addressed, with Unicode 🐈.", revision: source.revision)]
        new.addressed = true; new.updatedAt = ReviewClock.now()
        let changed = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: try ReviewFile.json(old), with: try ReviewFile.json(new))
        let loaded = try ReviewFile.decode(Data(changed.utf8))
        XCTAssertEqual(loaded.feedback[0], new)
        XCTAssertEqual(loaded.source, source.text)
        XCTAssertEqual(loaded.feedback[0].originalAnchor, old.originalAnchor)
        var duplicate = loaded; duplicate.feedback[0].replies.append(new.replies[0])
        XCTAssertThrowsError(try ReviewFile.encode(duplicate))
    }

    func testThreadEditsKeepAuthorsRepliesAndVersionsAndCancelRestoresPostedText() throws {
        var review = Review(sourcePath: "/spec.md", snapshot: source)
        let id = UUID().uuidString.lowercased(), replyID = UUID().uuidString.lowercased()
        try review.saveFeedback(edit(id, body: "Original", draft: false), author: "Maya", original: source, current: source)
        let first = review.feedback[0]
        func replyEdit(_ body: String, base: String? = nil, draft: Bool = false, existing: Bool = false) throws -> ReplyEdit {
            var value: [String: Any] = ["id": replyID, "threadID": id, "body": body, "isDraft": draft, "editExisting": existing]
            value["baseBody"] = base
            return try JSONDecoder().decode(ReplyEdit.self, from: JSONSerialization.data(withJSONObject: value))
        }
        try review.saveReply(replyEdit("Agent clarification"), author: "Agent", current: source)
        let reply = review.feedback[0].replies[0]
        try review.saveFeedback(edit(id, body: "Work in progress", base: "Original", existing: true), author: "Maya", original: nil, current: source)
        XCTAssertEqual(review.feedback[0].draftBase, "Original")
        try review.discardDraft(id: id, baseBody: "Work in progress")
        XCTAssertEqual(review.feedback[0].body, "Original")
        XCTAssertEqual(review.feedback[0].replies, [reply])
        try review.saveFeedback(edit(id, body: "Corrected", base: "Original", draft: false, existing: true), author: "Agent", original: nil, current: source)
        XCTAssertEqual(review.feedback[0].author, "Maya")
        XCTAssertEqual(review.feedback[0].editedBy, "Agent")
        XCTAssertEqual(review.feedback[0].createdAgainst, first.createdAgainst)
        try review.saveReply(replyEdit("Reply draft", base: reply.body, draft: true, existing: true), author: "Maya", current: source)
        try review.discardDraft(id: replyID, threadID: id, baseBody: "Reply draft")
        XCTAssertEqual(review.feedback[0].replies[0].body, reply.body)
        try review.saveReply(replyEdit("Corrected reply", base: reply.body, existing: true), author: "Maya", current: source)
        XCTAssertEqual(review.feedback[0].replies[0].author, "Agent")
        XCTAssertEqual(review.feedback[0].replies[0].editedBy, "Maya")
        XCTAssertEqual(review.feedback[0].replies[0].createdAgainst, reply.createdAgainst)
        XCTAssertEqual(try ReviewFile.decode(ReviewFile.encode(review)), review)
    }

    func testLegacyReviewUpgradesWithoutLosingItsOriginalMetadata() throws {
        var review = Review(sourcePath: "/spec.md", snapshot: source)
        let item = try Feedback(kind: .comment, author: "Maya", body: "Legacy comment", snapshot: source, start: 10, end: 14)
        review.feedback = [item]; review.formatVersion = 1
        struct LegacyNote: Encodable {
            var id: String; var kind: FeedbackKind; var author: String; var createdAt: String
            var sourceSHA256: String; var sourceModifiedAt: String; var quote: String
            var state: PlacementState; var resolved: Bool; var comment: String
        }
        let note = LegacyNote(id: item.id, kind: item.kind, author: item.author, createdAt: item.createdAt, sourceSHA256: item.createdAgainst.sha256, sourceModifiedAt: item.createdAgainst.modifiedAt, quote: item.originalAnchor.exact, state: item.state, resolved: item.resolved, comment: item.body)
        let body = NSMutableString(string: source.text)
        body.insert("<!-- mdr:note:\(item.id)\n\(try ReviewFile.json(note))\n/mdr:note:\(item.id) -->", at: item.anchor.end)
        let legacy = "<!-- mdr:review v1\n\(try ReviewFile.json(review))\n-->\n\n<!-- mdr:body -->\n\(body)"
        let loaded = try ReviewFile.decode(Data(legacy.utf8))
        XCTAssertEqual(loaded.formatVersion, 2)
        XCTAssertEqual(loaded.feedback, [item])
        XCTAssertEqual(loaded.source, source.text)
        XCTAssertEqual(try ReviewFile.decode(ReviewFile.encode(loaded)), loaded)
    }
}
