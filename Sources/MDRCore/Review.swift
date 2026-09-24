import Foundation
import CryptoKit

public enum MDRError: LocalizedError {
    case invalidDocument(String)
    case invalidFeedback(String)
    case staleFeedback
    case invalidAnchor
    case busy
    public var errorDescription: String? {
        switch self {
        case .invalidDocument(let message), .invalidFeedback(let message): return message
        case .staleFeedback: return "The feedback file changed outside mdr. Reopen this document to load that feedback before saving. Your draft is still here."
        case .invalidAnchor: return "The selected text no longer matches this revision. Select the passage again."
        case .busy: return "Another mdr window is saving this feedback. Try again in a moment."
        }
    }
}

public enum ReviewClock {
    public static func now() -> String { string(Date()) }
    public static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }

public struct SourceRevision: Codable, Equatable, Sendable {
    public var sha256: String
    public var modifiedAt: String
    public var byteLength: Int
    public init(sha256: String, modifiedAt: String, byteLength: Int) {
        self.sha256 = sha256; self.modifiedAt = modifiedAt; self.byteLength = byteLength
    }
}

public struct SourceSnapshot: Equatable, Sendable {
    public var text: String
    public var revision: SourceRevision
    public init(text: String, modifiedAt: String = ReviewClock.now()) {
        self.text = text
        self.revision = SourceRevision(sha256: sha256(text), modifiedAt: modifiedAt, byteLength: text.utf8.count)
    }
    public static func read(_ url: URL) throws -> SourceSnapshot {
        // Stat before and after reading so metadata and bytes describe one file version.
        for _ in 0..<3 {
            let before = try FileManager.default.attributesOfItem(atPath: url.path)
            let data = try Data(contentsOf: url)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            guard data.count <= 8_000_000 else { throw MDRError.invalidDocument("This document is larger than mdr's current 8 MB reading limit.") }
            guard let text = String(data: data, encoding: .utf8), Data(text.utf8) == data else {
                throw MDRError.invalidDocument("mdr reads UTF-8 Markdown. Save this document as UTF-8 and open it again.")
            }
            if (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date),
               (before[.size] as? NSNumber) == (after[.size] as? NSNumber),
               (before[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber) {
                return SourceSnapshot(text: text, modifiedAt: ReviewClock.string(after[.modificationDate] as? Date ?? Date()))
            }
        }
        throw MDRError.invalidDocument("The document is still being written. Try opening it again in a moment.")
    }
}

/// Offsets are UTF-16 code units, matching DOM/JavaScript string offsets.
public struct TextAnchor: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var exact: String
    public var prefix: String
    public var suffix: String
    public init(text: String, start: Int, end: Int) throws {
        let ns = text as NSString
        func scalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < ns.length else { return true }
            return !(0xD800...0xDBFF).contains(ns.character(at: offset - 1)) || !(0xDC00...0xDFFF).contains(ns.character(at: offset))
        }
        guard start >= 0, end >= start, end <= ns.length,
              scalarBoundary(start), scalarBoundary(end),
              Range(NSRange(location: start, length: end - start), in: text) != nil else { throw MDRError.invalidAnchor }
        self.start = start; self.end = end
        exact = ns.substring(with: NSRange(location: start, length: end - start))
        // Character-safe context avoids cutting a surrogate pair or combining sequence.
        let before = text[..<String.Index(utf16Offset: start, in: text)]
        let after = text[String.Index(utf16Offset: end, in: text)...]
        prefix = String(before.suffix(64)); suffix = String(after.prefix(64))
    }
}

public enum FeedbackKind: String, Codable, Sendable { case comment, suggestion }
public enum PlacementState: String, Codable, Sendable { case attached, conflict }

public struct FeedbackReply: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var author: String
    public var body: String
    public var createdAt: String
    public var createdAgainst: SourceRevision
    public var updatedAt: String
    public var isDraft = false
    public var draftBase: String?
    public var editedBy: String?
    enum CodingKeys: String, CodingKey { case id, author, body, createdAt, createdAgainst, updatedAt, isDraft, draftBase, editedBy }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); author = try c.decode(String.self, forKey: .author)
        body = try c.decode(String.self, forKey: .body); createdAt = try c.decode(String.self, forKey: .createdAt)
        createdAgainst = try c.decode(SourceRevision.self, forKey: .createdAgainst)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        draftBase = try c.decodeIfPresent(String.self, forKey: .draftBase)
        editedBy = try c.decodeIfPresent(String.self, forKey: .editedBy)
    }
    public init(author: String, body: String, revision: SourceRevision) {
        id = UUID().uuidString.lowercased(); self.author = author; self.body = body
        createdAt = ReviewClock.now(); updatedAt = createdAt; createdAgainst = revision
    }
}

public struct Feedback: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: FeedbackKind
    public var author: String
    public var createdAt: String
    public var updatedAt: String
    /// Immutable provenance, even after rebasing or manually reattaching.
    public var createdAgainst: SourceRevision
    public var originalAnchor: TextAnchor
    /// Placement against the review's current snapshot; never changes the source.
    public var anchor: TextAnchor
    public var state: PlacementState
    public var resolved: Bool
    public var body: String
    public var isDraft = false
    public var addressed = false
    public var replies: [FeedbackReply] = []
    public var draftBase: String?
    public var editedBy: String?
    enum CodingKeys: String, CodingKey {
        case id, kind, author, createdAt, updatedAt, createdAgainst, originalAnchor, anchor, state, resolved, body, isDraft, addressed, replies, draftBase, editedBy
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); kind = try c.decode(FeedbackKind.self, forKey: .kind)
        author = try c.decode(String.self, forKey: .author); body = try c.decode(String.self, forKey: .body)
        createdAt = try c.decode(String.self, forKey: .createdAt); updatedAt = try c.decode(String.self, forKey: .updatedAt)
        createdAgainst = try c.decode(SourceRevision.self, forKey: .createdAgainst)
        originalAnchor = try c.decode(TextAnchor.self, forKey: .originalAnchor); anchor = try c.decode(TextAnchor.self, forKey: .anchor)
        state = try c.decode(PlacementState.self, forKey: .state); resolved = try c.decode(Bool.self, forKey: .resolved)
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        addressed = try c.decodeIfPresent(Bool.self, forKey: .addressed) ?? false
        replies = try c.decodeIfPresent([FeedbackReply].self, forKey: .replies) ?? []
        draftBase = try c.decodeIfPresent(String.self, forKey: .draftBase)
        editedBy = try c.decodeIfPresent(String.self, forKey: .editedBy)
    }
    public init(kind: FeedbackKind, author: String, body: String, snapshot: SourceSnapshot, start: Int, end: Int, isDraft: Bool = false) throws {
        id = UUID().uuidString.lowercased(); self.kind = kind
        self.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.author.isEmpty else { throw MDRError.invalidFeedback("Set your reviewer name before adding feedback.") }
        guard isDraft || kind == .suggestion || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MDRError.invalidFeedback("Write a comment before saving.")
        }
        self.body = body; self.isDraft = isDraft; createdAt = ReviewClock.now(); updatedAt = createdAt
        createdAgainst = snapshot.revision
        originalAnchor = try TextAnchor(text: snapshot.text, start: start, end: end)
        anchor = originalAnchor; state = .attached; resolved = false
    }
}

public struct Review: Codable, Equatable, Sendable {
    public var formatVersion = 2
    public var sourcePath: String
    public var createdAt: String
    public var updatedAt: String
    public var revision: SourceRevision
    public var feedback: [Feedback]
    // Stored as the full Markdown body, not duplicated in the metadata header.
    public var source: String
    enum CodingKeys: String, CodingKey { case formatVersion, sourcePath, createdAt, updatedAt, revision, feedback }

    public init(sourcePath: String, snapshot: SourceSnapshot) {
        self.sourcePath = sourcePath; self.revision = snapshot.revision; source = snapshot.text
        createdAt = ReviewClock.now(); updatedAt = createdAt; feedback = []
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        revision = try c.decode(SourceRevision.self, forKey: .revision)
        feedback = try c.decode([Feedback].self, forKey: .feedback)
        source = ""
    }

    /// Rebase exact quotes and context only. Ambiguous/deleted/edited passages are retained as conflicts.
    @discardableResult public mutating func rebase(to snapshot: SourceSnapshot) -> Int {
        guard revision.sha256 != snapshot.revision.sha256 else { revision = snapshot.revision; return 0 }
        for index in feedback.indices {
            let anchor = feedback[index].anchor
            if let located = Self.locate(anchor, in: snapshot.text) {
                feedback[index].anchor = located
                feedback[index].state = .attached
            } else {
                feedback[index].state = .conflict
            }
        }
        source = snapshot.text; revision = snapshot.revision; updatedAt = ReviewClock.now()
        return feedback.filter { $0.state == .conflict && !$0.resolved }.count
    }

    public mutating func add(_ item: Feedback, against current: SourceSnapshot) {
        var item = item
        if item.createdAgainst.sha256 != current.revision.sha256 {
            if let located = Self.locate(item.anchor, in: current.text) { item.anchor = located }
            else { item.state = .conflict }
        }
        feedback.append(item); updatedAt = ReviewClock.now()
    }

    public static func locate(_ anchor: TextAnchor, in text: String) -> TextAnchor? {
        let ns = text as NSString
        if anchor.exact.isEmpty {
            let context = anchor.prefix + anchor.suffix
            guard !context.isEmpty else { return text.isEmpty ? try? TextAnchor(text: text, start: 0, end: 0) : nil }
            let matches = occurrences(of: context, in: text)
            guard matches.count == 1 else { return nil }
            let offset = matches[0] + (anchor.prefix as NSString).length
            return try? TextAnchor(text: text, start: offset, end: offset)
        }
        let matches = occurrences(of: anchor.exact, in: text)
        let length = (anchor.exact as NSString).length
        var candidates: [(Int, Int)] = []
        for offset in matches {
            let prefixLength = (anchor.prefix as NSString).length
            let suffixLength = (anchor.suffix as NSString).length
            let prefixMatches = prefixLength == 0 ? offset == 0 : offset >= prefixLength && ns.substring(with: NSRange(location: offset - prefixLength, length: prefixLength)) == anchor.prefix
            let suffixMatches = suffixLength == 0 ? offset + length == ns.length : offset + length + suffixLength <= ns.length && ns.substring(with: NSRange(location: offset + length, length: suffixLength)) == anchor.suffix
            let score = (prefixMatches ? max(prefixLength, 1) : 0) + (suffixMatches ? max(suffixLength, 1) : 0)
            // A unique long quote is useful when the surrounding paragraph was rewritten.
            if prefixMatches || suffixMatches || (matches.count == 1 && length >= 32) { candidates.append((offset, score)) }
        }
        candidates.sort { $0.1 > $1.1 }
        guard let best = candidates.first, candidates.count == 1 || best.1 > candidates[1].1 else { return nil }
        return try? TextAnchor(text: text, start: best.0, end: best.0 + length)
    }

    private static func occurrences(of needle: String, in haystack: String) -> [Int] {
        let source = haystack as NSString
        var cursor = 0, result: [Int] = []
        while cursor <= source.length {
            let range = source.range(of: needle, options: .literal, range: NSRange(location: cursor, length: source.length - cursor))
            if range.location == NSNotFound { break }
            result.append(range.location); cursor = range.location + max(range.length, 1)
            if result.count > 1000 { return [] } // Repetitive anchors must be selected more precisely.
        }
        return result
    }
}
