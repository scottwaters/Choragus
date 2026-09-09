import XCTest
@testable import SonosKit

final class SongListAIEndpointTests: XCTestCase {

    func testBareHostGainsV1() {
        XCTAssertEqual(SongListAIConfig.chatCompletionsURL(baseURL: "http://127.0.0.1:1234")?.absoluteString,
                       "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertEqual(SongListAIConfig.chatCompletionsURL(baseURL: "http://localhost:11434/")?.absoluteString,
                       "http://localhost:11434/v1/chat/completions")
    }

    func testExplicitPathIsKept() {
        XCTAssertEqual(SongListAIConfig.chatCompletionsURL(baseURL: "https://api.deepseek.com/v1")?.absoluteString,
                       "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(SongListAIConfig.chatCompletionsURL(baseURL: "https://host/proxy/openai/")?.absoluteString,
                       "https://host/proxy/openai/chat/completions")
    }

    /// A pasted endpoint URL is reduced to its base before the path is
    /// appended, so the endpoint is never doubled.
    func testPastedEndpointIsNotDoubled() {
        XCTAssertEqual(SongListAIConfig.chatCompletionsURL(baseURL: "https://api.deepseek.com/v1/chat/completions")?.absoluteString,
                       "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(SongListAIConfig.chatCompletionsURL(baseURL: "http://127.0.0.1:1234/v1/chat/completions/")?.absoluteString,
                       "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertEqual(SongListAIConfig.chatCompletionsURL(baseURL: "http://127.0.0.1:1234/chat/completions")?.absoluteString,
                       "http://127.0.0.1:1234/v1/chat/completions")
    }

    func testStreamErrorDescriptionCarriesNoStatusCode() {
        XCTAssertEqual(SongListAIError.streamError("overloaded").errorDescription,
                       "\(L10n.aiStreamError): overloaded")
        XCTAssertEqual(SongListAIError.streamError("").errorDescription, L10n.aiStreamError)
    }

    func testRejectsNonHTTP() {
        XCTAssertNil(SongListAIConfig.chatCompletionsURL(baseURL: ""))
        XCTAssertNil(SongListAIConfig.chatCompletionsURL(baseURL: "file:///tmp"))
        XCTAssertNil(SongListAIConfig.chatCompletionsURL(baseURL: "not a url"))
    }

    func testErrorDetailForms() {
        XCTAssertEqual(SongListAIService.errorDetail(from: #"{"error":{"message":"bad key"}}"#), "bad key")
        XCTAssertEqual(SongListAIService.errorDetail(from: #"{"error":"Unexpected endpoint or method. (POST /chat/completions)"}"#),
                       "Unexpected endpoint or method. (POST /chat/completions)")
        XCTAssertEqual(SongListAIService.errorDetail(from: "  plain text  "), "plain text")
        XCTAssertEqual(SongListAIService.errorDetail(from: ""), L10n.aiEmptyResponse)
    }
}
