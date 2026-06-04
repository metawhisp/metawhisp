import XCTest
@testable import MetaWhisp

/// Pure mapping for the cloud transcription provider enum (endpoint / model /
/// display). This is the path a free BYOK user hits when transcriptionEngine=cloud.
final class CloudTranscriptionProviderTests: XCTestCase {

    func testRawValueRoundTrip() {
        XCTAssertEqual(CloudTranscriptionProvider(rawValue: "groq"), .groq)
        XCTAssertEqual(CloudTranscriptionProvider(rawValue: "openai"), .openai)
        XCTAssertNil(CloudTranscriptionProvider(rawValue: "deepgram"))
    }

    func testAllCases() {
        XCTAssertEqual(CloudTranscriptionProvider.allCases, [.groq, .openai])
    }

    func testGroqMapping() {
        XCTAssertEqual(CloudTranscriptionProvider.groq.displayName, "Groq")
        XCTAssertEqual(CloudTranscriptionProvider.groq.model, "whisper-large-v3-turbo")
        XCTAssertEqual(CloudTranscriptionProvider.groq.endpoint.absoluteString,
                       "https://api.groq.com/openai/v1/audio/transcriptions")
    }

    func testOpenAIMapping() {
        XCTAssertEqual(CloudTranscriptionProvider.openai.displayName, "OpenAI")
        XCTAssertEqual(CloudTranscriptionProvider.openai.model, "whisper-1")
        XCTAssertEqual(CloudTranscriptionProvider.openai.endpoint.absoluteString,
                       "https://api.openai.com/v1/audio/transcriptions")
    }

    func testEndpointsAreHTTPS() {
        for p in CloudTranscriptionProvider.allCases {
            XCTAssertEqual(p.endpoint.scheme, "https", "\(p) endpoint must be https")
        }
    }
}
