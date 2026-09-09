/// DiagnosticsRedactorTests.swift — Coverage for the
/// `DiagnosticsRedactor` PII-scrubbing pipeline. The persistence-tier
/// pass runs before any row hits the on-disk SQLite store; the
/// public-output pass runs at the boundary where rows leave the
/// machine (clipboard, GitHub URL, encrypted bundle).
///
/// These tests exist because the bundle-export path silently shipped
/// raw `sn=` account bindings to GitHub for one release — the redactor
/// itself was correct, but the assembly path didn't apply it. Pinning
/// the public-output behaviour here plus the assembly contract in
/// `BugReportBundleScrubTests` closes that gap.
import XCTest
@testable import SonosKit

final class DiagnosticsRedactorTests: XCTestCase {

    // MARK: - scrubForPublicOutput

    /// A household id binds every speaker to one Sonos account; it is
    /// masked to its last four characters like a device id.
    func testScrubsHouseholdID() {
        let out = DiagnosticsRedactor.scrubForPublicOutput("household=Sonos_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234 room=Kitchen")
        XCTAssertEqual(out, "household=Sonos_**************************1234 room=Kitchen")
    }

    /// The exact failure mode from issue #19's bundle: `sn=274` made it
    /// to GitHub in cleartext because the bundle path bypassed the
    /// redactor.
    func testScrubsServiceAccountSerialNumber() {
        let raw = "x-sonos-http:spotify%3atrack%3a1C9XAjzr0pd1yE76TD3FM3?sid=9&flags=8224&sn=274"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertTrue(out.contains("sn=*"),
                      "sn= must be redacted on output paths to avoid leaking the user's SMAPI account binding.")
        XCTAssertTrue(out.contains("sid=9"),
                      "sid= must be preserved — it identifies Spotify vs Apple Music vs Plex generically and is needed for diagnosis.")
        XCTAssertFalse(out.contains("sn=274"),
                       "Original sn= value must not appear anywhere in the scrubbed output.")
    }

    func testScrubsHomePathToTilde() {
        let raw = "Failed to read \(NSHomeDirectory())/Library/Application Support/Choragus/foo.json"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertTrue(out.contains("~/Library/Application Support/Choragus/foo.json"),
                      "Home directory must collapse to ~ so usernames don't leak via paths.")
        XCTAssertFalse(out.contains(NSHomeDirectory()),
                       "Original /Users/<name> must not appear anywhere.")
    }

    func testScrubsLANIPInThe192168Range() {
        let raw = "Got 200 from http://192.168.1.45:1400/MediaRenderer/Control"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertEqual(out, "Got 200 from http://<lan-ip>:1400/MediaRenderer/Control")
    }

    func testScrubsLANIPInThe10Range() {
        let raw = "Reached speaker 10.0.0.50"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertEqual(out, "Reached speaker <lan-ip>")
    }

    func testScrubsLANIPInThe172Range() {
        // 172.16.0.0 – 172.31.255.255 is RFC1918 private space.
        let raw = "ping 172.20.5.10 succeeded; 172.40.5.10 should not be touched"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertTrue(out.contains("ping <lan-ip> succeeded"))
        XCTAssertTrue(out.contains("172.40.5.10"),
                      "172.40.x.x is outside RFC1918 — public addresses stay readable so e.g. lrclib.net resolves remain visible.")
    }

    func testScrubsLinkLocalIP() {
        let raw = "169.254.1.1 (link-local)"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertEqual(out, "<lan-ip> (link-local)")
    }

    func testPreservesPublicIPsForReadability() {
        let raw = "TLS handshake to 8.8.8.8 succeeded"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertEqual(out, "TLS handshake to 8.8.8.8 succeeded")
    }

    func testScrubsRINCONDeviceIDKeepingLastFour() {
        let raw = "Speaker RINCON_AB12CD34EF560XX21 went offline"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertTrue(out.contains("RINCON_*"),
                      "Device ID must mostly mask but keep enough for cross-event correlation.")
        XCTAssertTrue(out.hasSuffix("0XX21 went offline") || out.contains("0XX21"),
                      "Last 4 chars preserved — multiple events about the same speaker still correlate visually.")
        XCTAssertFalse(out.contains("AB12CD34EF56"),
                       "Original full device-ID hex must not survive.")
    }

    func testScrubsBearerToken() {
        let raw = "Authorization: Bearer abc123XYZ.payload.tail"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertTrue(out.contains("Bearer <redacted>"))
        XCTAssertFalse(out.contains("abc123XYZ"))
    }

    func testScrubsTokenQueryParameter() {
        let raw = "GET /smapi?token=very-secret-thing&sid=9"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertTrue(out.contains("token=<redacted>"))
        XCTAssertFalse(out.contains("very-secret-thing"))
        XCTAssertTrue(out.contains("sid=9"),
                      "Non-credential query params (sid) stay intact.")
    }

    func testScrubsAccessTokenAndApiKeyVariants() {
        let raw = "access_token=AAAA refresh_token=BBBB api_key=CCCC password=DDDD"
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)
        XCTAssertFalse(out.contains("AAAA"))
        XCTAssertFalse(out.contains("BBBB"))
        XCTAssertFalse(out.contains("CCCC"))
        XCTAssertFalse(out.contains("DDDD"))
    }

    /// Exercises the whole pipeline on a realistic context-JSON string —
    /// the exact shape that issue #19's bundle leaked. After scrubbing,
    /// the maintainer can still tell "this was a Spotify track on
    /// service 9 against speaker ending …F2", but the user's account
    /// binding (sn), home directory, and LAN topology are gone.
    func testEndToEndScrubOnRealisticContextJSON() {
        let raw = """
        {"action":"SetAVTransportURI","fault_code":"714",\
        "service":"AVTransport","sn_param":"sn=274",\
        "url":"http://192.168.1.12:1400/MediaRenderer/AVTransport/Control",\
        "uri":"x-sonos-http:spotify%3atrack%3aXYZ?sid=9&flags=8224&sn=274",\
        "device":"RINCON_AB12CD34EF5601400",\
        "log_path":"\(NSHomeDirectory())/Library/Application Support/Choragus/sonos_debug.log"}
        """
        let out = DiagnosticsRedactor.scrubForPublicOutput(raw)

        // Sanity checks on what should disappear.
        XCTAssertFalse(out.contains("192.168.1.12"))
        XCTAssertFalse(out.contains("sn=274"))
        XCTAssertFalse(out.contains(NSHomeDirectory()))
        XCTAssertFalse(out.contains("AB12CD34EF56"),
                       "Full RINCON hex must not survive.")

        // Sanity checks on what must survive (otherwise diagnosis breaks).
        XCTAssertTrue(out.contains("\"fault_code\":\"714\""),
                      "Fault code is the diagnostic signal — must survive.")
        XCTAssertTrue(out.contains("sid=9"),
                      "sid= identifies the service and must survive scrub.")
        XCTAssertTrue(out.contains("RINCON_*"),
                      "RINCON tail kept for correlation across events.")
    }

    // MARK: - scrubForPersistence

    func testPersistenceScrubRemovesAuthTokensButKeepsLocalPII() {
        let raw = "GET /api?token=secret123 from 192.168.1.5 \(NSHomeDirectory())/file"
        let out = DiagnosticsRedactor.scrubForPersistence(raw)
        XCTAssertTrue(out.contains("token=<redacted>"))
        XCTAssertFalse(out.contains("secret123"))
        XCTAssertTrue(out.contains("192.168.1.5"),
                      "Persistence-tier scrub keeps LAN IPs — the user's own diagnostic history is supposed to be useful for self-debug.")
        XCTAssertTrue(out.contains(NSHomeDirectory()),
                      "Persistence-tier scrub keeps home paths.")
    }
}
