import Foundation
import Darwin

/// User-scoped setup shared by the app menu and the headless command.
public enum ToolInstallation {
    public static func installCommand(app: URL, directory: URL) throws -> URL {
        let manager = FileManager.default
        let launcher = app.appendingPathComponent("Contents/Resources/mdr")
        guard manager.isExecutableFile(atPath: launcher.path) else {
            throw MDRError.invalidDocument("Install mdr.app in Applications before setting up the command.")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("mdr")
        if let target = try? manager.destinationOfSymbolicLink(atPath: destination.path) {
            guard target.hasSuffix("/mdr.app/Contents/Resources/mdr") else {
                throw MDRError.invalidDocument("Another command already exists at \(destination.path). Move it aside or choose another directory.")
            }
        } else if manager.fileExists(atPath: destination.path) {
            // Recognize mdr's original installer so existing users can upgrade.
            let previous = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
            guard previous.hasPrefix("#!/bin/zsh\n"), previous.contains("MDR_INSTALLED_APP=\"$HOME/Applications/mdr.app\"") else {
                throw MDRError.invalidDocument("Another command already exists at \(destination.path). Move it aside or choose another directory.")
            }
        }
        let temporary = directory.appendingPathComponent(".mdr-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        try manager.createSymbolicLink(at: temporary, withDestinationURL: launcher)
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return destination
    }

    public static func installSkill(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw MDRError.invalidDocument("The agent skill is missing. Reinstall mdr.")
        }
        guard !manager.fileExists(atPath: destination.path),
              (try? manager.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw MDRError.invalidDocument("A skill already exists at \(destination.path). Move the old folder aside before installing an update.")
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: source, to: destination)
    }
}
