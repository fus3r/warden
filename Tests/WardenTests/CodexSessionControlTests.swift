import XCTest
@testable import Warden

final class CodexSessionControlTests: XCTestCase {
    private let target = URL(fileURLWithPath: "/logs/main/rollout-thread.jsonl")

    func testOnlyExactWritablePathIdentifiesOwner() {
        let report = """
        p101
        f3
        ar
        n/logs/main/rollout-thread.jsonl
        p102
        f4
        aw
        n/logs/work/rollout-thread.jsonl
        p103
        f5
        au
        n/logs/main/rollout-thread.jsonl
        """
        XCTAssertEqual(CodexSessionControl.uniqueWriter(of: target, in: report), 103)
    }

    func testRejectsMultipleWritersAndMultiSessionProcess() {
        let writer = """
        p103
        f5
        aw
        n/logs/main/rollout-thread.jsonl
        """
        XCTAssertNil(CodexSessionControl.uniqueWriter(of: target, in: writer + """

        p104
        f6
        aw
        n/logs/main/rollout-thread.jsonl
        """))
        XCTAssertNil(CodexSessionControl.uniqueWriter(of: target, in: writer + """

        f7
        aw
        n/logs/main/rollout-another.jsonl
        """))
    }
}
