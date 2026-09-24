import XCTest
@testable import MDRCore

final class ToolInstallationTests: XCTestCase {
    func testCommandInstallationIsPortableAndProtectsOtherCommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Apps with spaces/mdr.app")
        let launcher = app.appendingPathComponent("Contents/Resources/mdr")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/zsh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let directory = root.appendingPathComponent("bin with spaces")
        let command = try ToolInstallation.installCommand(app: app, directory: directory)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: command.path), launcher.path)
        XCTAssertEqual(try ToolInstallation.installCommand(app: app, directory: directory), command)
        // An app moved by Finder leaves a stale link; reinstall repairs it.
        let moved = root.appendingPathComponent("Other Apps/mdr.app")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: app, to: moved)
        _ = try ToolInstallation.installCommand(app: moved, directory: directory)
        XCTAssertEqual(command.resolvingSymlinksInPath(), moved.appendingPathComponent("Contents/Resources/mdr"))
        try FileManager.default.removeItem(at: command)
        try Data("my unrelated command".utf8).write(to: command)
        XCTAssertThrowsError(try ToolInstallation.installCommand(app: moved, directory: directory))
        XCTAssertEqual(try String(contentsOf: command, encoding: .utf8), "my unrelated command")
        try FileManager.default.removeItem(at: command)
        try FileManager.default.createSymbolicLink(atPath: command.path, withDestinationPath: "/missing/other-command")
        XCTAssertThrowsError(try ToolInstallation.installCommand(app: moved, directory: directory))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: command.path), "/missing/other-command")
    }

    func testSkillInstallationKeepsExistingCustomizations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("---\nname: mdr\n---\nReview together.".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let destination = root.appendingPathComponent("agent skills/mdr")
        try ToolInstallation.installSkill(from: source, to: destination)
        try Data("customized skill".utf8).write(to: destination.appendingPathComponent("SKILL.md"))
        XCTAssertThrowsError(try ToolInstallation.installSkill(from: source, to: destination))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8), "customized skill")
    }
}
