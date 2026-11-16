import XCTest
@testable import SpeedCamCore

final class SearchRequestStateTests: XCTestCase {
    func testOutOfOrderResultsAndCleanupCannotReplaceCurrentSearch() throws {
        var state = SearchRequestState()
        state.present(query: "A")
        let old = try XCTUnwrap(state.begin(query: "A"))
        let current = try XCTUnwrap(state.begin(query: "B"))
        XCTAssertFalse(state.accepts(old, currentQuery: "B"))
        XCTAssertFalse(state.finish(old))
        XCTAssertTrue(state.accepts(current, currentQuery: "B"))
        XCTAssertTrue(state.finish(current))
        XCTAssertFalse(state.accepts(current, currentQuery: "B"))
    }

    func testQueryEditInvalidatesSelectionBeforeAnotherSearchStarts() throws {
        var state = SearchRequestState()
        state.present(query: "台北")
        let selection = try XCTUnwrap(state.begin(query: "台北"))
        XCTAssertFalse(state.accepts(selection, currentQuery: "台北車站"),
                       "即使畫面的 onChange 尚未執行，也不能採用舊結果")
        XCTAssertTrue(state.updateQuery("台北車站"))
        XCTAssertFalse(state.accepts(selection, currentQuery: "台北車站"))
        XCTAssertFalse(state.finish(selection))
    }

    func testDismissAndReopenWithIdenticalQueryRejectsOldPresentation() throws {
        var state = SearchRequestState()
        XCTAssertNil(state.begin(query: "A"))
        state.present(query: "A")
        let old = try XCTUnwrap(state.begin(query: "A"))
        state.dismiss()
        XCTAssertFalse(state.accepts(old, currentQuery: "A"))
        XCTAssertNil(state.begin(query: "A"))
        state.present(query: "A")
        let current = try XCTUnwrap(state.begin(query: "A"))
        XCTAssertFalse(state.finish(old))
        XCTAssertTrue(state.accepts(current, currentQuery: "A"))
    }

    func testSameQueryNotificationKeepsNewRequestButExplicitCancellationDoesNot() throws {
        var state = SearchRequestState()
        state.present(query: "")
        let old = try XCTUnwrap(state.begin(query: "加油站"))
        let current = try XCTUnwrap(state.begin(query: "加油站"))
        XCTAssertFalse(state.updateQuery("加油站"))
        XCTAssertFalse(state.accepts(old, currentQuery: "加油站"))
        XCTAssertTrue(state.accepts(current, currentQuery: "加油站"))
        state.invalidate()
        XCTAssertFalse(state.accepts(current, currentQuery: "加油站"))
    }
}
