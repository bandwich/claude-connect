import Testing
import Foundation
@testable import ClaudeConnect

@Suite("Tailscale IP Detection Tests")
struct TailscaleIPTests {

    // MARK: - Valid Tailscale CGNAT IPs (100.64.0.0/10 = 100.64.0.0 – 100.127.255.255)

    @Test func tailscaleLowerBound() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("100.64.0.0") == true)
    }

    @Test func tailscaleUpperBound() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("100.127.255.255") == true)
    }

    @Test func tailscaleMidRange() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("100.100.1.1") == true)
    }

    // MARK: - Non-Tailscale IPs

    @Test func localNetworkIP() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("192.168.1.42") == false)
    }

    @Test func justBelowRange() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("100.63.255.255") == false)
    }

    @Test func justAboveRange() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("100.128.0.0") == false)
    }

    @Test func nonIPString() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("not-an-ip") == false)
    }

    @Test func emptyString() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("") == false)
    }

    @Test func localhostIP() {
        let manager = WebSocketManager()
        #expect(manager.isTailscaleIP("127.0.0.1") == false)
    }
}
