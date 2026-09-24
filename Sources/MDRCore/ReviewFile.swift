import Foundation
import Darwin

/// One portable .feedback.md: machine-readable metadata + full source + inline notes.
public enum ReviewFile {
    private static let header = "<!-- mdr:review v2\n"
    private static let legacyHeader = "<!-- mdr:review v1\n"
    private static let bodyMarker = "\n-->\n\n<!-- mdr:body -->\n"

    private struct Metadata: Codable {
        var formatVersion: Int = 2
        var sourcePath: String
        var createdAt: String
        var updatedAt: String
        var revision: SourceRevision
        var feedbackIDs: [String]
    }

    public static func url(for source: URL) -> URL { source.deletingPathExtension().appendingPathExtension("feedback.md") }

    public static func json<T: Encodable>(_ value: T, pretty: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        let text = String(data: try encoder.encode(value), encoding: .utf8)!
        // Never let document/comment text break out of an HTML comment.
        return text.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e").replacingOccurrences(of: "&", with: "\\u0026")
    }

    private static func legacyNote(_ item: Feedback) throws -> String {
        struct InlineNote: Encodable {
            var id: String; var kind: FeedbackKind; var author: String; var createdAt: String
            var sourceSHA256: String; var sourceModifiedAt: String; var quote: String
            var state: PlacementState; var resolved: Bool; var comment: String?; var replacementMarkdown: String?
        }
        let value = InlineNote(id: item.id, kind: item.kind, author: item.author, createdAt: item.createdAt,
                               sourceSHA256: item.createdAgainst.sha256, sourceModifiedAt: item.createdAgainst.modifiedAt,
                               quote: item.originalAnchor.exact, state: item.state, resolved: item.resolved,
                               comment: item.kind == .comment ? item.body : nil,
                               replacementMarkdown: item.kind == .suggestion ? item.body : nil)
        return "<!-- mdr:note:\(item.id)\n\(try json(value))\n/mdr:note:\(item.id) -->"
    }

    public static func encode(_ review: Review) throws -> Data {
        guard sha256(review.source) == review.revision.sha256, review.source.utf8.count == review.revision.byteLength else { throw MDRError.invalidFeedback("The review snapshot does not match its hash or byte length.") }
        guard Set(review.feedback.map(\.id)).count == review.feedback.count else { throw MDRError.invalidFeedback("Duplicate feedback IDs.") }
        let source = review.source as NSString
        var insertions: [(Int, String, String)] = []
        for item in review.feedback {
            guard UUID(uuidString: item.id) != nil, !item.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.isDraft || item.kind == .suggestion || !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(item.replies.map(\.id)).count == item.replies.count,
                  item.replies.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.isDraft || !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && !$0.createdAt.isEmpty }) else {
                throw MDRError.invalidFeedback("A feedback record or reply is invalid. The file has been left untouched.")
            }
            if item.state == .attached {
                guard item.anchor.start >= 0, item.anchor.end >= item.anchor.start, item.anchor.end <= source.length,
                      source.substring(with: NSRange(location: item.anchor.start, length: item.anchor.end - item.anchor.start)) == item.anchor.exact else { throw MDRError.invalidAnchor }
            }
            let note = "<!-- mdr:note:\(item.id)\n\(try json(item))\n/mdr:note:\(item.id) -->"
            insertions.append((item.state == .attached ? item.anchor.end : source.length, item.id, note))
        }
        // Descending positions keep all offsets relative to the untouched source; IDs make ties stable.
        insertions.sort { $0.0 == $1.0 ? $0.1 > $1.1 : $0.0 > $1.0 }
        let annotated = NSMutableString(string: review.source)
        for (offset, _, value) in insertions { annotated.insert(value, at: offset) }
        let metadata = Metadata(sourcePath: review.sourcePath, createdAt: review.createdAt, updatedAt: review.updatedAt,
                                revision: review.revision, feedbackIDs: review.feedback.map(\.id))
        return Data((header + (try json(metadata)) + bodyMarker + (annotated as String)).utf8)
    }

    public static func decode(_ data: Data) throws -> Review {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(header) || text.hasPrefix(legacyHeader),
              let separator = text.range(of: bodyMarker) else { throw MDRError.invalidFeedback("This feedback file isn't an mdr review. It has been left untouched.") }
        let legacy = text.hasPrefix(legacyHeader)
        let prefix = legacy ? legacyHeader : header
        let metadata = Data(text[text.index(text.startIndex, offsetBy: prefix.count)..<separator.lowerBound].utf8)
        var review: Review
        var body = String(text[separator.upperBound...])
        do {
            if legacy {
                review = try JSONDecoder().decode(Review.self, from: metadata)
                guard review.formatVersion == 1 else { throw MDRError.invalidFeedback("Unsupported review version.") }
                for item in review.feedback {
                    let parts = body.components(separatedBy: try legacyNote(item))
                    guard parts.count == 2 else { throw MDRError.invalidFeedback("An inline v1 note differs from its header. Upgrade using mdr before editing notes directly.") }
                    body = parts.joined()
                }
            } else {
                let info = try JSONDecoder().decode(Metadata.self, from: metadata)
                guard info.formatVersion == 2, Set(info.feedbackIDs).count == info.feedbackIDs.count else { throw MDRError.invalidFeedback("Unsupported version or duplicate feedback IDs.") }
                review = Review(sourcePath: info.sourcePath, snapshot: SourceSnapshot(text: ""))
                review.createdAt = info.createdAt; review.updatedAt = info.updatedAt; review.revision = info.revision
                for id in info.feedbackIDs {
                    guard UUID(uuidString: id) != nil else { throw MDRError.invalidFeedback("Invalid feedback ID.") }
                    let start = "<!-- mdr:note:\(id)\n", end = "\n/mdr:note:\(id) -->"
                    guard body.components(separatedBy: start).count == 2, body.components(separatedBy: end).count == 2,
                          let a = body.range(of: start), let b = body.range(of: end, range: a.upperBound..<body.endIndex) else { throw MDRError.invalidFeedback("Missing or duplicate inline feedback note.") }
                    let item = try JSONDecoder().decode(Feedback.self, from: Data(body[a.upperBound..<b.lowerBound].utf8))
                    guard item.id == id else { throw MDRError.invalidFeedback("Inline feedback ID differs from its marker.") }
                    review.feedback.append(item)
                    body.removeSubrange(a.lowerBound..<b.upperBound)
                }
            }
        }
        catch let error as MDRError { throw error }
        catch { throw MDRError.invalidFeedback("The feedback metadata could not be read. The existing file has been left untouched.") }
        guard sha256(body) == review.revision.sha256 else { throw MDRError.invalidFeedback("The feedback document's body no longer matches its recorded revision. It has been left untouched.") }
        review.source = body; review.formatVersion = 2
        // Validate stored attached ranges as well as the body hash.
        _ = try encode(review)
        return review
    }

    /// Refuse stale overwrites, serialize mdr writers, then replace atomically in the same directory.
    @discardableResult public static func save(_ review: Review, to url: URL, expectedDiskHash: String?) throws -> String {
        let data = try encode(review)
        return try withLock(url) {
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists {
                guard let expectedDiskHash, sha256(try Data(contentsOf: url)) == expectedDiskHash else { throw MDRError.staleFeedback }
            } else if expectedDiskHash != nil { throw MDRError.staleFeedback }
            try data.write(to: url, options: .atomic)
            return sha256(data)
        }
    }

    /// Read the latest review while locked, then change only the requested fields.
    public static func update(at url: URL, initial: Review? = nil, _ mutation: (inout Review) throws -> Void) throws -> (review: Review, hash: String) {
        try withLock(url) {
            var review: Review
            if FileManager.default.fileExists(atPath: url.path) { review = try decode(Data(contentsOf: url)) }
            else if let initial { review = initial }
            else { throw MDRError.invalidFeedback("The feedback file does not exist yet.") }
            try mutation(&review)
            review.updatedAt = ReviewClock.now()
            let data = try encode(review)
            try data.write(to: url, options: .atomic)
            return (review, sha256(data))
        }
    }

    private static func withLock<T>(_ url: URL, _ operation: () throws -> T) throws -> T {
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).mdr-lock")
        // A crashed process cannot leave the document permanently locked. Never steal a live lock.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: lockURL.path),
           let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) > 30,
           let pidText = try? String(contentsOf: lockURL, encoding: .utf8), let pid = Int32(pidText),
           Darwin.kill(pid, 0) == -1, errno == ESRCH {
            try? FileManager.default.removeItem(at: lockURL)
        }
        let fd = Darwin.open(lockURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if errno == EEXIST { throw MDRError.busy }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: lockURL) }
        let pidBytes = Array(String(ProcessInfo.processInfo.processIdentifier).utf8)
        _ = pidBytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        return try operation()
    }
}
