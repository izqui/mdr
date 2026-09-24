#if DEBUG
import AppKit
import WebKit
import PDFKit
import MDRCore

/// Developer-only integration checks against the real WKWebView bridge and file watchers.
/// No synthetic desktop input, foreground activation, or user's documents are involved.
@MainActor enum NativeSmoke {
    static func run(owner: AppDelegate, directory: URL) async {
        var passed: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sourceURL = directory.appendingPathComponent("native-smoke-\(UUID().uuidString).md")
            let original = "# Native integration\n\nThe reader should be calm and fast.\n\n## Flow\n\n```mermaid\ngraph LR\n A[Read] --> B[Review]\n```\n"
            try Data(original.utf8).write(to: sourceURL)
            let reader = try ReaderWindow(url: sourceURL, owner: owner)
            owner.windows[sourceURL.path] = reader
            try await wait(reader, "document.querySelector('#document h1')?.textContent === 'Native integration'")
            try await wait(reader, "!!document.querySelector('.mermaid svg')")
            passed.append("Native WebKit loads the reader and offline Mermaid")
            let originalDates = try SourceSnapshot.read(sourceURL)
            guard let createdAt = originalDates.createdAt else { throw Failure("Missing file creation date") }
            try await wait(reader, "!document.getElementById('document-dates').hidden && document.getElementById('document-created').dateTime === \(try ReviewFile.json(createdAt, pretty: false)) && document.getElementById('document-updated').dateTime === \(try ReviewFile.json(originalDates.revision.modifiedAt, pretty: false))")

            try await selectComment(reader, quote: "calm and fast", body: "Keep the reading experience quiet.")
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('save-comment').click()")
            try await wait(reader, "document.querySelectorAll('.feedback-card').length === 1 && document.getElementById('composer').hidden")
            var review = try ReviewFile.decode(Data(contentsOf: ReviewFile.url(for: sourceURL)))
            guard review.feedback[0].originalAnchor.exact == "calm and fast", try Data(contentsOf: sourceURL) == Data(original.utf8) else { throw Failure("Source or selection changed after native comment save") }
            passed.append("Native selection saves a precise comment; source bytes are unchanged")

            _ = try await reader.webView.evaluateJavaScript("document.getElementById('suggest-mode').click()")
            try await wait(reader, "document.body.classList.contains('suggesting')")
            _ = try await reader.webView.evaluateJavaScript("window.getSelection().removeAllRanges(); document.querySelector('#document p').click()")
            try await wait(reader, "!!document.querySelector('[contenteditable=true]')")
            _ = try await reader.webView.evaluateJavaScript("document.querySelector('[contenteditable=true]').textContent = 'The reader should feel effortless.'; document.getElementById('save-edit').click();")
            try await wait(reader, "document.querySelectorAll('.feedback-card').length === 2 && document.getElementById('edit-bar').hidden")
            review = try ReviewFile.decode(Data(contentsOf: ReviewFile.url(for: sourceURL)))
            guard review.feedback.last?.body == "The reader should feel effortless.", try Data(contentsOf: sourceURL) == Data(original.utf8) else { throw Failure("Native suggestion failed source preservation") }
            passed.append("Rendered paragraph editing persists replacement Markdown separately")
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('read-mode').click()")
            try await wait(reader, "!document.body.classList.contains('suggesting')")

            try await selectComment(reader, quote: "calm and fast", body: "A draft across an agent edit.")
            let next = "An agent added an introduction.\n\n" + original
            let writer = try FileHandle(forWritingTo: sourceURL)
            try writer.truncate(atOffset: 0); try writer.write(contentsOf: Data(next.utf8)); try writer.close()
            try await wait(reader, "document.getElementById('notice-text').textContent.includes('source changed')")
            guard try await reader.webView.evaluateJavaScript("document.getElementById('comment-text').value") as? String == "A draft across an agent edit." else { throw Failure("External edit lost an active draft") }
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('save-comment').click()")
            try await wait(reader, "document.querySelectorAll('.feedback-card').length === 3 && document.getElementById('composer').hidden")
            review = try ReviewFile.decode(Data(contentsOf: ReviewFile.url(for: sourceURL)))
            guard review.source == next, review.feedback.allSatisfy({ $0.state == .attached }), review.feedback.last?.createdAgainst.sha256 == sha256(original) else { throw Failure("Draft provenance or rebasing failed") }
            passed.append("In-place source changes preserve drafts and rebase while retaining original provenance")
            let updatedDates = try SourceSnapshot.read(sourceURL)
            guard updatedDates.createdAt == originalDates.createdAt, updatedDates.revision.modifiedAt != originalDates.revision.modifiedAt else { throw Failure("File dates do not describe the in-place edit") }
            try await wait(reader, "document.getElementById('document-updated').dateTime === \(try ReviewFile.json(updatedDates.revision.modifiedAt, pretty: false))")
            passed.append("Document creation and update times come from disk and refresh after source edits")

            let rewritten = next.replacingOccurrences(of: "calm and fast", with: "clear and focused")
            try Data(rewritten.utf8).write(to: sourceURL, options: .atomic)
            try await wait(reader, "document.querySelectorAll('.feedback-card.conflict').length === 3")
            review = try ReviewFile.decode(Data(contentsOf: ReviewFile.url(for: sourceURL)))
            guard review.source == rewritten, review.feedback.allSatisfy({ $0.state == .conflict }) else { throw Failure("Atomic replacement did not surface conflicts") }
            passed.append("Atomic source replacement retains rewritten anchors as visible conflicts")

            try await selectComment(reader, quote: "clear and focused", body: "Do not lose this unsaved thought.")
            var external = review
            external.feedback[0].body = "Another reviewer edited the sidecar."
            external.feedback[0].updatedAt = ReviewClock.now()
            try ReviewFile.encode(external).write(to: ReviewFile.url(for: sourceURL), options: .atomic)
            try await wait(reader, "document.querySelector('.card-body')?.textContent === 'Another reviewer edited the sidecar.'")
            guard try await reader.webView.evaluateJavaScript("document.getElementById('comment-text').value") as? String == "Do not lose this unsaved thought." else { throw Failure("Incoming feedback lost the draft") }
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('save-comment').click()")
            try await wait(reader, "document.getElementById('composer').hidden && document.querySelectorAll('.feedback-card').length === 4")
            let merged = try ReviewFile.decode(Data(contentsOf: ReviewFile.url(for: sourceURL)))
            guard merged.feedback[0].body == external.feedback[0].body, merged.feedback.last?.body == "Do not lose this unsaved thought." else { throw Failure("Independent sidecar and comment updates did not merge") }
            passed.append("Independent external feedback edits merge while preserving active local drafts")
            let pdfSource = directory.appendingPathComponent("pdf-spec-\(UUID().uuidString).md")
            var pdfText = "# A quieter workspace\n\nA document exported directly from mdr.\n\n"
            for index in 1...7 {
                pdfText += "## Section \(index): Thoughtful review\n\n" + String(repeating: "A good reading experience leaves room for the idea. Reviewers can focus on the words, diagrams, and code, then leave feedback without disturbing the original. ", count: 4) + "\n\n"
                if index == 2 { pdfText += "```mermaid\ngraph LR\n A[First draft] --> B[Review]\n B --> C[Better draft]\n```\n\n" }
                if index == 4 { pdfText += "| Layer | Purpose | Owner |\n|---|---|---|\n| Source | The current idea | Author |\n| Review | Comments and suggestions | Reviewer |\n| History | Versions and provenance | Everyone |\n\n" }
                if index == 5 {
                    pdfText += "```typescript\n// Long lines wrap in the PDF; code keeps its indentation.\n"
                    for line in 1...45 { pdfText += "const item\(line) = { title: \"A deliberately long line of code that must remain readable on a printed page without clipping at the right margin\", sourceVersion: \(line) };\n" }
                    pdfText += "```\n\n"
                }
            }
            try Data(pdfText.utf8).write(to: pdfSource)
            let pdfReader = try ReaderWindow(url: pdfSource, owner: owner)
            owner.windows[pdfSource.path] = pdfReader
            try await wait(pdfReader, "!!document.querySelector('.mermaid svg') && document.querySelectorAll('.code-line').length > 40")
            _ = try await pdfReader.webView.evaluateJavaScript("document.querySelector('.suggest-code').click()")
            try await wait(pdfReader, "!!document.querySelector('.code-editor')")
            let codeProposal = "type Review = {\n  hash: string;\n  labels: string[];\n};\n"
            _ = try await pdfReader.webView.evaluateJavaScript("document.querySelector('.code-editor').value=\(try ReviewFile.json(codeProposal, pretty: false)); document.getElementById('save-edit').click()")
            try await wait(pdfReader, "document.querySelectorAll('.feedback-card').length === 1 && !document.querySelector('.code-editor')")
            let codeReview = try ReviewFile.decode(Data(contentsOf: ReviewFile.url(for: pdfSource)))
            guard codeReview.feedback[0].body == codeProposal, try Data(contentsOf: pdfSource) == Data(pdfText.utf8) else { throw Failure("Native code suggestion changed literal whitespace or the source") }
            passed.append("Native code suggestions retain exact indentation and punctuation without altering source")
            let info = pdfReader.printInfo()
            try "paper=\(info.paperSize), imageable=\(info.imageablePageBounds), scaling=\(info.scalingFactor), dictionary=\(info.dictionary())".write(to: directory.appendingPathComponent("print-info.txt"), atomically: true, encoding: .utf8)
            try await pdfReader.exportPDF(to: directory.appendingPathComponent("export-test.pdf"))
            let pdf = PDFDocument(url: directory.appendingPathComponent("export-test.pdf"))
            let exportedText = pdf?.string ?? ""
            guard (pdf?.pageCount ?? 0) > 1, exportedText.contains("Section 7"),
                  (1...45).allSatisfy({ exportedText.contains("item\($0) =") }) else {
                throw Failure("PDF clipped a code line or omitted the final section")
            }
            passed.append("Native paginated PDF exports text, Mermaid, tables, and a long code block")
            let report = ["ok": true, "checks": passed, "fixture": sourceURL.path] as [String: Any]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("native-smoke-report.json"))
            print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]), encoding: .utf8)!)
            reader.window.close()
            Darwin.exit(0)
        } catch {
            let report: [String: Any] = ["ok": false, "checks": passed, "error": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
                try? data.write(to: directory.appendingPathComponent("native-smoke-report.json"))
                print(String(data: data, encoding: .utf8)!)
            }
            Darwin.exit(1)
        }
    }
    static func wait(_ reader: ReaderWindow, _ expression: String) async throws {
        for _ in 0..<160 {
            if (try? await reader.webView.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure("Timed out: \(expression)")
    }
    static func selectComment(_ reader: ReaderWindow, quote: String, body: String) async throws {
        let q = try ReviewFile.json(quote, pretty: false)
        let b = try ReviewFile.json(body, pretty: false)
        let script = """
        (() => {
          const walker=document.createTreeWalker(document.getElementById('document'),NodeFilter.SHOW_TEXT);let node;
          while(node=walker.nextNode()){
            const start=node.textContent.indexOf(\(q));if(start<0)continue;
            const r=document.createRange();r.setStart(node,start);r.setEnd(node,start+\(q).length);
            window.getSelection().removeAllRanges();window.getSelection().addRange(r);
            window.mdr.command('comment');return true;
          }return false;
        })()
        """
        guard try await reader.webView.evaluateJavaScript(script) as? Bool == true else { throw Failure("Native test quote not found") }
        try await wait(reader, "!document.getElementById('composer').hidden")
        _ = try await reader.webView.evaluateJavaScript("document.getElementById('comment-text').value=\(b)")
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
