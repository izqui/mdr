#if DEBUG
import AppKit
import MDRCore

/// Hidden windows exercise actual WebKit clicks without touching the user's open reviews.
@MainActor enum NativeLinkSmoke {
    static func run(owner: AppDelegate, directory: URL) async {
        var passed: [String] = []
        do {
            let root = directory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            let sub = root.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("index.md")
            let target = sub.appendingPathComponent("Linked spec.MD")
            let original = "# Overview\n\nKeep this thought.\n\n[Linked spec](sub/Linked%20spec.MD#api-contract)\n\n[Missing](missing.md)\n"
            let linked = "# Linked spec\n\n" + String(repeating: "Some details to read.\n\n", count: 35)
                + "## API **contract**\n\n[Back](../index.md#overview)\n\n" + String(repeating: "More context.\n\n", count: 20)
            try Data(original.utf8).write(to: source)
            try Data(linked.utf8).write(to: target)
            let reader = try owner.openDocument(source, showWindow: false)
            try await NativeSmoke.wait(reader, "document.querySelector('#document h1')?.textContent === 'Overview'")
            try await NativeSmoke.selectComment(reader, quote: "Keep this thought", body: "An unfinished review stays here.")
            _ = try await reader.webView.evaluateJavaScript("document.querySelector('#document a').click()")
            let opened = try await waitForWindow(owner, target)
            try await NativeSmoke.wait(opened, "document.querySelector('#document h1')?.textContent === 'Linked spec' && document.getElementById('scroll-area').scrollTop > 100")
            try await NativeSmoke.wait(reader, "document.getElementById('comment-text').value === 'An unfinished review stays here.' && !document.getElementById('composer').hidden")
            guard reader.hasDraft, owner.windows.count == 2 else { throw NativeSmoke.Failure("Link lost a draft or opened the wrong number of windows") }
            passed.append("Clicking a relative link opens the real Markdown file with spaces and a heading fragment")
            passed.append("The original window and unfinished comment stay intact")

            _ = try await opened.webView.evaluateJavaScript("document.querySelector('#document a').click()")
            try await NativeSmoke.wait(reader, "document.getElementById('scroll-area').scrollTop < 100")
            // Wait for the link bridge to finish before checking window reuse.
            try await Task.sleep(nanoseconds: 200_000_000)
            guard owner.windows[source.path] === reader, owner.windows.count == 2, reader.hasDraft else { throw NativeSmoke.Failure("A parent-directory link failed to reuse the existing review") }
            passed.append("Parent-directory links reuse existing windows and preserve drafts")

            _ = try await reader.webView.evaluateJavaScript("document.querySelector('#document a[href=\"missing.md\"]').click()")
            try await NativeSmoke.wait(reader, "!document.getElementById('notice').hidden && document.getElementById('notice').classList.contains('warning')")
            guard owner.windows.count == 2, try Data(contentsOf: source) == Data(original.utf8),
                  try Data(contentsOf: target) == Data(linked.utf8),
                  !FileManager.default.fileExists(atPath: ReviewFile.url(for: source).path) else { throw NativeSmoke.Failure("Following links mutated the source or created a review") }
            passed.append("Missing files report an inline error; following links leaves source files untouched")
            try writeReport(["ok": true, "checks": passed], directory: directory)
            Darwin.exit(0)
        } catch {
            try? writeReport(["ok": false, "checks": passed, "error": error.localizedDescription], directory: directory)
            Darwin.exit(1)
        }
    }

    static func waitForWindow(_ owner: AppDelegate, _ url: URL) async throws -> ReaderWindow {
        for _ in 0..<100 {
            if let reader = owner.windows[url.standardizedFileURL.resolvingSymlinksInPath().path] { return reader }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NativeSmoke.Failure("The linked document did not open")
    }

    static func writeReport(_ report: [String: Any], directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("native-link-report.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
#endif
