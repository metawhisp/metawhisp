import Foundation

/// Made-up secrets in the shapes the agent's tests need, put together at run time: a test file holding text in a real
/// provider's key shape is refused by GitHub's push protection, made-up or not.
enum FakeSecrets {
    /// A Stripe live secret key's shape.
    static let stripeLiveKey = ["sk", "live", "51H8abcdefghijklmnopqrstuv"].joined(separator: "_")
    /// A GitHub personal access token's shape.
    static let githubToken = ["ghp", "16C7e42F292c6912E7710c838347Ae178B4a"].joined(separator: "_")
}
