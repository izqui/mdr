#if DEBUG
import AppKit
import MDRCore

@MainActor enum NativeFolderSmoke {
    static func run(owner: AppDelegate, directory: URL) async {
        var checks: [String] = []
        do {
            let root = directory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            let nested = root.appendingPathComponent("design")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("README.md"), twin = root.appendingPathComponent("Same text.md")
            let deep = nested.appendingPathComponent("Plan #1.md")
            let body = "# Workspace overview\n\nKeep this review with its document.\n\n[Design](design/Plan%20%231.md#contract)\n"
            try Data(body.utf8).write(to: source); try Data(body.utf8).write(to: twin)
            try Data("# Nested design\n\n## Contract\n\nA precise API contract.\n".utf8).write(to: deep)
            try Data("print('fixture')".utf8).write(to: root.appendingPathComponent("helper.py"))
            try Data([0xff, 0xfe]).write(to: root.appendingPathComponent("invalid.md"))
            let reader = try owner.openDocument(root, showWindow: false)
            try await NativeSmoke.wait(reader, "document.querySelector('#file-tree [data-path=\"README.md\"]') !== null")
            try await NativeSmoke.wait(reader, "document.querySelector('#file-tree [data-path=\"helper.py\"]').getAttribute('aria-disabled') === 'true'")
            _ = try await reader.webView.evaluateJavaScript("document.querySelector('#file-tree [data-path=\"design\"] > .file-row').click()")
            try await NativeSmoke.wait(reader, "document.querySelector('#file-tree [data-path=\"design/Plan #1.md\"]') !== null")
            checks.append("A directory opens a lazy nested tree and dims unsupported files")

            try await click(reader, path: "README.md", heading: "Workspace overview")
            try await NativeSmoke.selectComment(reader, quote: "Keep this review", body: "Keep this draft on the original file.")
            try await click(reader, path: "Same text.md", heading: "Workspace overview")
            guard reader.sourceURL == twin, owner.windows.count == 1 else { throw NativeSmoke.Failure("The folder did not reuse its window") }
            try await NativeSmoke.wait(reader, "document.getElementById('composer').hidden && document.getElementById('feedback-count').textContent === '0'")
            let saved = try ReviewFile.decode(Data(contentsOf: ReviewFile.url(for: source)))
            guard saved.feedback.count == 1, saved.feedback[0].isDraft, saved.feedback[0].body == "Keep this draft on the original file.", !FileManager.default.fileExists(atPath: ReviewFile.url(for: twin).path) else {
                throw NativeSmoke.Failure("A draft crossed into an identical document or failed to save")
            }
            checks.append("Switching saves unfinished feedback and keeps identical files separate")

            try await click(reader, path: "README.md", heading: "Workspace overview")
            _ = try await reader.webView.evaluateJavaScript("document.getElementById('feedback-toggle').click(); document.querySelector('[data-action=resume]').click()")
            try await NativeSmoke.wait(reader, "document.getElementById('comment-text').value === 'Keep this draft on the original file.' && !document.getElementById('composer').hidden")
            _ = try await reader.webView.evaluateJavaScript("document.querySelector('#document a').click()")
            try await NativeSmoke.wait(reader, "document.querySelector('#document h1')?.textContent === 'Nested design'")
            guard reader.sourceURL == deep, owner.windows.count == 1 else { throw NativeSmoke.Failure("A relative link escaped the folder window") }
            checks.append("Drafts resume and relative Markdown links stay in the folder window")

            _ = try await reader.webView.evaluateJavaScript("document.querySelector('#file-tree [data-path=\"invalid.md\"] > .file-row').click()")
            try await NativeSmoke.wait(reader, "document.getElementById('notice-text').textContent.includes('UTF-8')")
            guard reader.sourceURL == deep else { throw NativeSmoke.Failure("An unreadable file replaced the current review") }
            checks.append("Failed opens preserve the current document")

            let added = nested.appendingPathComponent("New spec.md")
            try Data("# New spec\n\nCreated by an agent.\n".utf8).write(to: added)
            try await NativeSmoke.wait(reader, "document.querySelector('#file-tree [data-path=\"design/New spec.md\"]') !== null")
            try FileManager.default.removeItem(at: added)
            try await NativeSmoke.wait(reader, "document.querySelector('#file-tree [data-path=\"design/New spec.md\"]') === null")
            checks.append("Expanded folders refresh when files are created and removed")
            guard try Data(contentsOf: source) == Data(body.utf8), try Data(contentsOf: twin) == Data(body.utf8) else { throw NativeSmoke.Failure("Browsing changed a source file") }
            reader.window.close()
            guard owner.windows.isEmpty else { throw NativeSmoke.Failure("Closing the folder leaked its window registration") }
            checks.append("Closing the folder removes its registration and observers")
            try report(["ok": true, "checks": checks], directory)
            Darwin.exit(0)
        } catch {
            try? report(["ok": false, "checks": checks, "error": error.localizedDescription], directory)
            Darwin.exit(1)
        }
    }

    static func click(_ reader: ReaderWindow, path: String, heading: String) async throws {
        let pathJSON = try ReviewFile.json(path, pretty: false)
        _ = try await reader.webView.evaluateJavaScript("[...document.querySelectorAll('#file-tree [role=treeitem]')].find(item => item.dataset.path === \(pathJSON)).querySelector('.file-row').click()")
        try await NativeSmoke.wait(reader, "document.querySelector('#document h1')?.textContent === \(try ReviewFile.json(heading, pretty: false)) && document.getElementById('file-name').textContent === \(try ReviewFile.json(URL(fileURLWithPath: path).lastPathComponent, pretty: false))")
    }

    static func report(_ value: [String: Any], _ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("native-folder-report.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
#endif
