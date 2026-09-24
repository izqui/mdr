#if DEBUG
import AppKit
import MDRCore

@MainActor enum NativeLiveSmoke {
    static func run(owner: AppDelegate, directory: URL) async {
        var checks: [String] = []
        do {
            let root = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("live.md"), sidecar = ReviewFile.url(for: source)
            let text = "# Live review\n\nThe reader should be calm and fast.\n\n```swift\nlet speed = 1\n```\n"
            try Data(text.utf8).write(to: source)
            let reader = try owner.openDocument(source, showWindow: false)
            try await NativeSmoke.wait(reader, "document.querySelector('#document h1')?.textContent === 'Live review'")
            try await NativeSmoke.selectComment(reader, quote: "calm and fast", body: "Clarify speed.")
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('comment-text').dispatchEvent(new Event('input',{bubbles:true}))")
            try await NativeSmoke.wait(reader, "document.getElementById('comment-autosave').textContent === 'Draft saved'")
            var review = try ReviewFile.decode(Data(contentsOf: sidecar))
            let firstID = review.feedback[0].id
            guard review.feedback[0].isDraft, reader.hasDraft, reader.draftIsSaved, reader.confirmDiscard() else { throw NativeSmoke.Failure("Draft was not durably autosaved") }
            checks.append("Typing creates a durable draft before posting, with safe window closing")
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('comment-text').value='Clarify speed and latency.';document.getElementById('comment-text').dispatchEvent(new Event('input',{bubbles:true}));document.getElementById('save-comment').click()")
            try await NativeSmoke.wait(reader, "document.getElementById('composer').hidden")
            review = try ReviewFile.decode(Data(contentsOf: sidecar))
            guard review.feedback.count == 1, review.feedback[0].id == firstID, !review.feedback[0].isDraft else { throw NativeSmoke.Failure("Posting duplicated the draft") }
            checks.append("Posting retains the draft's ID, timestamps, and original source version")

            try await NativeSmoke.selectComment(reader, quote: "reader", body: "Another live thought.")
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('comment-text').dispatchEvent(new Event('input',{bubbles:true}))")
            try await NativeSmoke.wait(reader, "document.getElementById('comment-autosave').textContent === 'Draft saved'")
            review = try ReviewFile.decode(Data(contentsOf: sidecar))
            let original = review.feedback[0]
            var replied = original
            replied.replies.append(FeedbackReply(author: "Agent", body: "Added a latency target.", revision: review.revision))
            replied.addressed = true; replied.updatedAt = ReviewClock.now()
            // An agent edits just the inline JSON, leaving the header and source snapshot alone.
            let external = String(decoding: try Data(contentsOf: sidecar), as: UTF8.self).replacingOccurrences(of: try ReviewFile.json(original), with: try ReviewFile.json(replied))
            try Data(external.utf8).write(to: sidecar, options: .atomic)
            try await NativeSmoke.wait(reader, "document.querySelector('.reply-body')?.textContent === 'Added a latency target.' && document.getElementById('comment-text').value === 'Another live thought.'")
            checks.append("A direct inline agent reply and addressed status appear during active typing")

            let changedSource = "An agent added context.\n\n" + text
            try Data(changedSource.utf8).write(to: source, options: .atomic)
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('comment-text').value='Another live thought, extended.';document.getElementById('comment-text').dispatchEvent(new Event('input',{bubbles:true}))")
            let bodyFile = root.appendingPathComponent("reply.txt")
            try Data("Confirmed the new source revision.".utf8).write(to: bodyFile)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--feedback", "reply", source.path, firstID, "--author", "Agent", "--body-file", bodyFile.path, "--addressed"]
            process.standardOutput = output
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NativeSmoke.Failure("Agent CLI reply failed") }
            _ = output.fileHandleForReading.readDataToEndOfFile()
            try await NativeSmoke.wait(reader, "document.querySelectorAll('.reply-body').length === 2 && document.getElementById('comment-autosave').textContent === 'Draft saved'")
            review = try ReviewFile.decode(Data(contentsOf: sidecar))
            guard review.feedback[0].replies.count == 2, review.feedback[1].body == "Another live thought, extended.",
                  review.feedback[1].createdAgainst.sha256 == sha256(text), review.source == changedSource else { throw NativeSmoke.Failure("Concurrent source/draft/reply updates did not merge") }
            checks.append("Concurrent CLI replies, typing, and source edits merge without losing provenance")
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('cancel-comment').click()")
            try await NativeSmoke.wait(reader, "document.getElementById('composer').hidden && document.querySelectorAll('.feedback-card').length === 1")

            _ = try await reader.webView.evaluateJavaScript("document.querySelector('.suggest-code').click()")
            try await NativeSmoke.wait(reader, "!!document.querySelector('.code-editor')")
            _ = try await reader.webView.evaluateJavaScript("document.querySelector('.code-editor').value='let speed = 2\\n';document.querySelector('.code-editor').dispatchEvent(new Event('input',{bubbles:true}))")
            try await NativeSmoke.wait(reader, "document.getElementById('edit-autosave').textContent === 'Draft saved'")
            review = try ReviewFile.decode(Data(contentsOf: sidecar))
            guard review.feedback.last?.isDraft == true, review.feedback.last?.body == "let speed = 2\n" else { throw NativeSmoke.Failure("Code autosave lost literal content") }
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('cancel-edit').click()")
            try await NativeSmoke.wait(reader, "!document.querySelector('.code-editor') && document.querySelectorAll('.feedback-card').length === 1")
            checks.append("Code suggestions autosave literal whitespace; discarding removes only that draft")

            _ = try await reader.webView.evaluateJavaScript("document.getElementById('read-mode').click()")
            try await NativeSmoke.wait(reader, "!document.body.classList.contains('suggesting')")
            try await NativeSmoke.selectComment(reader, quote: "reader", body: "Recover this draft.")
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('comment-text').dispatchEvent(new Event('input',{bubbles:true}))")
            try await NativeSmoke.wait(reader, "document.getElementById('comment-autosave').textContent === 'Draft saved'")
            let reopened = try ReaderWindow(url: source, owner: owner)
            try await NativeSmoke.wait(reopened, "!!document.querySelector('[data-action=resume]')")
            _ = try await reopened.webView.evaluateJavaScript("document.querySelector('[data-action=resume]').click()")
            try await NativeSmoke.wait(reopened, "document.getElementById('comment-text').value === 'Recover this draft.' && !document.getElementById('composer').hidden")
            checks.append("A new reader window restores saved drafts and their original identities")
            let valid = try Data(contentsOf: sidecar)
            try Data("an incomplete agent write".utf8).write(to: sidecar)
            _ = try await reopened.webView.evaluateJavaScript("document.getElementById('comment-text').value='Keep this local edit.';document.getElementById('comment-text').dispatchEvent(new Event('input',{bubbles:true}))")
            try await NativeSmoke.wait(reopened, "!document.getElementById('composer-error').hidden")
            guard try String(contentsOf: sidecar, encoding: .utf8) == "an incomplete agent write" else { throw NativeSmoke.Failure("Invalid external contents were overwritten") }
            try valid.write(to: sidecar, options: .atomic)
            _ = try await reopened.webView.evaluateJavaScript("document.getElementById('comment-text').dispatchEvent(new Event('input',{bubbles:true}))")
            try await NativeSmoke.wait(reopened, "document.getElementById('comment-autosave').textContent === 'Draft saved'")
            guard try Data(contentsOf: source) == Data(changedSource.utf8) else { throw NativeSmoke.Failure("Reviewing changed the source") }
            checks.append("Malformed external writes are preserved; local typing survives and can save after repair")
            _ = try await reopened.webView.evaluateJavaScript("document.getElementById('save-comment').click()")
            try await NativeSmoke.wait(reopened, "document.getElementById('composer').hidden")
            _ = try await reopened.webView.evaluateJavaScript("document.querySelector('[data-action=reply]').click()")
            try await NativeSmoke.wait(reopened, "!document.getElementById('composer').hidden")
            _ = try await reopened.webView.evaluateJavaScript("document.getElementById('comment-text').value='A human follow-up.';document.getElementById('comment-text').dispatchEvent(new Event('input',{bubbles:true}));document.getElementById('save-comment').click()")
            try await NativeSmoke.wait(reopened, "document.getElementById('composer').hidden && document.querySelectorAll('.thread-reply').length === 3")
            review = try ReviewFile.decode(Data(contentsOf: sidecar))
            guard review.feedback[0].replies.last?.body == "A human follow-up.", !review.feedback[0].addressed else { throw NativeSmoke.Failure("Human reply failed to reopen the conversation") }
            _ = try await reopened.webView.evaluateJavaScript("document.querySelectorAll('[data-action=edit-reply]')[2].click()")
            try await NativeSmoke.wait(reopened, "document.getElementById('comment-text').value === 'A human follow-up.'")
            _ = try await reopened.webView.evaluateJavaScript("document.getElementById('comment-text').value='A corrected human follow-up.';document.getElementById('comment-text').dispatchEvent(new Event('input',{bubbles:true}));document.getElementById('save-comment').click()")
            try await NativeSmoke.wait(reopened, "document.getElementById('composer').hidden && document.querySelectorAll('.reply-body')[2]?.textContent === 'A corrected human follow-up.'")
            let postedBody = review.feedback[0].body
            _ = try await reopened.webView.evaluateJavaScript("document.querySelector('[data-action=edit]').click()")
            try await NativeSmoke.wait(reopened, "!document.getElementById('composer').hidden")
            _ = try await reopened.webView.evaluateJavaScript("document.getElementById('comment-text').value='Temporary edit to discard.';document.getElementById('comment-text').dispatchEvent(new Event('input',{bubbles:true}))")
            try await NativeSmoke.wait(reopened, "document.getElementById('comment-autosave').textContent === 'Draft saved'")
            _ = try await reopened.webView.evaluateJavaScript("document.getElementById('cancel-comment').click()")
            try await NativeSmoke.wait(reopened, "document.getElementById('composer').hidden")
            review = try ReviewFile.decode(Data(contentsOf: sidecar))
            guard review.feedback[0].body == postedBody, !review.feedback[0].isDraft, review.feedback[0].replies.count == 3,
                  review.feedback[0].replies.last?.body == "A corrected human follow-up." else { throw NativeSmoke.Failure("Canceling a comment edit lost posted text or replies") }
            checks.append("Human thread replies, reply editing, and cancelled comment edits round-trip through the real bridge")
            try report(["ok": true, "checks": checks, "fixture": source.path], at: directory)
            Darwin.exit(0)
        } catch {
            try? report(["ok": false, "checks": checks, "error": error.localizedDescription], at: directory)
            Darwin.exit(1)
        }
    }
    static func report(_ value: [String: Any], at directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("native-live-report.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
#endif
