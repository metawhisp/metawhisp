import AppKit

/// The site's account page (PLAN-v6 §1): sign in — which also creates the account — then the plans, the payment,
/// and "Open in MetaWhisp", which signs the app in. Every "Get Pro" and "Already have Pro? Sign in" in the app
/// opens it through `open`, so a sign-in the app started is known in this one place.
enum AccountPage {
    static let url = URL(string: "https://metawhisp.com/account/")!

    /// Opens the page in the default browser. False when macOS could not open it — the caller then shows the link,
    /// with Copy. First the sign-in is marked as expected (A3): the link the site sends back within the hour signs in
    /// without a question — also when the user opens the shown link by hand.
    @MainActor
    static func open(defaults: UserDefaults = .standard,
                     with openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        SignInExpectation.mark(defaults: defaults)
        let opened = openURL(url)
        NSLog("[AccountPage] %@", opened ? "opened in the browser" : "the browser did not open — the link is shown")
        return opened
    }

    /// Copy: the address goes to `pasteboard` — on the user's click alone.
    static func copy(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }
}
