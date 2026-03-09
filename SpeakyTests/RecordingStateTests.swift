import Testing
@testable import Speaky

@Suite("RecordingState")
struct RecordingStateTests {

    @Test("equality for simple cases")
    func simpleEquality() {
        #expect(RecordingState.idle == RecordingState.idle)
        #expect(RecordingState.recording == RecordingState.recording)
        #expect(RecordingState.transcribing == RecordingState.transcribing)
        #expect(RecordingState.idle != RecordingState.recording)
    }

    @Test("error equality includes message")
    func errorEquality() {
        #expect(RecordingState.error("a") == RecordingState.error("a"))
        #expect(RecordingState.error("a") != RecordingState.error("b"))
    }

    @Test("error is not equal to other states")
    func errorNotEqualToOther() {
        #expect(RecordingState.error("msg") != RecordingState.idle)
        #expect(RecordingState.error("msg") != RecordingState.recording)
        #expect(RecordingState.error("msg") != RecordingState.transcribing)
    }
}
