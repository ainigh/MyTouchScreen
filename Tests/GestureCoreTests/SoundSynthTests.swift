import XCTest
@testable import GestureCore

final class SoundSynthTests: XCTestCase {
    func testWAVHeaderAndLength() {
        for cue in SoundCue.allCases {
            let data = cue.wavData()
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
            let expectedSamples = Int(cue.recipe.duration * Double(SoundCue.sampleRate))
            XCTAssertEqual(data.count, 44 + expectedSamples * 2, "\(cue)")
        }
    }

    func testSoundsAreQuietAndEndSilently() {
        for cue in SoundCue.allCases {
            let samples = cue.samples()
            let peak = samples.map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.01, "\(cue) is silent")
            XCTAssertLessThanOrEqual(peak, 0.25, "\(cue) is too loud")
            XCTAssertEqual(samples.last ?? 1, 0, accuracy: 1e-3, "\(cue) must end at zero (no click)")
        }
    }
}
