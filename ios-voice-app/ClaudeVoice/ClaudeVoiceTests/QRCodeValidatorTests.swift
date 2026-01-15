import XCTest
@testable import ClaudeVoice

final class QRCodeValidatorTests: XCTestCase {
    let validator = QRCodeValidator()

    func test_valid_ws_url() {
        let result = validator.validate("ws://192.168.1.42:8765")
        if case .success(let url) = result {
            XCTAssertEqual(url.absoluteString, "ws://192.168.1.42:8765")
        } else {
            XCTFail("Should succeed")
        }
    }

    func test_valid_wss_url() {
        let result = validator.validate("wss://secure.example.com:8765")
        if case .success(let url) = result {
            XCTAssertEqual(url.scheme, "wss")
        } else {
            XCTFail("Should succeed")
        }
    }

    func test_empty_code_rejected() {
        let result = validator.validate("")
        XCTAssertEqual(result, .failure(.emptyCode))
    }

    func test_http_url_rejected() {
        let result = validator.validate("http://192.168.1.42:8765")
        XCTAssertEqual(result, .failure(.invalidScheme("http")))
    }

    func test_random_text_rejected() {
        let result = validator.validate("not a url")
        if case .failure(.invalidScheme) = result {
            // Expected
        } else {
            XCTFail("Should reject random text")
        }
    }

    func test_various_valid_ips() {
        let urls = ["ws://10.0.0.1:8765", "ws://172.16.0.1:9000", "ws://localhost:8765"]
        for urlString in urls {
            if case .failure = validator.validate(urlString) {
                XCTFail("\(urlString) should be valid")
            }
        }
    }
}
