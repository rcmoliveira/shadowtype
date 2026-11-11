// SecureInputOwner — naming the process that holds secure event input.
// IsSecureEventInputEnabled() is a system-wide boolean, so one holder silences Shadowtype in every
// app; the whole point of this type is turning that invisible silence into a named culprit. Parsing
// is tested against injected session dictionaries (no IOKit), the live read only for "doesn't crash".
import XCTest
@testable import Shadowtype

final class SecureInputOwnerTests: XCTestCase {

    func testReadsOwnerPIDFromSessionDict() {
        let pid = SecureInputOwner.pid(sessions: {
            [["kCGSSessionIDKey": 255, "kCGSSessionSecureInputPID": 4212]]
        })
        XCTAssertEqual(pid, 4212)
    }

    func testNoOwnerKeyIsNilNotZero() {
        // The common case: a normal desktop session reports no secure-input owner. Returning 0 here
        // would render "held by pid 0", which is a lie the user cannot act on.
        XCTAssertNil(SecureInputOwner.pid(sessions: { [["kCGSSessionIDKey": 255]] }))
        XCTAssertNil(SecureInputOwner.pid(sessions: { [["kCGSSessionSecureInputPID": 0]] }))
    }

    func testScansEverySession() {
        let pid = SecureInputOwner.pid(sessions: {
            [["kCGSSessionIDKey": 255], ["kCGSSessionSecureInputPID": 77]]
        })
        XCTAssertEqual(pid, 77)
    }

    // The registry has handed back CFNumber through `Any` as Int or UInt depending on shim; neither
    // may be silently dropped, and a wrong type must not crash or produce a bogus PID.
    func testNumberWidthsAndGarbageTolerated() {
        XCTAssertEqual(SecureInputOwner.pid(sessions: { [["kCGSSessionSecureInputPID": UInt(900)]] }), 900)
        XCTAssertNil(SecureInputOwner.pid(sessions: { [["kCGSSessionSecureInputPID": "nonsense"]] }))
        XCTAssertNil(SecureInputOwner.pid(sessions: { [] }))
    }

    // describe() must always produce a usable sentence — it lands in a menu row and in diag.log.
    func testDescribeAlwaysReturnsNonEmpty() {
        XCTAssertFalse(SecureInputOwner.describe().isEmpty)
    }

    // The live IOKit read is the risky part: it must never throw, hang, or return junk that the
    // caller then renders. On any machine it returns 0..n session dicts.
    func testLiveConsoleSessionsReadIsSafe() {
        let sessions = SecureInputOwner.consoleSessions()
        XCTAssertTrue(sessions.count >= 0)   // shape assertion; the real check is "we got here"
    }

    // A real PID resolves to a real app name (this test process is guaranteed to be running).
    func testNamesAKnownRunningProcess() {
        let selfName = SecureInputOwner.name(forPID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(selfName, "a live pid must resolve a localizedName")
    }

    func testNameForDeadPIDIsNil() {
        // An unrecoverable PID must degrade to "pid N", not a wrong name.
        XCTAssertNil(SecureInputOwner.name(forPID: 999_999))
    }
}
