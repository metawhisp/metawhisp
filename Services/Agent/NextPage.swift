import Foundation

/// The one link on a page to the next page of its list, as a reference browser agent finds it
/// (`next_page_control`, `pages_forward` and `pager_link`; `agent.py` 3236-3252 and `page.py` 81-119,
/// MIT): a link to another address of the page's own site, labelled as a pager's next — "Next", "Next page",
/// "More results", "Older posts", arrows after them, or one or two arrows alone. None when there is none, or
/// links to two addresses: which one goes on is not known. A pager drawn above and below its list is one.
enum NextPage {
    private static let label = try! NSRegularExpression(
        pattern: "^(?:(?:next(?: page)?|more results|older(?: posts)?)\\s*[›»→>]*|[›»→>]{1,2})$",
        options: [.caseInsensitive])

    static func control(on page: ObservedPage) -> ObservedElement? {
        drawings(on: page).first
    }

    /// Each drawing of the page's one next link, in the page's order — a pager drawn above and below its list is two
    /// controls to one address — or none where `control` finds none.
    static func drawings(on page: ObservedPage) -> [ObservedElement] {
        guard let here = URL(string: page.url) else { return [] }
        var found: [String: [ObservedElement]] = [:]
        for element in page.elements where element.role == "link" && element.frame == nil {
            let words = element.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard label.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)) != nil,
                  let href = element.href, let target = URL(string: href, relativeTo: here)?.absoluteURL,
                  target.scheme == here.scheme, target.host == here.host, target.port == here.port,
                  (target.path, target.query) != (here.path, here.query) else { continue }
            found[target.absoluteString, default: []].append(element)
        }
        return found.count == 1 ? found.values.first ?? [] : []
    }

    /// What the reader is told of the page's next-page control (`next_page_notice`, `agent.py` 3201-3209): a list
    /// on the page may continue, and the next page's answer is not this page's.
    static func notice(_ label: String) -> String {
        "This page has a next-page control (\(ErrandModel.pythonString(label))): a list on it may continue. A "
            + "requirement about the page that control opens is not answered by this page, whatever this page holds: "
            + "leave it unanswered until that page is read."
    }
}
