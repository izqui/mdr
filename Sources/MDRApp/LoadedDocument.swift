import Foundation
import MDRCore

/// Load and validate completely before replacing the current review in a window.
struct LoadedDocument {
    var snapshot: SourceSnapshot
    var review: Review
    var diskHash: String?
    var notice: String?

    init(url: URL) throws {
        guard !url.lastPathComponent.lowercased().hasSuffix(".feedback.md") else {
            throw MDRError.invalidDocument("Open the original Markdown document. mdr will load its .feedback.md automatically.")
        }
        snapshot = try SourceSnapshot.read(url)
        review = Review(sourcePath: url.path, snapshot: snapshot)
        let sidecar = ReviewFile.url(for: url)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            let data = try Data(contentsOf: sidecar)
            review = try ReviewFile.decode(data)
            guard review.sourcePath == url.path || review.revision.sha256 == snapshot.revision.sha256 || !FileManager.default.fileExists(atPath: review.sourcePath) else {
                throw MDRError.invalidFeedback("This feedback file belongs to another source document: \(review.sourcePath). Rename one of the documents so each has its own feedback file.")
            }
            review.sourcePath = url.path; diskHash = sha256(data)
            if review.revision.sha256 != snapshot.revision.sha256 {
                let count = review.rebase(to: snapshot)
                diskHash = try ReviewFile.save(review, to: sidecar, expectedDiskHash: diskHash)
                notice = count == 0 ? "Source updated. Your feedback followed the text." : "Source updated. \(count) \(count == 1 ? "note needs" : "notes need") a new anchor."
            }
        }
    }
}
