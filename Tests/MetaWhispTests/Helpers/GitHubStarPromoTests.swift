import XCTest
@testable import MetaWhisp

/// ITER-056 — pins the founder's 3-stage GitHub star promo lifecycle:
/// «первый раз показывается без крестика; после клика Star показывается ещё
/// раз, но уже с крестиком; крестик — скрыт навсегда».
final class GitHubStarPromoTests: XCTestCase {

    func test_stage0_visibleWithoutClose() {
        XCTAssertTrue(GitHubStarPromo.isVisible(stage: 0))
        XCTAssertFalse(GitHubStarPromo.showsClose(stage: 0))
    }

    func test_starClick_advancesToStage1_visibleWithClose() {
        let s = GitHubStarPromo.afterStarClick(stage: 0)
        XCTAssertEqual(s, 1)
        XCTAssertTrue(GitHubStarPromo.isVisible(stage: s))
        XCTAssertTrue(GitHubStarPromo.showsClose(stage: s))
    }

    func test_closeClick_hidesForever() {
        let s = GitHubStarPromo.afterCloseClick(stage: 1)
        XCTAssertEqual(s, 2)
        XCTAssertFalse(GitHubStarPromo.isVisible(stage: s))
    }

    /// Repeated Star clicks never resurrect a dismissed block, and a second
    /// star click doesn't reset the stage.
    func test_transitions_neverRegress() {
        XCTAssertEqual(GitHubStarPromo.afterStarClick(stage: 1), 1)
        XCTAssertEqual(GitHubStarPromo.afterStarClick(stage: 2), 2)
        XCTAssertFalse(GitHubStarPromo.isVisible(stage: GitHubStarPromo.afterStarClick(stage: 2)))
    }
}
