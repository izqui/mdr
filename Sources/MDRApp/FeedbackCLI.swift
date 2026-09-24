import Foundation
import MDRCore

enum FeedbackCLI {
    static let usage = """
    mdr FILE                                  Open a Markdown file in the Mac reader
    mdr --help                                Show this help
    mdr skill                                 Print the complete agent workflow and file format
    mdr skill --install DIRECTORY             Install the agent skill in a new folder
    mdr --install-cli [DIRECTORY]              Install the command (default: ~/.local/bin)

    mdr feedback show FILE                    Read the review as JSON
    mdr feedback watch FILE [--include-drafts] Watch changes as newline-delimited JSON
    mdr feedback comment FILE --author NAME --quote TEXT --body-file PATH
    mdr feedback reply FILE NOTE_ID --author NAME --body-file PATH [--addressed]
    mdr feedback edit FILE NOTE_ID [--reply REPLY_ID] --author NAME --body-file PATH
    mdr feedback resolve FILE NOTE_ID --author NAME
    mdr feedback reopen FILE NOTE_ID --author NAME

    FILE is the source .md or its .feedback.md. Use --body-file - for stdin.
    Comments accept --kind suggestion and --start N --end N instead of --quote.
    Offsets are UTF-16; ambiguous quotes are rejected. Use --note-id UUID or
    --reply-id UUID for retry-safe creation. Text edits preserve original authors
    and source provenance and record editedBy and updatedAt.
    The human's typing autosaves as drafts; Post / Cmd+Enter makes it ready.
    watch omits drafts by default and waits if the feedback file does not exist.
    """

    static func run(_ args: [String]) -> Int32 {
        do {
            if args.isEmpty || args == ["--help"] { print(usage); return 0 }
            guard args.count >= 2 else { throw MDRError.invalidFeedback(usage) }
            let file = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
            let sidecar = file.lastPathComponent.hasSuffix(".feedback.md") ? file : ReviewFile.url(for: file)
            switch args[0] {
            case "show":
                guard args.count == 2 else { throw MDRError.invalidFeedback(usage) }
                emit(try ReviewFile.json(ReviewFile.decode(Data(contentsOf: sidecar))))
            case "watch":
                guard args.count == 2 || (args.count == 3 && args[2] == "--include-drafts") else { throw MDRError.invalidFeedback(usage) }
                watch(sidecar, includeDrafts: args.contains("--include-drafts"))
            case "comment", "reply", "edit", "resolve", "reopen":
                let command = args[0], offset = command == "comment" ? 2 : 3
                guard args.count >= offset else { throw MDRError.invalidFeedback(usage) }
                var options: [String: String] = [:], addressed = false, index = offset
                let validOptions = ["--author", "--body-file", "--reply-id", "--note-id", "--reply", "--kind", "--quote", "--start", "--end"]
                while index < args.count {
                    if args[index] == "--addressed", command == "reply" { addressed = true; index += 1; continue }
                    guard validOptions.contains(args[index]), index + 1 < args.count, options[args[index]] == nil else { throw MDRError.invalidFeedback(usage) }
                    options[args[index]] = args[index + 1]; index += 2
                }
                guard let author = options["--author"], !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MDRError.invalidFeedback("Provide --author so the human can see who wrote the feedback.") }
                var body = ""
                if ["comment", "reply", "edit"].contains(command) {
                    guard let path = options["--body-file"] else { throw MDRError.invalidFeedback("Provide --body-file PATH or --body-file - for stdin.") }
                    let bytes = path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: path))
                    guard let text = String(data: bytes, encoding: .utf8) else { throw MDRError.invalidFeedback("Feedback text must be UTF-8.") }
                    body = text
                }
                let newID = options[command == "comment" ? "--note-id" : "--reply-id"] ?? UUID().uuidString.lowercased()
                guard UUID(uuidString: newID) != nil else { throw MDRError.invalidFeedback("Note and reply IDs must be UUIDs.") }
                var initial: Review?
                if command == "comment", !FileManager.default.fileExists(atPath: sidecar.path), file != sidecar {
                    initial = Review(sourcePath: file.path, snapshot: try SourceSnapshot.read(file))
                }
                for attempt in 0...20 {
                    do {
                        let result = try ReviewFile.update(at: sidecar, initial: initial) { review in
                            let current = try SourceSnapshot.read(URL(fileURLWithPath: review.sourcePath))
                            review.rebase(to: current)
                            if command == "comment" {
                                guard let kind = FeedbackKind(rawValue: options["--kind"] ?? "comment") else { throw MDRError.invalidFeedback("Kind must be comment or suggestion.") }
                                let range = try selectedRange(in: current.text, options: options)
                                if let existing = review.feedback.first(where: { $0.id == newID }) {
                                    guard existing.body == body, existing.author == author, existing.kind == kind,
                                          existing.anchor.start == range.location, existing.anchor.end == NSMaxRange(range) else { throw MDRError.invalidFeedback("That note ID already belongs to different feedback.") }
                                    return
                                }
                                var item = try Feedback(kind: kind, author: author, body: body, snapshot: current, start: range.location, end: NSMaxRange(range))
                                item.id = newID; review.add(item, against: current); return
                            }
                            guard let position = review.feedback.firstIndex(where: { $0.id == args[2] }) else { throw MDRError.invalidFeedback("The feedback ID was not found.") }
                            let item = review.feedback[position]
                            guard !item.isDraft else { throw MDRError.invalidFeedback("This note is being drafted or edited. Wait until the reviewer posts it.") }
                            if command == "reply" {
                                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MDRError.invalidFeedback("Write a reply before posting.") }
                                if let existing = item.replies.first(where: { $0.id == newID }) {
                                    guard existing.body == body && existing.author == author else { throw MDRError.invalidFeedback("That reply ID already belongs to different content.") }
                                    return
                                }
                                var reply = FeedbackReply(author: author, body: body, revision: current.revision); reply.id = newID
                                review.feedback[position].replies.append(reply)
                                review.feedback[position].addressed = addressed; review.feedback[position].resolved = false
                            } else if command == "edit" {
                                if let replyID = options["--reply"] {
                                    guard let reply = item.replies.first(where: { $0.id == replyID }), !reply.isDraft else { throw MDRError.invalidFeedback("Reply not found, or someone is currently editing it.") }
                                    let fields: [String: Any] = ["id": replyID, "threadID": item.id, "body": body, "baseBody": reply.body, "isDraft": false, "editExisting": true]
                                    let edit = try JSONDecoder().decode(ReplyEdit.self, from: JSONSerialization.data(withJSONObject: fields))
                                    try review.saveReply(edit, author: author, current: current)
                                } else {
                                    let fields: [String: Any] = ["id": item.id, "kind": item.kind.rawValue, "body": body, "baseBody": item.body, "isDraft": false, "editExisting": true,
                                                              "sourceHash": item.createdAgainst.sha256, "start": item.originalAnchor.start, "end": item.originalAnchor.end, "exact": item.originalAnchor.exact]
                                    let edit = try JSONDecoder().decode(FeedbackEdit.self, from: JSONSerialization.data(withJSONObject: fields))
                                    try review.saveFeedback(edit, author: author, original: nil, current: current)
                                }
                            } else { review.feedback[position].resolved = command == "resolve" }
                            review.feedback[position].updatedAt = ReviewClock.now()
                        }
                        emit(try ReviewFile.json(result.review, pretty: false)); break
                    } catch MDRError.busy where attempt < 20 { Thread.sleep(forTimeInterval: 0.1) }
                }
            default: throw MDRError.invalidFeedback(usage)
            }
            return 0
        } catch { log(error.localizedDescription); return 1 }
    }

    private static func selectedRange(in text: String, options: [String: String]) throws -> NSRange {
        let source = text as NSString
        if let quote = options["--quote"] {
            guard options["--start"] == nil, options["--end"] == nil, !quote.isEmpty else { throw MDRError.invalidAnchor }
            let match = source.range(of: quote)
            guard match.location != NSNotFound else { throw MDRError.invalidFeedback("The quote does not appear in the current source.") }
            let remaining = NSRange(location: match.location + 1, length: source.length - match.location - 1)
            guard source.range(of: quote, range: remaining).location == NSNotFound else { throw MDRError.invalidFeedback("The quote is ambiguous. Use --start and --end UTF-16 offsets to identify the passage.") }
            return match
        }
        guard let a = options["--start"], let start = Int(a), let b = options["--end"], let end = Int(b) else { throw MDRError.invalidFeedback("Provide --quote TEXT or --start N --end N to anchor the comment.") }
        _ = try TextAnchor(text: text, start: start, end: end)
        return NSRange(location: start, length: end - start)
    }

    private static func watch(_ url: URL, includeDrafts: Bool) {
        var lastDiskHash: String?, lastEvent: String?, lastError: String?, waiting = false
        while true {
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    if !waiting { emit("{\"event\":\"waiting\",\"path\":\(try ReviewFile.json(url.path, pretty: false))}"); waiting = true }
                    lastDiskHash = nil; lastEvent = nil
                } else {
                    let data = try Data(contentsOf: url), hash = sha256(data)
                    if hash != lastDiskHash {
                        var review = try ReviewFile.decode(data)
                        if !includeDrafts {
                            review.feedback.removeAll(where: \.isDraft)
                            for index in review.feedback.indices { review.feedback[index].replies.removeAll(where: \.isDraft) }
                        }
                        // Draft keystrokes must not wake an agent working only on posted notes.
                        var meaningful = review.feedback
                        if !includeDrafts { for index in meaningful.indices { meaningful[index].updatedAt = "" } }
                        let signature = sha256(try ReviewFile.json(meaningful, pretty: false) + ReviewFile.json(review.revision, pretty: false))
                        if signature != lastEvent {
                            emit("{\"event\":\"feedback\",\"path\":\(try ReviewFile.json(url.path, pretty: false)),\"review\":\(try ReviewFile.json(review, pretty: false))}")
                            lastEvent = signature
                        }
                        lastDiskHash = hash; waiting = false; lastError = nil
                    }
                }
            } catch {
                if lastError != error.localizedDescription { lastError = error.localizedDescription; log("Waiting for a valid feedback file: " + error.localizedDescription) }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
    private static func emit(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    private static func log(_ text: String) { FileHandle.standardError.write(Data(("mdr: " + text + "\n").utf8)) }
}
