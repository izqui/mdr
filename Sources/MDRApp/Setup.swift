import AppKit
import MDRCore

@MainActor
extension AppDelegate {
    func offerCommandInstallation() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              !UserDefaults.standard.bool(forKey: "offeredCommandInstallation") else { return }
        UserDefaults.standard.set(true, forKey: "offeredCommandInstallation")
        let alert = NSAlert()
        alert.messageText = "Open documents from Terminal"
        alert.informativeText = "Install the mdr command in ~/.local/bin to open files and let your agent read and reply to feedback. You can do this later from the mdr menu.\n\nMove mdr to Applications first. Your shell configuration stays under your control."
        alert.addButton(withTitle: "Install Command")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { installTerminalCommand() }
    }

    @objc func installTerminalCommand() {
        do {
            // App Translocation and mounted disk images are temporary locations.
            let app = Bundle.main.bundleURL
            guard !app.path.contains("/AppTranslocation/"), !app.path.hasPrefix("/Volumes/") else {
                throw MDRError.invalidDocument("Drag mdr to Applications, open that copy, then choose mdr → Install Terminal Command… again.")
            }
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
            let destination = try ToolInstallation.installCommand(app: app, directory: directory)
            let alert = NSAlert()
            alert.messageText = "The mdr command is installed"
            alert.informativeText = "Installed at \(destination.path)\n\nTry: mdr --help\n\nIf your shell cannot find mdr, add this line to ~/.zshrc (or your shell’s configuration), then open a new Terminal:\n\nexport PATH=\"$HOME/.local/bin:$PATH\""
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Copy PATH Line")
            if alert.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("export PATH=\"$HOME/.local/bin:$PATH\"", forType: .string)
            }
        } catch { show(error) }
    }
}
