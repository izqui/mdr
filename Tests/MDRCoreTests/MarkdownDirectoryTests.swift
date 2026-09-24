import XCTest
@testable import MDRCore

final class MarkdownDirectoryTests: XCTestCase {
    func fixture() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/directory-tests/\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testShallowListingSortsFoldersFirstAndDisablesUnsupportedFiles() throws {
        let root = try fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
        for name in ["README.MD", "spec 10.markdown", "spec 2.md", "image.png", "README.feedback.md", ".hidden.md"] {
            try Data("# Fixture".utf8).write(to: root.appendingPathComponent(name))
        }
        let folder = try MarkdownDirectory(root), entries = try folder.contents()
        XCTAssertEqual(entries.first?.name, "nested")
        XCTAssertFalse(entries.contains { $0.path.contains("deeper") || $0.name == ".hidden.md" })
        XCTAssertEqual(entries.filter { !$0.isDirectory && $0.enabled }.map(\.name), ["README.MD", "spec 2.md", "spec 10.markdown"])
        XCTAssertNotNil(entries.first { $0.name == "image.png" }?.reason)
        XCTAssertFalse(entries.first { $0.name == "README.feedback.md" }!.enabled)
        XCTAssertEqual(try folder.contents("nested").first?.path, "nested/deeper")
        XCTAssertTrue(try folder.contents("nested/deeper").isEmpty)
    }

    func testNamesAreLiteralAndTraversalCannotLeaveRoot() throws {
        let root = try fixture(), folder = try MarkdownDirectory(root)
        let name = "Plan #1 100% café.md", file = root.appendingPathComponent(name)
        try Data("# Plan".utf8).write(to: file)
        XCTAssertEqual(try folder.document(name), file)
        XCTAssertEqual(folder.relativePath(for: file), name)
        XCTAssertFalse(folder.contains(root.appendingPathExtension("sibling").appendingPathComponent("spec.md")))
        for path in ["../elsewhere.md", "/tmp/spec.md", "child/../../spec.md"] { XCTAssertThrowsError(try folder.document(path)) }
        for name in ["script.py", "review.feedback.md"] {
            try Data("text".utf8).write(to: root.appendingPathComponent(name))
            XCTAssertThrowsError(try folder.document(name))
        }
        XCTAssertThrowsError(try folder.document("missing.md"))
    }

    func testDirectorySymlinksCannotRecurseOrEscape() throws {
        let root = try fixture(), folder = try MarkdownDirectory(root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertTrue(try folder.contents().allSatisfy { !$0.enabled })
        XCTAssertThrowsError(try folder.contents("loop"))
        XCTAssertThrowsError(try folder.contents("outside"))
    }
}
