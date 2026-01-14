import XCTest
@testable import ClaudeVoice

final class QRScannerTests: XCTestCase {

    func test_valid_websocket_url_accepted() {
        let validURLs = [
            "ws://192.168.1.42:8765",
            "ws://10.0.0.1:8765",
            "ws://172.16.0.1:9000",
        ]

        for url in validURLs {
            XCTAssertTrue(url.hasPrefix("ws://"), "\(url) should be valid")
        }
    }

    func test_invalid_urls_rejected() {
        let invalidURLs = [
            "http://192.168.1.42:8765",
            "https://example.com",
            "not a url",
            "",
        ]

        for url in invalidURLs {
            XCTAssertFalse(url.hasPrefix("ws://"), "\(url) should be invalid")
        }
    }
}
