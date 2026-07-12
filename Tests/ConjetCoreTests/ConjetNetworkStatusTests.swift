import ConjetCore
import XCTest

final class ConjetNetworkStatusTests: XCTestCase {
    func testNetworkStatusDecodesOldDaemonPayloadWithNewModeDefaults() throws {
        let json = """
        {
          "bindPolicy": "secure-local",
          "proxyEngine": "proxy-gcd-evented",
          "eventWatcherState": "running",
          "eventWatcherReconnects": 0,
          "periodicReconcileIntervalSeconds": 45,
          "capabilities": {
            "version": 4,
            "tcpProxy": true,
            "udpProxy": true,
            "binaryFrames": true,
            "udpBinaryFrames": true,
            "persistentVsock": true,
            "bridgeEngine": "conjet-netd-c"
          },
          "activeTCPForwards": 0,
          "activeUDPForwards": 0,
          "failedForwards": 0,
          "conflictCount": 0,
          "staleForwards": 0,
          "vmNetworkMode": "hvf-nat",
          "turboAvailable": false,
          "turboEnabled": false,
          "forwards": [],
          "messages": []
        }
        """

        let status = try ConjetJSON.decoder().decode(ConjetNetworkStatus.self, from: Data(json.utf8))

        XCTAssertEqual(status.bridgeEngine, "conjet-netd-c")
        XCTAssertEqual(status.tcpMode, "legacy-tcp-proxy")
        XCTAssertEqual(status.udpMode, "persistent-binary-udp")
        XCTAssertFalse(status.tcpBinaryFrames)
        XCTAssertFalse(status.persistentTCPVsock)
        XCTAssertFalse(status.tcpVsockPool)
        XCTAssertFalse(status.pythonFallbackActive)
        XCTAssertEqual(status.targetEventWatcherState, "stopped")
        XCTAssertEqual(status.targetEventReconnects, 0)
    }
}
