import XCTest
@testable import Murmur

/// Regression test for the "stuck at Downloading model (100%)" bug: a late
/// progress(1.0) callback delivered after the model finished loading must NOT
/// move the state back into `.loading` and clobber `.ready` (which blocked recording).
final class TranscriptionStateTests: XCTestCase {
    func test_lateProgress_doesNotClobberReady() {
        // This is the exact bug: engine calls progress(1.0) right before returning,
        // its deferred Task lands after we've already set .ready.
        XCTAssertEqual(TranscriptionState.ready.applyingLoadingProgress(1.0), .ready)
    }

    func test_progressUpdatesWhileLoading() {
        XCTAssertEqual(TranscriptionState.loading(progress: 0).applyingLoadingProgress(0.5),
                       .loading(progress: 0.5))
        XCTAssertEqual(TranscriptionState.loading(progress: 0.5).applyingLoadingProgress(1.0),
                       .loading(progress: 1.0))
    }

    func test_progressNeverResurrectsLoadingFromOtherStates() {
        XCTAssertEqual(TranscriptionState.recording.applyingLoadingProgress(0.3), .recording)
        XCTAssertEqual(TranscriptionState.error("x").applyingLoadingProgress(1.0), .error("x"))
        XCTAssertEqual(TranscriptionState.idle.applyingLoadingProgress(0.9), .idle)
    }
}
