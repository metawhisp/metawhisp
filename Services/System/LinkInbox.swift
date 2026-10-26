import Foundation

/// The `metawhisp://` links macOS hands the app (Codex, 1.4.0 review). A link that opens the app is delivered while
/// it launches — before `applicationDidFinishLaunching` — and one delivered before a handler exists is lost, so the
/// handler is registered as the launch begins (`applicationWillFinishLaunching`) and hands every link here. What comes
/// before the app can act on links is held, in the order it came, until `open(_:)`; any link after that goes straight
/// on. A launch that held one was opened by a link: the move to Applications, which ends the launch, is put off.
@MainActor
final class LinkInbox {
    private var held: [URL] = []
    private var deliver: ((URL) -> Void)?

    /// A link came before the app could act on links: this launch was opened by one, or got one while it launched.
    private(set) var openedByLink = false

    func receive(_ url: URL) {
        if let deliver {
            deliver(url)
            return
        }
        held.append(url)
        openedByLink = true
    }

    /// The app can act on links now: those held are handed on in the order they came, every later one at once.
    func open(_ deliver: @escaping (URL) -> Void) {
        self.deliver = deliver
        let waiting = held
        held = []
        waiting.forEach(deliver)
    }
}
