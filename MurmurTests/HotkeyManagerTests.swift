import XCTest
import Carbon.HIToolbox
@testable import Murmur

/// The hotkey is delivered via a session-level CGEvent tap (reliable in background AND
/// when Murmur is frontmost). Creating the tap needs Input-Monitoring permission, which a
/// headless test runner doesn't have, so we can't assert the tap is live — but we can
/// assert start()/stop() don't crash and that stop() fully releases the tap.
final class HotkeyManagerTests: XCTestCase {
    @MainActor
    func test_startThenStop_releasesTap() {
        let hm = HotkeyManager(keyCode: UInt16(kVK_RightOption), modifiers: 0, mode: .hold)
        hm.start()
        hm.stop()
        XCTAssertFalse(hm.hasEventTapForTesting, "stop() must release the event tap")
    }

    @MainActor
    func test_doubleStopIsSafe() {
        let hm = HotkeyManager(keyCode: UInt16(kVK_RightOption), modifiers: 0, mode: .hold)
        hm.start()
        hm.stop()
        hm.stop() // must not crash
        XCTAssertFalse(hm.hasEventTapForTesting)
    }
}
