/// BugReportEncryptor.swift — Wraps a diagnostic bundle for the
/// maintainer.
///
/// Used by the Diagnostics window when the user opts to attach an
/// encrypted bundle to a bug report. The wrapping uses an ephemeral
/// X25519 key agreement plus ChaChaPoly AEAD, so the bundle is
/// readable only by the holder of the matching private key (the
/// maintainer). Anyone in between — GitHub's CDN, an email server,
/// a dropbox link — sees opaque bytes.
///
/// The maintainer's public key is read from the app's `Info.plist`
/// at the `BugReportPublicKey` slot. The slot is empty in dev / fork
/// builds; consumers should treat `maintainerPublicKey == nil` as a
/// signal to hide the encrypted-report UI rather than fall through
/// to a degraded path.
import CryptoKit
import Foundation

public enum BugReportEncryptor {
    public enum Error: Swift.Error, LocalizedError {
        case publicKeyMissing
        case publicKeyMalformed
        case wrapFailed

        public var errorDescription: String? {
            switch self {
            case .publicKeyMissing:
                return L10n.errBugReportKeyMissing
            case .publicKeyMalformed:
                return L10n.errBugReportKeyInvalid
            case .wrapFailed:
                return L10n.errBugReportWrapFailed
            }
        }
    }

    /// HKDF context label. Bumped whenever the wire format changes so
    /// older bundles keep decrypting under their original derivation.
    private static let contextLabel = "Choragus-Bug-Bundle-v1"

    /// Wire format version byte stamped into the output. Read at the
    /// maintainer side to pick the right unwrap routine when the
    /// format evolves.
    public static let wireFormatVersion: UInt8 = 1

    /// Returns the maintainer's public key from the app bundle, or
    /// `nil` when the plist slot is empty / unsubstituted (dev /
    /// fork builds). UI consumers use the `nil` case to hide
    /// encrypted-report controls entirely.
    public static var maintainerPublicKey: Curve25519.KeyAgreement.PublicKey? {
        guard let raw = Bundle.main.infoDictionary?["BugReportPublicKey"] as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        guard let data = Data(base64Encoded: trimmed) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    /// True when the app was built with a maintainer public key
    /// embedded — useful for hiding UI when the value is missing.
    public static var isConfigured: Bool {
        maintainerPublicKey != nil
    }

    /// Wraps `plaintext` for the configured maintainer public key.
    /// Throws if the key isn't present or isn't parseable.
    ///
    /// Output layout (binary, all-bytes):
    ///   [version: 1 byte][ephemeral_pubkey: 32 bytes][nonce: 12 bytes][ciphertext + tag: N bytes]
    ///
    /// The recipient performs key agreement with their private key and
    /// the embedded ephemeral public key, derives the symmetric key
    /// via HKDF-SHA256 with `contextLabel` as the info parameter, and
    /// opens the AEAD.
    public static func wrap(_ plaintext: Data) throws -> Data {
        guard let raw = Bundle.main.infoDictionary?["BugReportPublicKey"] as? String else {
            throw Error.publicKeyMissing
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else {
            throw Error.publicKeyMissing
        }
        guard let keyData = Data(base64Encoded: trimmed) else {
            throw Error.publicKeyMalformed
        }
        let recipient: Curve25519.KeyAgreement.PublicKey
        do {
            recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        } catch {
            throw Error.publicKeyMalformed
        }
        return try wrap(plaintext, for: recipient)
    }

    /// Direct-key variant for tests and the maintainer-side decrypt
    /// CLI (which doesn't use Info.plist).
    public static func wrap(_ plaintext: Data,
                            for recipient: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared: SharedSecret
        do {
            shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        } catch {
            throw Error.wrapFailed
        }
        let symmetric = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(contextLabel.utf8),
            outputByteCount: 32
        )
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.seal(plaintext, using: symmetric)
        } catch {
            throw Error.wrapFailed
        }
        var out = Data()
        out.append(wireFormatVersion)
        out.append(ephemeral.publicKey.rawRepresentation)         // 32
        out.append(contentsOf: sealed.nonce)                       // 12
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Unwraps a previously-`wrap`'d bundle using the recipient's
    /// private key. Used by the maintainer-side decrypt CLI; not
    /// shipped in the app's normal code paths but kept here so the
    /// wrap and unwrap routines stay byte-symmetric in one file.
    public static func unwrap(_ envelope: Data,
                              with privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard envelope.count > 1 + 32 + 12 + 16 else { throw Error.wrapFailed }
        let version = envelope[envelope.startIndex]
        guard version == wireFormatVersion else { throw Error.wrapFailed }

        let ephemeralStart = envelope.index(envelope.startIndex, offsetBy: 1)
        let ephemeralEnd = envelope.index(ephemeralStart, offsetBy: 32)
        let ephemeralData = envelope[ephemeralStart..<ephemeralEnd]
        let nonceStart = ephemeralEnd
        let nonceEnd = envelope.index(nonceStart, offsetBy: 12)
        let nonceData = envelope[nonceStart..<nonceEnd]
        let bodyStart = nonceEnd
        let tagStart = envelope.index(envelope.endIndex, offsetBy: -16)
        let ciphertext = envelope[bodyStart..<tagStart]
        let tag = envelope[tagStart..<envelope.endIndex]

        let ephemeral: Curve25519.KeyAgreement.PublicKey
        do {
            ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralData)
        } catch {
            throw Error.wrapFailed
        }
        let shared: SharedSecret
        do {
            shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        } catch {
            throw Error.wrapFailed
        }
        let symmetric = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(contextLabel.utf8),
            outputByteCount: 32
        )
        let nonce: ChaChaPoly.Nonce
        do {
            nonce = try ChaChaPoly.Nonce(data: nonceData)
        } catch {
            throw Error.wrapFailed
        }
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        } catch {
            throw Error.wrapFailed
        }
        do {
            return try ChaChaPoly.open(sealed, using: symmetric)
        } catch {
            throw Error.wrapFailed
        }
    }
}
