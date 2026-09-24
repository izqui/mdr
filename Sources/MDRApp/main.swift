import AppKit
import WebKit
import UniformTypeIdentifiers
import MDRCore

private let readerResources = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("mdr_MDRApp.bundle")) } ?? Bundle.module

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [String: ReaderWindow] = [:]
    var initialPaths: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MDR_DEMO_DIR"] {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await NativeDemo.run(owner: self, directory: URL(fileURLWithPath: path)) }
            return
        }
        if let path = ProcessInfo.processInfo.environment["MDR_LIVE_TEST_DIR"] {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await NativeLiveSmoke.run(owner: self, directory: URL(fileURLWithPath: path)) }
            return
        }
        if let path = ProcessInfo.processInfo.environment["MDR_LINK_TEST_DIR"] {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await NativeLinkSmoke.run(owner: self, directory: URL(fileURLWithPath: path)) }
            return
        }
        if let path = ProcessInfo.processInfo.environment["MDR_INTEGRATION_TEST_DIR"] {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await NativeSmoke.run(owner: self, directory: URL(fileURLWithPath: path)) }
            return
        }
        #endif
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        for path in paths { open(URL(fileURLWithPath: path)) }
        for path in initialPaths { open(URL(fileURLWithPath: path)) }
        if windows.isEmpty { showWelcome() }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.offerCommandInstallation() }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if NSApp.mainMenu == nil { initialPaths.append(contentsOf: filenames) }
        else { filenames.forEach { open(URL(fileURLWithPath: $0)) } }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }; return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windows.values.allSatisfy { $0.confirmDiscard() } ? .terminateNow : .terminateCancel
    }

    func showWelcome() {
        if let existing = windows["welcome"] { existing.window.makeKeyAndOrderFront(nil); return }
        do {
            let reader = try ReaderWindow(url: nil, owner: self)
            windows["welcome"] = reader; reader.window.makeKeyAndOrderFront(nil)
        } catch { show(error) }
    }

    func open(_ url: URL) {
        do { try openDocument(url) } catch { show(error) }
    }

    @discardableResult
    func openDocument(_ url: URL, fragment: String? = nil, showWindow: Bool = true) throws -> ReaderWindow {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = windows[url.path] {
            if showWindow { existing.window.makeKeyAndOrderFront(nil) }
            existing.navigate(to: fragment)
            return existing
        }
        let reader = try ReaderWindow(url: url, owner: self)
        windows[url.path] = reader
        reader.navigate(to: fragment)
        if showWindow {
            reader.window.makeKeyAndOrderFront(nil)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            if let welcome = windows["welcome"], !welcome.hasDraft { welcome.window.close() }
        }
        return reader
    }

    @objc func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        panel.prompt = "Read"
        if panel.runModal() == .OK { panel.urls.forEach { open($0) } }
    }

    @objc func command(_ sender: NSMenuItem) {
        guard let reader = windows.values.first(where: { $0.window.isKeyWindow }), let action = sender.representedObject as? String else { return }
        reader.call("window.mdr.command", value: action)
    }

    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "mdr", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development", .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0", .credits: NSAttributedString(string: "A little room to think.\nRead beautifully. Leave a clear trail.")])
    }

    func show(_ error: Error) {
        let alert = NSAlert(error: error); alert.runModal()
    }

    func makeMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let app = NSMenu(); appItem.submenu = app
        app.addItem(withTitle: "About mdr", action: #selector(about), keyEquivalent: "").target = self
        app.addItem(withTitle: "Install Terminal Command…", action: #selector(installTerminalCommand), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide mdr", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit mdr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "File"); let fileItem = NSMenuItem(); fileItem.submenu = file; bar.addItem(fileItem)
        file.addItem(withTitle: "Open…", action: #selector(chooseFile), keyEquivalent: "o").target = self
        let recent = NSMenu(title: "Open Recent")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""); recentItem.submenu = recent; file.addItem(recentItem)
        for url in NSDocumentController.shared.recentDocumentURLs.prefix(10) {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url; item.target = self; recent.addItem(item)
        }
        file.addItem(.separator())
        addCommand(file, "Export as PDF…", "exportPDF", "p", [.command, .shift])
        addCommand(file, "Print…", "print", "p")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "Edit"); let editItem = NSMenuItem(); editItem.submenu = edit; bar.addItem(editItem)
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        addCommand(edit, "Find in Document…", "find", "f")
        let review = NSMenu(title: "Review"); let reviewItem = NSMenuItem(); reviewItem.submenu = review; bar.addItem(reviewItem)
        addCommand(review, "Comment on Selection", "comment", "m", [.command, .option])
        addCommand(review, "Suggest Changes", "suggest", "e", [.command, .shift])
        addCommand(review, "Show Feedback", "feedback", "r", [.command, .shift])
        addCommand(review, "Reveal Feedback File", "reveal", "r", [.command, .option])
        let view = NSMenu(title: "View"); let viewItem = NSMenuItem(); viewItem.submenu = view; bar.addItem(viewItem)
        addCommand(view, "Toggle Outline", "outline", "b")
        addCommand(view, "Increase Text Size", "zoomIn", "+")
        addCommand(view, "Decrease Text Size", "zoomOut", "-")
        addCommand(view, "Reset Text Size", "zoomReset", "0")
        view.addItem(.separator())
        addCommand(view, "Appearance & Reviewer…", "settings", ",")
        let window = NSMenu(title: "Window"); let windowItem = NSMenuItem(); windowItem.submenu = window; bar.addItem(windowItem)
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window; NSApp.mainMenu = bar
    }

    @objc func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { open(url) } }

    func addCommand(_ menu: NSMenu, _ title: String, _ action: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title, action: #selector(command(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers; item.representedObject = action; item.target = self; menu.addItem(item)
    }
}

@MainActor
final class ReaderWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let window: NSWindow
    let webView: WKWebView
    let sourceURL: URL?
    weak var owner: AppDelegate?
    var snapshot: SourceSnapshot
    var review: Review
    var diskHash: String?
    var snapshots: [String: SourceSnapshot] = [:]
    var hasDraft = false
    var draftIsSaved = false
    var watcher: DispatchSourceFileSystemObject?
    var fileWatchers: [DispatchSourceFileSystemObject] = []
    var debounce: DispatchWorkItem?
    var ready = false
    var pendingFragment: String?
    var notice: String? = nil
    var lastWarning: String?
    var exportContinuation: CheckedContinuation<Void, Error>?
    var exportDestination: URL?
    var exportTemporary: URL?
    var activePrintOperation: NSPrintOperation?

    init(url: URL?, owner: AppDelegate) throws {
        self.owner = owner; sourceURL = url
        if let url {
            guard !url.lastPathComponent.hasSuffix(".feedback.md") else { throw MDRError.invalidDocument("Open the original Markdown document. mdr will load its .feedback.md automatically.") }
            snapshot = try SourceSnapshot.read(url)
        } else {
            let guide = readerResources.url(forResource: "welcome", withExtension: "md", subdirectory: "Web")!
            snapshot = try SourceSnapshot.read(guide)
        }
        review = Review(sourcePath: url?.path ?? "Welcome", snapshot: snapshot)
        if let url, FileManager.default.fileExists(atPath: ReviewFile.url(for: url).path) {
            let data = try Data(contentsOf: ReviewFile.url(for: url))
            review = try ReviewFile.decode(data)
            guard review.sourcePath == url.path || review.revision.sha256 == snapshot.revision.sha256 || !FileManager.default.fileExists(atPath: review.sourcePath) else {
                throw MDRError.invalidFeedback("This feedback file belongs to another source document: \(review.sourcePath). Rename one of the documents so each has its own feedback file.")
            }
            // A moved document and its sidecar can travel together.
            review.sourcePath = url.path
            diskHash = sha256(data)
            if review.revision.sha256 != snapshot.revision.sha256 {
                let count = review.rebase(to: snapshot)
                diskHash = try ReviewFile.save(review, to: ReviewFile.url(for: url), expectedDiskHash: diskHash)
                notice = count == 0 ? "Source updated. Your feedback followed the text." : "Source updated. \(count) \(count == 1 ? "note needs" : "notes need") a new anchor."
            }
        }
        snapshots[snapshot.revision.sha256] = snapshot
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = url?.lastPathComponent ?? "mdr"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        window.minSize = NSSize(width: 780, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("mdr.reader")
        window.center()
        window.contentView = webView
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        config.userContentController.add(self, name: "mdr")
        let html = readerResources.url(forResource: "index", withExtension: "html", subdirectory: "Web")!
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        if let url { watch(url.deletingLastPathComponent()); watchFiles() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscard() }
    func windowWillClose(_ notification: Notification) {
        watcher?.cancel(); fileWatchers.forEach { $0.cancel() }; debounce?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mdr")
        owner?.windows.removeValue(forKey: sourceURL?.path ?? "welcome")
    }
    func windowDidBecomeKey(_ notification: Notification) { refreshFromDisk() }

    func confirmDiscard() -> Bool {
        guard hasDraft && !draftIsSaved else { return true }
        let alert = NSAlert()
        alert.messageText = "Your latest feedback hasn't saved yet."
        alert.informativeText = "Keep reviewing to finish saving. Closing now keeps the last saved draft but loses any newer changes."
        alert.addButton(withTitle: "Keep Reviewing"); alert.addButton(withTitle: "Close Without Latest Changes")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func watch(_ directory: URL) {
        let fd = Darwin.open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshFromDisk() }
            self?.debounce = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { Darwin.close(fd) }
        watcher = source; source.resume()
    }

    func watchFiles() {
        fileWatchers.forEach { $0.cancel() }; fileWatchers = []
        guard let sourceURL else { return }
        for url in [sourceURL, ReviewFile.url(for: sourceURL)] {
            let fd = Darwin.open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                self?.debounce?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.refreshFromDisk() }
                self?.debounce = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
            source.setCancelHandler { Darwin.close(fd) }
            fileWatchers.append(source); source.resume()
        }
    }

    func refreshFromDisk() {
        guard let url = sourceURL, ready else { return }
        defer { watchFiles() }
        do {
            let latest = try SourceSnapshot.read(url)
            let feedbackURL = ReviewFile.url(for: url)
            let bytes = FileManager.default.fileExists(atPath: feedbackURL.path) ? try Data(contentsOf: feedbackURL) : nil
            var nextHash = bytes.map { sha256($0) }
            let external = nextHash != diskHash
            var next = external ? (try bytes.map { try ReviewFile.decode($0) } ?? Review(sourcePath: url.path, snapshot: latest)) : review
            try validateSource(next, url: url, snapshot: latest)
            let changed = latest.revision != snapshot.revision || next.revision.sha256 != latest.revision.sha256
            if changed {
                if nextHash != nil {
                    let result = try ReviewFile.update(at: feedbackURL) { current in
                        try validateSource(current, url: url, snapshot: latest)
                        current.sourcePath = url.path; current.rebase(to: latest)
                    }
                    next = result.review; nextHash = result.hash
                } else { next.rebase(to: latest) }
                notice = "Source updated. Feedback has been checked against the new text."
            } else if external { notice = "Feedback updated from disk." }
            next.sourcePath = url.path
            review = next; diskHash = nextHash; snapshot = latest; snapshots[latest.revision.sha256] = latest
            if changed || external { sendState() }
            lastWarning = nil
        } catch {
            let message = error.localizedDescription
            if lastWarning != message { lastWarning = message; call("window.mdr.warning", value: message) }
        }
    }

    func validateSource(_ review: Review, url: URL, snapshot: SourceSnapshot) throws {
        guard review.sourcePath == url.path || review.revision.sha256 == snapshot.revision.sha256 || !FileManager.default.fileExists(atPath: review.sourcePath) else {
            throw MDRError.invalidFeedback("This feedback file belongs to another source document.")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any], let action = data["action"] as? String else { return }
        let requestID = data["requestId"] as? String
        do {
            switch action {
            case "ready":
                ready = true; sendState()
                if let fragment = pendingFragment { pendingFragment = nil; navigate(to: fragment) }
            case "open": owner?.chooseFile()
            case "openLink":
                guard let href = data["href"] as? String else { break }
                switch try MarkdownLink.resolve(href, from: sourceURL) {
                case .heading(let fragment): navigate(to: fragment)
                case .document(let url, let fragment):
                    try owner?.openDocument(url, fragment: fragment, showWindow: window.isVisible)
                case .external(let url): NSWorkspace.shared.open(url)
                }
            case "exportPDF": choosePDFDestination()
            case "print": printDocument()
            case "dirty": hasDraft = data["value"] as? Bool ?? false; draftIsSaved = data["saved"] as? Bool ?? false
            case "setAuthor":
                let name = (data["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw MDRError.invalidFeedback("Enter your name so the agent knows who left the feedback.") }
                UserDefaults.standard.set(name, forKey: "reviewerName")
            case "setPreference":
                if let key = data["key"] as? String {
                    if key == "theme", let value = data["value"] as? String, ["paper", "light", "dark", "system"].contains(value) { UserDefaults.standard.set(value, forKey: "theme") }
                    if key == "fontSize", let value = data["value"] as? Int, (14...26).contains(value) { UserDefaults.standard.set(value, forKey: "fontSize") }
                }
            case "copyText":
                if let value = data["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
            case "image":
                guard let sourceURL, let path = data["path"] as? String,
                      let imageURL = URL(string: path, relativeTo: sourceURL.deletingLastPathComponent().appendingPathComponent(""))?.absoluteURL,
                      imageURL.isFileURL else { break }
                let resolved = imageURL.resolvingSymlinksInPath().standardizedFileURL
                let parent = sourceURL.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
                guard resolved.path.hasPrefix(parent), let type = UTType(filenameExtension: resolved.pathExtension), type.conforms(to: .image),
                      let mime = type.preferredMIMEType else { break }
                let bytes = try Data(contentsOf: resolved)
                guard bytes.count <= 20_000_000 else { break }
                if let requestID { call("window.mdr.resolve", arguments: [requestID, ["ok": true, "dataURL": "data:\(mime);base64,\(bytes.base64EncodedString())"]]); return }
            case "reveal":
                guard let sourceURL else { break }
                let path = diskHash == nil ? sourceURL : ReviewFile.url(for: sourceURL)
                NSWorkspace.shared.activateFileViewerSelecting([path])
            case "copyPath":
                guard let sourceURL else { break }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ReviewFile.url(for: sourceURL).path, forType: .string)
            case "saveFeedback":
                let edit = try JSONDecoder().decode(FeedbackEdit.self, from: JSONSerialization.data(withJSONObject: data))
                let original = snapshots[edit.sourceHash]
                try mutateReview { current, latest in
                    try current.saveFeedback(edit, author: reviewerName, original: original, current: latest)
                }
            case "saveReply":
                let edit = try JSONDecoder().decode(ReplyEdit.self, from: JSONSerialization.data(withJSONObject: data))
                try mutateReview { current, latest in try current.saveReply(edit, author: reviewerName, current: latest) }
            case "discardReply":
                guard let id = data["id"] as? String, let threadID = data["threadID"] as? String, let body = data["baseBody"] as? String else { throw MDRError.invalidAnchor }
                try mutateReview { current, _ in try current.discardDraft(id: id, threadID: threadID, baseBody: body) }
            case "addFeedback":
                guard let kind = FeedbackKind(rawValue: data["kind"] as? String ?? ""),
                      let start = data["start"] as? Int, let end = data["end"] as? Int,
                      let hash = data["sourceHash"] as? String, let original = snapshots[hash] else { throw MDRError.invalidAnchor }
                let item = try Feedback(kind: kind, author: reviewerName, body: data["body"] as? String ?? "", snapshot: original, start: start, end: end)
                guard item.anchor.exact == data["exact"] as? String else { throw MDRError.invalidAnchor }
                try mutateReview { current, latest in current.add(item, against: latest) }
            case "resolve", "delete", "reattach", "discardDraft":
                try mutateReview { current, latest in
                    guard let id = data["id"] as? String else { throw MDRError.invalidAnchor }
                    guard let index = current.feedback.firstIndex(where: { $0.id == id }) else {
                        if action == "discardDraft" { return }
                        throw MDRError.invalidFeedback("This feedback no longer exists.")
                    }
                    if action == "discardDraft" {
                        guard let body = data["baseBody"] as? String else { throw MDRError.invalidAnchor }
                        try current.discardDraft(id: id, baseBody: body)
                    } else if action == "delete" { current.feedback.remove(at: index) }
                    else if action == "resolve" { current.feedback[index].resolved.toggle(); current.feedback[index].updatedAt = ReviewClock.now() }
                    else {
                        guard data["sourceHash"] as? String == latest.revision.sha256,
                              let start = data["start"] as? Int, let end = data["end"] as? Int else { throw MDRError.invalidAnchor }
                        let anchor = try TextAnchor(text: latest.text, start: start, end: end)
                        guard anchor.exact == data["exact"] as? String else { throw MDRError.invalidAnchor }
                        current.feedback[index].anchor = anchor; current.feedback[index].state = .attached; current.feedback[index].updatedAt = ReviewClock.now()
                    }
                }
            case "reload":
                // A cancelled or posted draft can now display the latest source.
                hasDraft = false; refreshFromDisk(); sendState()
            default: break
            }
            if let requestID { call("window.mdr.resolve", arguments: [requestID, ["ok": true]]) }
        } catch {
            if let requestID { call("window.mdr.resolve", arguments: [requestID, ["ok": false, "error": error.localizedDescription, "retryable": (error as? MDRError).map { if case .busy = $0 { return true }; return false } ?? false]]) }
            else { call("window.mdr.warning", value: error.localizedDescription) }
        }
    }

    var reviewerName: String { UserDefaults.standard.string(forKey: "reviewerName") ?? (NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()) }

    func navigate(to fragment: String?) {
        guard let fragment else { return }
        if ready { call("window.mdr.navigateToHeading", value: fragment) }
        else { pendingFragment = fragment }
    }

    func choosePDFDestination() {
        guard !hasDraft else { call("window.mdr.warning", value: "Save or cancel your current feedback before exporting."); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (sourceURL?.deletingPathExtension().lastPathComponent ?? "mdr field guide") + ".pdf"
        panel.directoryURL = sourceURL?.deletingLastPathComponent()
        panel.prompt = "Export PDF"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do { try await self.exportPDF(to: url); self.call("window.mdr.exported", value: "PDF exported to \(url.lastPathComponent).") }
                catch { self.call("window.mdr.warning", value: error.localizedDescription) }
            }
        }
    }

    func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        if info.paperSize.width < 200 || info.paperSize.height < 200 { info.paperSize = NSSize(width: 612, height: 792) }
        info.scalingFactor = 1
        info.topMargin = 48; info.bottomMargin = 48; info.leftMargin = 48; info.rightMargin = 48
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = false
        return info
    }

    func exportPDF(to url: URL) async throws {
        guard exportContinuation == nil else { throw MDRError.invalidDocument("A PDF export is already in progress.") }
        let info = printInfo()
        info.jobDisposition = .save
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".mdr-export-\(UUID().uuidString).pdf")
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporary
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false; operation.showsProgressPanel = false
        operation.jobTitle = sourceURL?.deletingPathExtension().lastPathComponent ?? "mdr"
        operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        exportDestination = url; exportTemporary = temporary; activePrintOperation = operation
        // WebKit computes the page range asynchronously. A synchronous run() can print empty pages.
        try await withCheckedThrowingContinuation { continuation in
            exportContinuation = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(pdfExportFinished(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc func pdfExportFinished(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let continuation = exportContinuation
        defer {
            if let temporary = exportTemporary { try? FileManager.default.removeItem(at: temporary) }
            exportContinuation = nil; exportDestination = nil; exportTemporary = nil; activePrintOperation = nil
        }
        do {
            guard success, let temporary = exportTemporary, let destination = exportDestination else { throw MDRError.invalidDocument("The PDF export did not complete. Your existing files were left untouched.") }
            let data = try Data(contentsOf: temporary)
            guard data.starts(with: Data("%PDF".utf8)) else { throw MDRError.invalidDocument("The PDF could not be generated.") }
            try data.write(to: destination, options: .atomic)
            continuation?.resume()
        } catch { continuation?.resume(throwing: error) }
    }

    func printDocument() {
        guard !hasDraft else { call("window.mdr.warning", value: "Save or cancel your current feedback before printing."); return }
        let operation = webView.printOperation(with: printInfo())
        operation.showsPrintPanel = true; operation.showsProgressPanel = true
        operation.jobTitle = sourceURL?.lastPathComponent ?? "mdr"
        operation.view?.frame = NSRect(origin: .zero, size: operation.printInfo.paperSize)
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func mutateReview(_ mutation: (inout Review, SourceSnapshot) throws -> Void) throws {
        guard let url = sourceURL else { throw MDRError.invalidFeedback("Open a Markdown file to start reviewing.") }
        let latest = try SourceSnapshot.read(url)
        let result = try ReviewFile.update(at: ReviewFile.url(for: url), initial: Review(sourcePath: url.path, snapshot: latest)) { current in
            try validateSource(current, url: url, snapshot: latest)
            current.sourcePath = url.path; current.rebase(to: latest)
            try mutation(&current, latest)
        }
        snapshot = latest; snapshots[latest.revision.sha256] = latest
        review = result.review; diskHash = result.hash
        sendState(); watchFiles()
    }

    func sendState() {
        guard ready else { return }
        do {
            let revision = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.revision))
            let items = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review.feedback))
            let value: [String: Any] = ["source": snapshot.text, "revision": revision, "feedback": items,
                "fileName": sourceURL?.lastPathComponent ?? "The mdr field guide", "filePath": sourceURL?.path ?? "",
                "feedbackPath": sourceURL.map { ReviewFile.url(for: $0).path } ?? "", "author": reviewerName,
                "hasSidecar": diskHash != nil, "isWelcome": sourceURL == nil, "notice": notice ?? "",
                "theme": UserDefaults.standard.string(forKey: "theme") ?? "paper",
                "fontSize": UserDefaults.standard.object(forKey: "fontSize") as? Int ?? 18]
            call("window.mdr.receive", value: value)
            notice = nil
        } catch { owner?.show(error) }
    }

    func call(_ function: String, value: Any) { call(function, arguments: [value]) }
    func call(_ function: String, arguments: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed]), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("\(function)(...\(json))") { _, error in
            if let error { NSLog("mdr bridge: %@", error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else if navigationAction.request.url?.isFileURL == true { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
}

if ["--help", "-h"].contains(CommandLine.arguments.dropFirst().first ?? "") {
    print(FeedbackCLI.usage)
    Darwin.exit(0)
}
if CommandLine.arguments.dropFirst().first == "--skill" {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    if !arguments.isEmpty {
        do {
            guard arguments.count == 2, arguments[0] == "--install",
                  let source = readerResources.url(forResource: "mdr-agent-skill", withExtension: nil, subdirectory: "Web") else {
                throw MDRError.invalidDocument("Usage: mdr skill [--install DIRECTORY]")
            }
            let destination = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            try ToolInstallation.installSkill(from: source, to: destination)
            print("Installed mdr skill at \(destination.path)")
            Darwin.exit(0)
        } catch {
            FileHandle.standardError.write(Data("mdr: \(error.localizedDescription)\n".utf8)); Darwin.exit(1)
        }
    }
    if let url = readerResources.url(forResource: "mdr-skill", withExtension: "md", subdirectory: "Web"), let guide = try? String(contentsOf: url, encoding: .utf8) {
        print(guide); Darwin.exit(0)
    }
    FileHandle.standardError.write(Data("mdr: The agent guide is missing. Rebuild the app.\n".utf8)); Darwin.exit(1)
}
if CommandLine.arguments.dropFirst().first == "--install-cli" {
    do {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard arguments.count <= 1 else { throw MDRError.invalidDocument("Usage: mdr --install-cli [DIRECTORY]") }
        let directory = arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let destination = try ToolInstallation.installCommand(app: Bundle.main.bundleURL, directory: directory)
        print("Installed \(destination.path)")
        print("Add its directory to PATH if needed. For the default location: export PATH=\"$HOME/.local/bin:$PATH\"")
        Darwin.exit(0)
    } catch {
        FileHandle.standardError.write(Data("mdr: \(error.localizedDescription)\n".utf8)); Darwin.exit(1)
    }
}
if CommandLine.arguments.dropFirst().first == "--feedback" {
    Darwin.exit(FeedbackCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
