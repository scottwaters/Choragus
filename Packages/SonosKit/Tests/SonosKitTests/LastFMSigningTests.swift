import XCTest
import CryptoKit
@testable import SonosKit

/// Verifies the Last.fm request-signing algorithm. The hash is the only
/// part of the Last.fm client that's deterministic without a network round-
/// trip, and a broken signature is the #1 cause of `error 13: invalid
/// signature`. These tests pin the algorithm against hand-computed digests
/// so future refactors can't silently break auth.
@MainActor
final class LastFMSigningTests: XCTestCase {

    /// `sign` only reads from its arguments; the token store isn't consulted.
    /// Using a throwaway SecretsStore keeps the real user Keychain untouched
    /// in case anyone calls setters during a future refactor.
    @MainActor
    private func makeClient() -> LastFMClient {
        let secrets = SecretsStore(
            service: "com.sonoscontroller.app.tests.\(UUID().uuidString)",
            account: "secrets.test"
        )
        let store = LastFMTokenStore(secrets: secrets)
        return LastFMClient(tokenStore: store)
    }

    private func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // Hand-computed reference: concat sorted "key+value" pairs + sharedSecret,
    // then md5 hex. We assert the client produces the same digest.

    func testSignatureIsStableUnderKeyOrder() {
        let client = makeClient()
        let a = client.sign(params: ["a": "1", "b": "2", "c": "3"], sharedSecret: "SECRET")
        let b = client.sign(params: ["c": "3", "a": "1", "b": "2"], sharedSecret: "SECRET")
        XCTAssertEqual(a, b)
    }

    func testSignatureExcludesFormatAndCallback() {
        let client = makeClient()
        let base = client.sign(params: ["method": "auth.getToken", "api_key": "XYZ"],
                               sharedSecret: "SECRET")
        let withFormat = client.sign(
            params: ["method": "auth.getToken", "api_key": "XYZ",
                     "format": "json", "callback": "cb"],
            sharedSecret: "SECRET"
        )
        XCTAssertEqual(base, withFormat, "format and callback must be excluded from signature")
    }

    func testSignatureMatchesManualHash() {
        let client = makeClient()
        // Sorted: api_key=XYZ, method=auth.getToken → "api_keyXYZmethodauth.getTokenSECRET"
        let expected = md5Hex("api_keyXYZmethodauth.getTokenSECRET")
        let actual = client.sign(
            params: ["method": "auth.getToken", "api_key": "XYZ"],
            sharedSecret: "SECRET"
        )
        XCTAssertEqual(actual, expected)
    }

    func testSignatureIncludesSessionKey() {
        // `sk` is signed (unlike format/callback), so changing it must change the digest.
        let client = makeClient()
        let s1 = client.sign(params: ["sk": "KEY1", "method": "track.scrobble"],
                             sharedSecret: "SECRET")
        let s2 = client.sign(params: ["sk": "KEY2", "method": "track.scrobble"],
                             sharedSecret: "SECRET")
        XCTAssertNotEqual(s1, s2)
    }

    func testSignatureIsLowercaseHex32Chars() {
        let client = makeClient()
        let sig = client.sign(params: ["method": "auth.getToken", "api_key": "XYZ"],
                              sharedSecret: "SECRET")
        XCTAssertEqual(sig.count, 32)
        XCTAssertEqual(sig, sig.lowercased())
        XCTAssertTrue(sig.allSatisfy { $0.isHexDigit })
    }

    func testFormEncodingPercentEncodesPlus() {
        // Regression: "Mike + the Mechanics" was returning error 13 because
        // `+` was left literal in the body and Last.fm decoded it as space.
        // The server's recomputed signature differed from ours and every
        // track in the batch failed.
        let client = makeClient()
        let body = client.formEncodeForTests([
            "track[0]": "Mike + the Mechanics"
        ])
        XCTAssertTrue(body.contains("%2B"),
                      "`+` must be percent-encoded to survive form-decoding")
        XCTAssertFalse(body.contains("Mechanics+the") || body.contains("+the+"),
                       "raw `+` in body would decode to a space on the server")
    }

    func testSignatureHandlesUnicode() {
        let client = makeClient()
        // Sorted: artist=Björk, title=Jóga → "artistBjörktitleJógaS"
        let expected = md5Hex("artistBjörktitleJógaS")
        let actual = client.sign(
            params: ["title": "Jóga", "artist": "Björk"],
            sharedSecret: "S"
        )
        XCTAssertEqual(actual, expected)
    }
}
