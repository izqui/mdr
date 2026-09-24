import Foundation

/// Enumerate one folder at a time. Expanding a tree never walks the whole project.
public struct MarkdownDirectory: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let name: String
        public let path: String
        public let isDirectory: Bool
        public let enabled: Bool
        public let reason: String?
    }

    public let root: URL

    public init(_ root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try self.root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw MDRError.invalidDocument("Choose a folder containing Markdown files.")
        }
    }

    public func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root.path || path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
    }

    public func relativePath(for url: URL) -> String? {
        guard contains(url) else { return nil }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root.path ? "" : String(path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
    }

    public func url(for path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw MDRError.invalidDocument("This item is outside the open folder.")
        }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard contains(url) else { throw MDRError.invalidDocument("This item is outside the open folder.") }
        return url
    }

    public func contents(_ path: String = "") throws -> [Entry] {
        let directory = try url(for: path)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MDRError.invalidDocument("This folder can no longer be opened. Refresh the file list.")
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]).map { child in
            let attributes = try? child.resourceValues(forKeys: keys)
            let folder = attributes?.isDirectory == true
            let reason: String?
            if attributes?.isSymbolicLink == true { reason = "Symbolic links are not followed in the folder browser." }
            else if attributes?.isPackage == true { reason = "App and document packages cannot be opened here." }
            else if folder { reason = nil }
            else if child.lastPathComponent.lowercased().hasSuffix(".feedback.md") { reason = "Feedback file. Open its original document to review the conversation." }
            else if attributes?.isRegularFile != true || !Self.isMarkdown(child) { reason = "mdr opens .md and .markdown files." }
            else { reason = nil }
            return Entry(name: child.lastPathComponent, path: path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent,
                         isDirectory: folder, enabled: reason == nil, reason: reason)
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public func document(_ path: String) throws -> URL {
        let file = try url(for: path)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Self.isMarkdown(file),
              !file.lastPathComponent.lowercased().hasSuffix(".feedback.md") else {
            throw MDRError.invalidDocument("Choose an original .md or .markdown document.")
        }
        return file.resolvingSymlinksInPath()
    }

    public static func isMarkdown(_ url: URL) -> Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }
}
