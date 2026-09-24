import Foundation
import MDRCore

/// Watch only the root and expanded folders, independently of document watchers.
@MainActor final class FolderObservation {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    let directory: MarkdownDirectory
    let changed: (String) -> Void

    init(directory: MarkdownDirectory, changed: @escaping (String) -> Void) {
        self.directory = directory; self.changed = changed
    }

    func watch(_ path: String) {
        guard sources[path] == nil, let url = try? directory.url(for: path) else { return }
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending[path]?.cancel()
            let task = DispatchWorkItem { [weak self] in self?.pending.removeValue(forKey: path); self?.changed(path) }
            self.pending[path] = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
        }
        source.setCancelHandler { Darwin.close(fd) }
        sources[path] = source; source.resume()
    }

    func stop(_ path: String) {
        for key in Array(sources.keys) where key == path || key.hasPrefix(path + "/") {
            sources.removeValue(forKey: key)?.cancel(); pending.removeValue(forKey: key)?.cancel()
        }
    }

    func stopAll() {
        sources.values.forEach { $0.cancel() }; sources.removeAll()
        pending.values.forEach { $0.cancel() }; pending.removeAll()
    }
}
