import Foundation

public struct FeedbackEdit: Decodable {
    public var id: String
    public var kind: FeedbackKind
    public var body: String
    public var isDraft: Bool
    public var sourceHash: String
    public var start: Int
    public var end: Int
    public var exact: String
    public var baseBody: String?
    public var editExisting: Bool?
}

public struct ReplyEdit: Decodable {
    public var id: String
    public var threadID: String
    public var body: String
    public var isDraft: Bool
    public var baseBody: String?
    public var editExisting: Bool?
}

extension Review {
    public mutating func saveFeedback(_ edit: FeedbackEdit, author: String, original: SourceSnapshot?, current: SourceSnapshot) throws {
        guard UUID(uuidString: edit.id) != nil,
              edit.isDraft || edit.kind == .suggestion || !edit.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MDRError.invalidFeedback("Write some feedback before posting it.") }
        if let index = feedback.firstIndex(where: { $0.id == edit.id }) {
            let item = feedback[index]
            guard item.kind == edit.kind, item.createdAgainst.sha256 == edit.sourceHash,
                  item.originalAnchor.start == edit.start, item.originalAnchor.end == edit.end, item.originalAnchor.exact == edit.exact else { throw MDRError.invalidAnchor }
            // Replies and agent status can merge freely; simultaneous edits to the same text cannot.
            guard item.isDraft || edit.editExisting == true, item.body == edit.baseBody || item.body == edit.body else {
                throw MDRError.invalidFeedback("This feedback text changed in another window or agent. Your text is still here; review the saved note before continuing.")
            }
            if !item.isDraft && edit.isDraft { feedback[index].draftBase = item.body }
            if !edit.isDraft {
                if item.draftBase != nil || !item.isDraft { feedback[index].editedBy = author }
                if edit.body != (item.draftBase ?? item.body) { feedback[index].addressed = false; feedback[index].resolved = false }
                feedback[index].draftBase = nil
            }
            feedback[index].body = edit.body; feedback[index].isDraft = edit.isDraft
            feedback[index].updatedAt = ReviewClock.now()
        } else {
            guard edit.baseBody == nil else { throw MDRError.invalidFeedback("This draft was deleted elsewhere. Your text is still here.") }
            guard let original, original.revision.sha256 == edit.sourceHash else { throw MDRError.invalidAnchor }
            var item = try Feedback(kind: edit.kind, author: author, body: edit.body, snapshot: original, start: edit.start, end: edit.end, isDraft: edit.isDraft)
            guard item.originalAnchor.exact == edit.exact else { throw MDRError.invalidAnchor }
            item.id = edit.id
            add(item, against: current)
        }
        updatedAt = ReviewClock.now()
    }

    public mutating func saveReply(_ edit: ReplyEdit, author: String, current: SourceSnapshot) throws {
        guard let index = feedback.firstIndex(where: { $0.id == edit.threadID }), UUID(uuidString: edit.id) != nil,
              edit.isDraft || !edit.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MDRError.invalidFeedback("Write a reply in an existing thread.") }
        if let position = feedback[index].replies.firstIndex(where: { $0.id == edit.id }) {
            let reply = feedback[index].replies[position]
            guard reply.isDraft || edit.editExisting == true, reply.body == edit.baseBody || reply.body == edit.body else {
                throw MDRError.invalidFeedback("This reply changed elsewhere. Your text is still here; review the saved reply before continuing.")
            }
            if !reply.isDraft && edit.isDraft { feedback[index].replies[position].draftBase = reply.body }
            if !edit.isDraft {
                if reply.draftBase != nil || !reply.isDraft { feedback[index].replies[position].editedBy = author }
                feedback[index].replies[position].draftBase = nil
            }
            feedback[index].replies[position].body = edit.body
            feedback[index].replies[position].isDraft = edit.isDraft
            feedback[index].replies[position].updatedAt = ReviewClock.now()
        } else {
            guard edit.baseBody == nil else { throw MDRError.invalidFeedback("This reply was deleted elsewhere. Your text is still here.") }
            var reply = FeedbackReply(author: author, body: edit.body, revision: current.revision)
            reply.id = edit.id; reply.isDraft = edit.isDraft
            feedback[index].replies.append(reply)
        }
        if !edit.isDraft { feedback[index].addressed = false; feedback[index].resolved = false }
        feedback[index].updatedAt = ReviewClock.now(); updatedAt = ReviewClock.now()
    }

    public mutating func discardDraft(id: String, threadID: String? = nil, baseBody: String) throws {
        guard let index = feedback.firstIndex(where: { $0.id == (threadID ?? id) }) else { return }
        if threadID != nil {
            guard let position = feedback[index].replies.firstIndex(where: { $0.id == id }) else { return }
            let item = feedback[index].replies[position]
            guard item.isDraft, item.body == baseBody else { throw MDRError.invalidFeedback("This reply changed elsewhere. Review it before discarding.") }
            if let previous = item.draftBase {
                feedback[index].replies[position].body = previous; feedback[index].replies[position].draftBase = nil
                feedback[index].replies[position].isDraft = false
            } else { feedback[index].replies.remove(at: position) }
        } else {
            let item = feedback[index]
            guard item.isDraft, item.body == baseBody else { throw MDRError.invalidFeedback("This draft changed elsewhere. Review it before discarding.") }
            if let previous = item.draftBase {
                feedback[index].body = previous; feedback[index].draftBase = nil; feedback[index].isDraft = false
            } else {
                guard item.replies.isEmpty else { throw MDRError.invalidFeedback("This draft has replies. Delete the thread explicitly if you want to remove the conversation.") }
                feedback.remove(at: index)
            }
        }
        updatedAt = ReviewClock.now()
    }
}
