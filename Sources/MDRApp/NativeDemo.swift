#if DEBUG
import AppKit
import WebKit
import MDRCore

/// Reproducible screenshots of a fictional review, using the actual Mac reader.
@MainActor enum NativeDemo {
    static func run(owner: AppDelegate, directory: URL) async {
        do {
            let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let output = project.appendingPathComponent("docs/images")
            let root = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("export-service.md")
            try FileManager.default.copyItem(at: project.appendingPathComponent("examples/export-service.md"), to: source)
            let snapshot = try SourceSnapshot.read(source)
            var review = Review(sourcePath: source.path, snapshot: snapshot)
            func note(_ quote: String, _ body: String, reply: String) throws -> Feedback {
                let range = (snapshot.text as NSString).range(of: quote)
                guard range.location != NSNotFound else { throw NativeSmoke.Failure("Missing demo quote") }
                var item = try Feedback(kind: .comment, author: "Maya", body: body, snapshot: snapshot,
                                        start: range.location, end: NSMaxRange(range))
                item.createdAt = "2026-09-23T17:15:00.000Z"; item.updatedAt = item.createdAt
                var response = FeedbackReply(author: "Agent", body: reply, revision: snapshot.revision)
                response.createdAt = "2026-09-23T17:17:00.000Z"; response.updatedAt = response.createdAt
                item.replies = [response]; item.addressed = true
                return item
            }
            review.feedback = [
                try note("A repeated request with the same idempotency key returns the original job.",
                         "Can two workspaces safely reuse a key? And what if the body changes?",
                         reply: "Yes — keys are scoped to the workspace. Added a 24-hour retention window and a 409 response for a different body. See Request contract."),
                try note("idempotencyKey: \"monthly-export-september\"",
                         "Keep this key stable across network retries. A timestamp here would create duplicate exports.",
                         reply: "The example now uses one key per logical export. Retrying returns the same job ID; a new export gets a new key.")
            ]
            let quote = "The client polls every two seconds while the page is visible and stops on a terminal state."
            let range = (snapshot.text as NSString).range(of: quote)
            review.feedback.append(try Feedback(kind: .suggestion, author: "Maya",
                body: "The client polls every two seconds while the page is visible, backs off after a minute, and stops on a terminal state.",
                snapshot: snapshot, start: range.location, end: NSMaxRange(range)))
            review.feedback[2].createdAt = "2026-09-23T17:19:00.000Z"
            review.feedback[2].updatedAt = review.feedback[2].createdAt
            try ReviewFile.encode(review).write(to: ReviewFile.url(for: source))
            let reader = try owner.openDocument(source, showWindow: false)
            reader.window.setContentSize(NSSize(width: 1440, height: 980))
            try await NativeSmoke.wait(reader, "!!document.querySelector('.mermaid svg') && document.querySelectorAll('.feedback-card').length === 3")
            // Override only this isolated reader's presentation; never change user preferences.
            let revision = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.revision))
            let items = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review.feedback))
            reader.call("window.mdr.receive", value: ["source": snapshot.text, "revision": revision, "feedback": items,
                "fileName": "export-service.md", "filePath": "/demo/export-service.md", "feedbackPath": "/demo/export-service.feedback.md",
                "author": "Maya", "hasSidecar": true, "isWelcome": false, "theme": "paper", "fontSize": 18])
            try await NativeSmoke.wait(reader, "document.getElementById('settings-toggle').textContent === 'M'")
            _ = try await reader.webView.evaluateJavaScript("window.mdr.command('feedback');document.getElementById('scroll-area').scrollTop=0")
            try await NativeSmoke.wait(reader, "!document.getElementById('feedback-panel').hidden")
            try await capture(reader, to: output.appendingPathComponent("review.png"))
            _ = try await reader.webView.evaluateJavaScript("window.mdr.navigateToHeading('request-contract');(() => {const list=document.getElementById('feedback-list'),card=document.querySelectorAll('.feedback-card')[1];list.scrollTop+=card.getBoundingClientRect().top-list.getBoundingClientRect().top-16;})()")
            try await capture(reader, to: output.appendingPathComponent("code.png"))
            _ = try await reader.webView.evaluateJavaScript("window.mdr.command('feedback');window.mdr.navigateToHeading('job-lifecycle')")
            try await capture(reader, to: output.appendingPathComponent("diagram.png"))
            print("Saved fictional native reader screenshots to docs/images")
            Darwin.exit(0)
        } catch {
            FileHandle.standardError.write(Data("Demo capture failed: \(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    static func capture(_ reader: ReaderWindow, to destination: URL) async throws {
        try await Task.sleep(nanoseconds: 700_000_000)
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 1440
        let image = try await reader.webView.takeSnapshot(configuration: config)
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw NativeSmoke.Failure("Could not encode demo image") }
        try png.write(to: destination)
    }
}
#endif
