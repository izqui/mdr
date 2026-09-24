import Foundation

/// Resolve document links against the source file, never the bundled reader HTML.
public enum MarkdownLink: Equatable {
    case heading(String)
    case document(URL, fragment: String?)
    case external(URL)

    public static func resolve(_ href: String, from source: URL?) throws -> MarkdownLink {
        if href.hasPrefix("#") {
            guard let fragment = String(href.dropFirst()).removingPercentEncoding else {
                throw MDRError.invalidDocument("This heading link is not a valid URL.")
            }
            return .heading(fragment)
        }
        let address = href.hasPrefix("//") ? "https:" + href : href
        guard !address.isEmpty, let url = URL(string: address, relativeTo: source)?.absoluteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw MDRError.invalidDocument("This link could not be opened.")
        }
        if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            return .external(url)
        }
        guard url.isFileURL, ["", "localhost"].contains((parts.host ?? "").lowercased()),
              ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw MDRError.invalidDocument("mdr opens links to local .md and .markdown files, web pages, and email addresses.")
        }
        let fragment = parts.fragment
        parts.fragment = nil; parts.query = nil
        guard let file = parts.url else { throw MDRError.invalidDocument("This file link could not be opened.") }
        return .document(file.standardizedFileURL.resolvingSymlinksInPath(), fragment: fragment)
    }
}
