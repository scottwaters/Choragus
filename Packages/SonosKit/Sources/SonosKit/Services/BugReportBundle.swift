/// BugReportBundle.swift — Assembles a diagnostic bundle for the
/// Diagnostics window's encrypted-report flow.
///
/// Produces a JSON envelope whose header is plaintext (so the
/// maintainer can sort received bundles without decrypting first) and
/// whose body is opaque ciphertext from `BugReportEncryptor`. The
/// header carries non-PII context only — Choragus version, macOS
/// version, build tag, locale, event count, speaker count, timestamp.
///
/// Wire layout (UTF-8 JSON):
///
///   {
///     "format": "ChoragusBugBundle",
///     "formatVersion": 2,
///     "generatedAt": "2026-05-02T12:00:00Z",
///     "choragusVersion": "4.x",
///     "macOSVersion": "26.3.1",
///     "buildTag": "B2154",
///     "bundleId": "com.choragus.app",
///     "eventCount": 47,
///     "speakerCount": 5,
///     "locale": "en_AU",
///     "encryptedBody": "<base64 of BugReportEncryptor.wrap(body.json)>"
///   }
///
/// For format v2, `encryptedBody` decrypts to a UTF-8 JSON object:
///
///   {
///     "entries": [
///       { "timestamp": "...", "level": "ERROR", "tag": "SOAP",
///         "message": "...", "context": "..." },
///       ...
///     ],
///     "devices": [
///       { "roomName": "Kitchen", "modelName": "Sonos One",
///         "modelNumber": "S18", "softwareVersion": "80.1-58220",
///         "systemVersion": "S2", "isCoordinator": true,
///         "groupCoordinatorRoom": "Kitchen",
///         "isPortable": false, "isAtmosCapable": false },
///       ...
///     ]
///   }
///
/// Format v1 envelopes (no devices section) decode as the bare
/// `[EntryPayload]` array; the decoder branches on `formatVersion`.
///
/// Wire format version is bumped whenever either layer's schema
/// changes.
import Foundation

public enum BugReportBundle {
    public enum Error: Swift.Error, LocalizedError {
        case envelopeAssembly
        case bodyEncoding
        case envelopeMalformed
        case bodyMalformed

        public var errorDescription: String? {
            switch self {
            case .envelopeAssembly: return "Could not assemble the bug-report envelope."
            case .bodyEncoding:     return "Could not encode the bug-report body."
            case .envelopeMalformed: return "Bug-report envelope is malformed."
            case .bodyMalformed:    return "Bug-report body is malformed."
            }
        }
    }

    public static let formatTag = "ChoragusBugBundle"
    public static let formatVersion: Int = 2

    /// Plain-Swift representation of one diagnostic entry as it
    /// appears inside the encrypted body. Intentionally a flat dict
    /// so the maintainer-side decrypt CLI doesn't need to import
    /// SonosKit.
    public struct EntryPayload: Codable {
        public let timestamp: String
        public let level: String
        public let tag: String
        public let message: String
        public let context: String?

        public init(timestamp: String, level: String, tag: String,
                    message: String, context: String?) {
            self.timestamp = timestamp
            self.level = level
            self.tag = tag
            self.message = message
            self.context = context
        }
    }

    /// Per-speaker snapshot included alongside the event list. Mirrors
    /// what Sonos's official "About My System" page shows, minus the
    /// fields the export-tier redactor strips for every other payload
    /// (IP, RINCON UUID, household ID). Grouping is described by the
    /// `groupCoordinatorRoom` string — the reader buckets devices that
    /// share the same coordinator room into one group, matching the
    /// way Sonos's own UI labels groups by the coordinator's name.
    public struct DevicePayload: Codable {
        public let roomName: String
        public let modelName: String
        public let modelNumber: String
        public let softwareVersion: String
        public let systemVersion: String      // "S1" / "S2" / "Unknown"
        public let isCoordinator: Bool
        public let groupCoordinatorRoom: String
        public let isPortable: Bool
        public let isAtmosCapable: Bool
        /// Surround/sub channel role for bonded home-theater satellites
        /// (Sonos `HTSatChanMapSet`). Values mirror
        /// `SpeakerChannel.displayName`: "Soundbar", "Sub", "Left Rear",
        /// "Right Rear". `nil` for free-standing zones and regular
        /// (non-bonded) group members. Optional so legacy bundles that
        /// pre-date the field still decode.
        public let surroundRole: String?

        public init(roomName: String, modelName: String, modelNumber: String,
                    softwareVersion: String, systemVersion: String,
                    isCoordinator: Bool, groupCoordinatorRoom: String,
                    isPortable: Bool, isAtmosCapable: Bool,
                    surroundRole: String? = nil) {
            self.roomName = roomName
            self.modelName = modelName
            self.modelNumber = modelNumber
            self.softwareVersion = softwareVersion
            self.systemVersion = systemVersion
            self.isCoordinator = isCoordinator
            self.groupCoordinatorRoom = groupCoordinatorRoom
            self.isPortable = isPortable
            self.isAtmosCapable = isAtmosCapable
            self.surroundRole = surroundRole
        }
    }

    /// Plaintext envelope read by the maintainer-side decrypt CLI
    /// before any unwrap happens. Lets the maintainer sort received
    /// bundles by version / macOS / timestamp / topology size without
    /// holding the private key locally.
    public struct Header: Codable {
        public let format: String
        public let formatVersion: Int
        public let generatedAt: String
        public let choragusVersion: String?
        public let macOSVersion: String?
        public let buildTag: String?
        public let bundleId: String?
        public let eventCount: Int
        public let speakerCount: Int
        public let locale: String?
        public let encryptedBody: String   // base64
    }

    /// Body shape for format v2: events plus a topology snapshot. The
    /// reader picks this shape when `Header.formatVersion == 2`. v1
    /// bodies are a bare `[EntryPayload]` array — the decoder branches
    /// on version so older bundles still open.
    public struct BodyV2: Codable {
        public let entries: [EntryPayload]
        public let devices: [DevicePayload]

        public init(entries: [EntryPayload], devices: [DevicePayload]) {
            self.entries = entries
            self.devices = devices
        }
    }

    /// Builds the per-speaker snapshot included in v2 bodies. Iterates
    /// `groups` for user-visible zones, then folds in bonded
    /// home-theater satellites (Sub, surrounds) AND stereo-pair right
    /// halves — both of those classes of speaker exist in `devices`
    /// but are excluded from `groups[*].members` because Sonos marks
    /// them invisible. Without the fold, a 5.1 (Arc + Sub + 2× Era)
    /// looks like a single Arc, and a stereo-paired Bedroom looks
    /// like a single speaker.
    ///
    /// Both `htSatChannelMaps` and `stereoChannelMaps` are accepted —
    /// HT maps are keyed by the soundbar coordinator UUID; stereo
    /// maps are keyed by the visible primary's UUID (which may differ
    /// from the group coordinator if a stereo pair is soft-grouped
    /// into a larger group).
    ///
    /// Walks both the bare ZonePlayer record and the `_MR`
    /// MediaRenderer sibling when picking model / firmware fields
    /// because the bare record carries empty strings on some firmware
    /// (same lookup pattern as `SonosGroup.isAtmosCapable`).
    public static func topologySnapshot(
        groups: [SonosGroup],
        devices: [String: SonosDevice],
        htSatChannelMaps: [String: [(String, SpeakerChannel)]] = [:],
        stereoChannelMaps: [String: [(String, SpeakerChannel)]] = [:]
    ) -> [DevicePayload] {
        var out: [DevicePayload] = []
        for group in groups {
            let coordinatorRoom = group.coordinator?.roomName ?? group.name

            // Merge every bonded entry that lives under any of this
            // group's visible members (covers the case where a stereo
            // pair is soft-grouped under a different coordinator) plus
            // any HT map at the group coordinator.
            var bondedMap: [(String, SpeakerChannel)] = htSatChannelMaps[group.coordinatorID] ?? []
            for member in group.members {
                if let stereo = stereoChannelMaps[member.id] {
                    bondedMap.append(contentsOf: stereo)
                }
            }

            // Role lookup derived directly from the channel — works for
            // every variant (Soundbar / Sub / Left/Right Rear /
            // Left / Right). De-duplicates if a device appears in
            // both maps (shouldn't happen on real Sonos hardware but
            // keeps the snapshot deterministic if it ever does).
            var roleByID: [String: String] = [:]
            for (id, channel) in bondedMap {
                roleByID[id] = channel.displayName
            }

            // Visible group members (coordinator + soft-grouped zones +
            // stereo-pair primaries — primaries are visible).
            for member in group.members {
                out.append(buildDevicePayload(
                    member,
                    devices: devices,
                    coordinatorID: group.coordinatorID,
                    coordinatorRoom: coordinatorRoom,
                    surroundRole: roleByID[member.id]
                ))
            }

            // Invisible bonded satellites + stereo-pair right halves.
            // Pulled via the channel map because Sonos excludes them
            // from `group.members`. De-dupe against IDs we already
            // emitted.
            let emittedIDs = Set(group.members.map(\.id))
            var seen = emittedIDs
            for (satID, channel) in bondedMap where !seen.contains(satID) {
                seen.insert(satID)
                guard let satDevice = devices[satID] else { continue }
                out.append(buildDevicePayload(
                    satDevice,
                    devices: devices,
                    coordinatorID: group.coordinatorID,
                    coordinatorRoom: coordinatorRoom,
                    surroundRole: channel.displayName
                ))
            }

            // Fallback for invisible bonded members not covered by the
            // channel maps. The HT/stereo channel maps live in memory
            // only and aren't persisted to the topology cache, so on a
            // cold launch they're empty until the first discovery cycle
            // runs `parseHTChannelMaps` / `parseStereoChannelMaps`.
            // Without this fallback, a bundle captured in that window
            // misses every bonded sub/surround/right-pair speaker
            // (issue raised against B1208 — fresh launch dropped the
            // entire TV surround set from the snapshot). The fallback
            // walks `devices` for anything carrying this group's
            // `groupID` that we haven't already emitted; those are
            // exactly the invisible bonded members. `_MR` MediaRenderer
            // sub-records are skipped (parsing artefact, not a
            // physical speaker).
            for (id, dev) in devices
            where dev.groupID == group.id
                && !seen.contains(id)
                && !id.hasSuffix("_MR")
            {
                seen.insert(id)
                out.append(buildDevicePayload(
                    dev,
                    devices: devices,
                    coordinatorID: group.coordinatorID,
                    coordinatorRoom: coordinatorRoom,
                    surroundRole: "Bonded"
                ))
            }
        }
        return out
    }

    private static func buildDevicePayload(
        _ device: SonosDevice,
        devices: [String: SonosDevice],
        coordinatorID: String,
        coordinatorRoom: String,
        surroundRole: String?
    ) -> DevicePayload {
        let mr = devices["\(device.id)_MR"]
        let modelName = !device.modelName.isEmpty
            ? device.modelName
            : (mr?.modelName ?? "")
        let modelNumber = !device.modelNumber.isEmpty
            ? device.modelNumber
            : (mr?.modelNumber ?? "")
        let softwareVersion = !device.softwareVersion.isEmpty
            ? device.softwareVersion
            : (mr?.softwareVersion ?? "")
        let portable = device.isPortable || (mr?.isPortable ?? false)
        let atmos = device.isAtmosCapable || (mr?.isAtmosCapable ?? false)
        return DevicePayload(
            roomName: device.roomName,
            modelName: modelName,
            modelNumber: modelNumber,
            softwareVersion: softwareVersion,
            systemVersion: device.systemVersion.rawValue,
            isCoordinator: device.id == coordinatorID,
            groupCoordinatorRoom: coordinatorRoom,
            isPortable: portable,
            isAtmosCapable: atmos,
            surroundRole: surroundRole
        )
    }

    /// Returns a new entry list with `DiagnosticsRedactor.scrubForPublicOutput`
    /// applied to every `message` and `context` value.
    ///
    /// Bundle assembly intentionally stays neutral so internal tooling
    /// can ship raw payloads when needed; production callers
    /// (`DiagnosticsView.submitEncryptedReport`) compose `scrubForPublicOutput`
    /// then `assemble` so the final bundle never carries `sn=` account
    /// bindings, LAN topology, home paths, RINCON device IDs, or auth
    /// tokens — even though the body is encrypted to the maintainer's
    /// pubkey, minimisation defends against later key compromise. See
    /// the regression test in `BugReportBundleScrubTests`.
    public static func scrubForPublicOutput(_ entries: [EntryPayload]) -> [EntryPayload] {
        entries.map { e in
            EntryPayload(
                timestamp: e.timestamp,
                level: e.level,
                tag: e.tag,
                message: DiagnosticsRedactor.scrubForPublicOutput(e.message),
                context: e.context.map(DiagnosticsRedactor.scrubForPublicOutput)
            )
        }
    }

    /// Builds the envelope: serialises `entries` + `devices` as a v2
    /// body JSON object, runs the JSON through
    /// `BugReportEncryptor.wrap(...)`, base64-encodes the result, and
    /// wraps in the JSON header. Returns the file bytes the caller
    /// writes to disk.
    ///
    /// `devices` defaults to empty so callers that don't yet have a
    /// topology snapshot (or genuinely want to omit it) still produce
    /// a valid v2 envelope.
    public static func assemble(entries: [EntryPayload],
                                devices: [DevicePayload] = []) throws -> Data {
        // 1. Encode the v2 body object as compact JSON.
        let bodyEncoder = JSONEncoder()
        bodyEncoder.outputFormatting = [.sortedKeys]
        let bodyJSON: Data
        do {
            bodyJSON = try bodyEncoder.encode(BodyV2(entries: entries, devices: devices))
        } catch {
            throw Error.bodyEncoding
        }

        // 2. Wrap the body bytes for the maintainer's public key.
        let ciphertext = try BugReportEncryptor.wrap(bodyJSON)

        // 3. Build the plaintext header carrying non-PII context.
        let header = Header(
            format: formatTag,
            formatVersion: formatVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            choragusVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            buildTag: Bundle.main.infoDictionary?["ChoragusBuildTag"] as? String,
            bundleId: Bundle.main.bundleIdentifier,
            eventCount: entries.count,
            speakerCount: devices.count,
            locale: Locale.current.identifier,
            encryptedBody: ciphertext.base64EncodedString()
        )

        // 4. Serialise the envelope.
        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try envelopeEncoder.encode(header)
        } catch {
            throw Error.envelopeAssembly
        }
    }

    /// Reads the plaintext envelope without unwrapping the body. Used
    /// by the maintainer-side decrypt CLI to inspect provenance
    /// metadata before deciding whether to decrypt.
    public static func readHeader(_ envelopeBytes: Data) throws -> Header {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Header.self, from: envelopeBytes)
        } catch {
            throw Error.envelopeMalformed
        }
    }

    /// Full read + unwrap. Called by the maintainer-side CLI with the
    /// matching private key. Returns the entry list, the topology
    /// snapshot, and the header metadata.
    ///
    /// Branches on `Header.formatVersion`: v2 bodies decode as
    /// `BodyV2` (entries + devices); v1 bodies decode as a bare
    /// `[EntryPayload]` array with an empty `devices` list so legacy
    /// bundles still open.
    public static func decode(envelopeBytes: Data,
                              privateKey: Curve25519KeyAgreementPrivateKeyProtocol) throws
        -> (header: Header, entries: [EntryPayload], devices: [DevicePayload])
    {
        let header = try readHeader(envelopeBytes)
        guard header.format == formatTag else { throw Error.envelopeMalformed }
        guard let ciphertext = Data(base64Encoded: header.encryptedBody) else {
            throw Error.envelopeMalformed
        }
        let bodyJSON = try privateKey.unwrap(envelope: ciphertext)
        let decoder = JSONDecoder()
        do {
            switch header.formatVersion {
            case 1:
                let entries = try decoder.decode([EntryPayload].self, from: bodyJSON)
                return (header, entries, [])
            case 2:
                let body = try decoder.decode(BodyV2.self, from: bodyJSON)
                return (header, body.entries, body.devices)
            default:
                throw Error.envelopeMalformed
            }
        } catch let err as Error {
            throw err
        } catch {
            throw Error.bodyMalformed
        }
    }
}

/// Indirection so the maintainer-side CLI can use `Curve25519` from
/// CryptoKit without taking a SonosKit dependency. The CLI conforms a
/// `CryptoKit.Curve25519.KeyAgreement.PrivateKey` to this protocol via
/// a small extension.
public protocol Curve25519KeyAgreementPrivateKeyProtocol {
    func unwrap(envelope: Data) throws -> Data
}
