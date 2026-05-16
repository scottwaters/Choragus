/// BugReportBundleScrubTests.swift — Pin the bundle-export contract:
/// every payload string that leaves the process via `BugReportBundle`
/// must have run through `DiagnosticsRedactor.scrubForPublicOutput`
/// first, even though the body is encrypted to the maintainer's pubkey.
///
/// This test exists because the bundle path silently shipped raw `sn=`
/// account bindings to GitHub for one release (the diagnostic side of
/// issue #19) — the redactor was correct, but the assembly path didn't
/// apply it. The pre-fix DiagnosticsView built `EntryPayload` from raw
/// `e.message` and `e.contextJSON`, so anything below the
/// scrubForPublicOutput barrier reached the encrypted body in
/// cleartext. After the fix, callers compose
/// `BugReportBundle.scrubForPublicOutput` then `assemble`, and this
/// test pins the helper's behaviour.
import XCTest
import CryptoKit
@testable import SonosKit

final class BugReportBundleScrubTests: XCTestCase {

    private func makeRawEntry(message: String, context: String?) -> BugReportBundle.EntryPayload {
        BugReportBundle.EntryPayload(
            timestamp: "2026-05-02T13:10:53Z",
            level: "ERROR",
            tag: "PLAYBACK",
            message: message,
            context: context
        )
    }

    /// The exact signature of issue #19's bundle leak: a context blob
    /// carrying `sn=274` and a LAN URL. After the helper, neither must
    /// survive — but `sid=` is preserved because it's diagnostic gold.
    func testScrubRemovesSnAndLANIPFromContext() {
        let raw = makeRawEntry(
            message: "Direct play failed for Jingo",
            context: "{\"uri\":\"x-sonos-http:spotify%3atrack%3aXYZ?sid=9&flags=8224&sn=274\",\"url\":\"http://192.168.1.12:1400/MediaRenderer/AVTransport/Control\"}"
        )
        let scrubbed = BugReportBundle.scrubForPublicOutput([raw])

        XCTAssertEqual(scrubbed.count, 1)
        let ctx = scrubbed[0].context ?? ""
        XCTAssertFalse(ctx.contains("sn=274"),
                       "Pre-fix bundle leaked sn= account bindings — regression guard.")
        XCTAssertTrue(ctx.contains("sn=*"))
        XCTAssertTrue(ctx.contains("sid=9"),
                      "sid= is the maintainer's primary diagnostic signal — must survive scrub.")
        XCTAssertFalse(ctx.contains("192.168.1.12"))
        XCTAssertTrue(ctx.contains("<lan-ip>"))
    }

    func testScrubAppliesToMessageNotJustContext() {
        let raw = makeRawEntry(
            message: "Failed to write \(NSHomeDirectory())/Library/Caches/foo",
            context: nil
        )
        let scrubbed = BugReportBundle.scrubForPublicOutput([raw])
        XCTAssertFalse(scrubbed[0].message.contains(NSHomeDirectory()),
                       "Message strings must also pass through scrubForPublicOutput — not just context.")
        XCTAssertTrue(scrubbed[0].message.contains("~/"))
    }

    func testScrubLeavesNonPIIFieldsUntouched() {
        let raw = makeRawEntry(
            message: "Direct play failed for Jingo",
            context: "{\"service\":\"Spotify\",\"title\":\"Jingo\",\"artist\":\"Candido\",\"sid\":\"9\"}"
        )
        let scrubbed = BugReportBundle.scrubForPublicOutput([raw])
        XCTAssertEqual(scrubbed[0].message, "Direct play failed for Jingo",
                       "Plain prose with no PII signatures passes through unchanged.")
        XCTAssertEqual(scrubbed[0].context,
                       "{\"service\":\"Spotify\",\"title\":\"Jingo\",\"artist\":\"Candido\",\"sid\":\"9\"}",
                       "Service name, title, artist, sid all stay — they're either public or load-bearing for diagnosis.")
    }

    func testScrubHandlesNilContext() {
        let raw = makeRawEntry(message: "Plain message", context: nil)
        let scrubbed = BugReportBundle.scrubForPublicOutput([raw])
        XCTAssertNil(scrubbed[0].context)
        XCTAssertEqual(scrubbed[0].message, "Plain message")
    }

    func testScrubPreservesEntryStructureAndOrder() {
        let raws = (0..<5).map { i in
            BugReportBundle.EntryPayload(
                timestamp: "T\(i)",
                level: "INFO",
                tag: "TAG\(i)",
                message: "msg \(i)",
                context: nil
            )
        }
        let scrubbed = BugReportBundle.scrubForPublicOutput(raws)
        XCTAssertEqual(scrubbed.count, 5)
        XCTAssertEqual(scrubbed.map(\.timestamp), raws.map(\.timestamp))
        XCTAssertEqual(scrubbed.map(\.level), raws.map(\.level))
        XCTAssertEqual(scrubbed.map(\.tag), raws.map(\.tag))
    }

    /// Round-trip test: build raw entries containing PII, scrub via the
    /// helper, encrypt with a test keypair, decrypt with the matching
    /// private key, and assert the decrypted JSON contains no leaked
    /// values. This is the literal end-to-end path a real bundle takes
    /// — minus the Info.plist read for the maintainer pubkey, which is
    /// stubbed via the direct-key `wrap(_:for:)` overload.
    func testEncryptedBundleRoundTripContainsNoLeakedSecrets() throws {
        let raws = [
            makeRawEntry(
                message: "Direct play failed",
                context: "{\"uri\":\"x-sonos-http:spotify%3atrack%3aXYZ?sid=9&sn=274\",\"url\":\"http://192.168.1.12:1400/X\"}"
            ),
            makeRawEntry(
                message: "Token refresh: Bearer eyJSecretBlobABCDEF",
                context: "{\"path\":\"\(NSHomeDirectory())/Library/Caches/foo\"}"
            ),
        ]
        let scrubbed = BugReportBundle.scrubForPublicOutput(raws)

        // Drive the encryptor with a freshly-minted keypair so the
        // test doesn't depend on the production Info.plist slot.
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let plaintextJSON = try JSONEncoder().encode(scrubbed)
        let envelope = try BugReportEncryptor.wrap(plaintextJSON, for: priv.publicKey)

        // Round-trip through the static decryptor.
        let decrypted = try BugReportEncryptor.unwrap(envelope, with: priv)
        let roundTripped = try JSONDecoder().decode([BugReportBundle.EntryPayload].self, from: decrypted)
        XCTAssertEqual(roundTripped.count, scrubbed.count)

        // The decrypted body — what the maintainer actually reads —
        // must not contain any of the user's private values.
        let combined = roundTripped
            .map { ($0.message) + " " + ($0.context ?? "") }
            .joined(separator: " ")

        XCTAssertFalse(combined.contains("sn=274"),
                       "Encrypted bundle must not carry the user's SMAPI account binding through to the decrypted view.")
        XCTAssertFalse(combined.contains("192.168.1.12"),
                       "Encrypted bundle must not carry LAN IPs.")
        XCTAssertFalse(combined.contains(NSHomeDirectory()),
                       "Encrypted bundle must not carry the user's home directory.")
        XCTAssertFalse(combined.contains("eyJSecretBlobABCDEF"),
                       "Encrypted bundle must not carry Bearer tokens.")

        // sid= is the explicit not-PII exception — keep it for diagnosis.
        XCTAssertTrue(combined.contains("sid=9"),
                      "sid= must survive end-to-end so the maintainer can identify which SMAPI service the row references.")
    }

    // MARK: - v2 topology snapshot

    /// `topologySnapshot` walks `groups[*].members`, falls back to the
    /// `_MR` sibling when the bare ZonePlayer record has empty model
    /// fields, marks the coordinator, and labels the group by the
    /// coordinator's room name (matching Sonos's UI convention).
    func testTopologySnapshotShapeAndGrouping() {
        let arcBare = SonosDevice(
            id: "RINCON_ARC", ip: "192.168.1.10", roomName: "Living Room",
            modelName: "", modelNumber: "", softwareVersion: "",
            swGen: "2", isCoordinator: true, groupID: "G1"
        )
        let arcMR = SonosDevice(
            id: "RINCON_ARC_MR", ip: "192.168.1.10", roomName: "Living Room",
            modelName: "Arc", modelNumber: "S27", softwareVersion: "80.1-58220",
            swGen: "2"
        )
        let one = SonosDevice(
            id: "RINCON_ONE", ip: "192.168.1.11", roomName: "Bedroom",
            modelName: "Sonos One", modelNumber: "S18", softwareVersion: "80.1-58220",
            swGen: "2", isCoordinator: false, groupID: "G1"
        )
        let move = SonosDevice(
            id: "RINCON_MOVE", ip: "192.168.1.12", roomName: "Kitchen",
            modelName: "Move 2", modelNumber: "S40", softwareVersion: "80.1-58220",
            swGen: "2", isCoordinator: true, groupID: "G2"
        )

        let group1 = SonosGroup(id: "G1", coordinatorID: "RINCON_ARC", members: [arcBare, one])
        let group2 = SonosGroup(id: "G2", coordinatorID: "RINCON_MOVE", members: [move])

        let devicesDict: [String: SonosDevice] = [
            arcBare.id: arcBare, arcMR.id: arcMR, one.id: one, move.id: move
        ]
        let snapshot = BugReportBundle.topologySnapshot(
            groups: [group1, group2], devices: devicesDict
        )

        XCTAssertEqual(snapshot.count, 3)

        let arc = snapshot.first { $0.roomName == "Living Room" }
        XCTAssertEqual(arc?.modelName, "Arc",
                       "Bare ZonePlayer modelName is empty on some firmware — must resolve via the _MR sibling.")
        XCTAssertEqual(arc?.modelNumber, "S27")
        XCTAssertEqual(arc?.softwareVersion, "80.1-58220")
        XCTAssertEqual(arc?.systemVersion, "S2")
        XCTAssertTrue(arc?.isCoordinator == true)
        XCTAssertEqual(arc?.groupCoordinatorRoom, "Living Room")
        XCTAssertTrue(arc?.isAtmosCapable == true)

        let bedroom = snapshot.first { $0.roomName == "Bedroom" }
        XCTAssertEqual(bedroom?.groupCoordinatorRoom, "Living Room",
                       "Group label is the coordinator's room name — matches Sonos's UI convention.")
        XCTAssertTrue(bedroom?.isCoordinator == false)

        let kitchen = snapshot.first { $0.roomName == "Kitchen" }
        XCTAssertTrue(kitchen?.isPortable == true,
                      "Move 2 is portable — flag must be set so the maintainer notices Bluetooth-mode quirks.")
        XCTAssertEqual(kitchen?.groupCoordinatorRoom, "Kitchen")
    }

    /// HT 5.1 setup (Arc + Sub + 2× Era): when `htSatChannelMaps` is
    /// populated, every bonded satellite must appear in the snapshot
    /// with its correct surround role even though Sonos marks them
    /// `Invisible="1"` and excludes them from `groups[*].members`.
    func testTopologySnapshotIncludesBondedSatellitesViaChannelMap() {
        let arc = SonosDevice(
            id: "RINCON_ARC", ip: "192.168.1.10", roomName: "Living Room",
            modelName: "Arc", modelNumber: "S27", softwareVersion: "80.1-58220",
            swGen: "2", isCoordinator: true, groupID: "G1"
        )
        let sub = SonosDevice(
            id: "RINCON_SUB", ip: "192.168.1.11", roomName: "Living Room",
            modelName: "Sub", modelNumber: "S26", softwareVersion: "80.1-58220",
            swGen: "2", groupID: "G1"
        )
        let lr = SonosDevice(
            id: "RINCON_LR", ip: "192.168.1.12", roomName: "Living Room",
            modelName: "Sonos One SL", modelNumber: "S22", softwareVersion: "80.1-58220",
            swGen: "2", groupID: "G1"
        )
        let rr = SonosDevice(
            id: "RINCON_RR", ip: "192.168.1.13", roomName: "Living Room",
            modelName: "Sonos One SL", modelNumber: "S22", softwareVersion: "80.1-58220",
            swGen: "2", groupID: "G1"
        )
        // Only Arc is in the visible group members (sub/satellites are invisible).
        let group = SonosGroup(id: "G1", coordinatorID: "RINCON_ARC", members: [arc])
        let devicesDict: [String: SonosDevice] = [
            arc.id: arc, sub.id: sub, lr.id: lr, rr.id: rr
        ]
        let htMap: [String: [(String, SpeakerChannel)]] = [
            "RINCON_ARC": [
                ("RINCON_ARC", .soundbar),
                ("RINCON_SUB", .sub),
                ("RINCON_LR", .rearLeft),
                ("RINCON_RR", .rearRight)
            ]
        ]
        let snapshot = BugReportBundle.topologySnapshot(
            groups: [group], devices: devicesDict, htSatChannelMaps: htMap
        )

        XCTAssertEqual(snapshot.count, 4,
                       "All 4 speakers must appear — Arc + 3 invisible satellites.")
        XCTAssertEqual(snapshot.first(where: { $0.modelName == "Arc" })?.surroundRole,
                       "Soundbar")
        XCTAssertEqual(snapshot.first(where: { $0.modelName == "Sub" })?.surroundRole,
                       "Sub")
        let surrounds = snapshot.filter { $0.modelName == "Sonos One SL" }
        XCTAssertEqual(surrounds.count, 2)
        let roles = surrounds.compactMap(\.surroundRole).sorted()
        XCTAssertEqual(roles, ["Left Rear", "Right Rear"])
    }

    /// Cold-launch path: `htSatChannelMaps` / `stereoChannelMaps`
    /// aren't persisted, so they're empty until the first discovery
    /// completes. The snapshot must still emit invisible bonded
    /// satellites by scanning `devices` for matching `groupID`, tagged
    /// generically as `[Bonded]`. Without this fallback B1208 dropped
    /// the entire TV surround set whenever a bundle was captured
    /// shortly after launch.
    func testTopologySnapshotBondedFallbackWhenChannelMapEmpty() {
        let arc = SonosDevice(
            id: "RINCON_ARC", ip: "192.168.1.10", roomName: "Living Room",
            modelName: "Arc", modelNumber: "S27", softwareVersion: "80.1-58220",
            swGen: "2", isCoordinator: true, groupID: "G1"
        )
        let sub = SonosDevice(
            id: "RINCON_SUB", ip: "192.168.1.11", roomName: "Living Room",
            modelName: "Sub", modelNumber: "S26", softwareVersion: "80.1-58220",
            swGen: "2", groupID: "G1"
        )
        let group = SonosGroup(id: "G1", coordinatorID: "RINCON_ARC", members: [arc])
        let devicesDict: [String: SonosDevice] = [arc.id: arc, sub.id: sub]
        let snapshot = BugReportBundle.topologySnapshot(
            groups: [group], devices: devicesDict
            // No channel maps — simulates cold launch state.
        )

        XCTAssertEqual(snapshot.count, 2,
                       "Bonded Sub must still appear via the devices[groupID] fallback even when channel maps are empty.")
        let subRow = snapshot.first { $0.modelName == "Sub" }
        XCTAssertEqual(subRow?.surroundRole, "Bonded",
                       "Without channel-map data, the fallback uses generic 'Bonded' so the maintainer at least sees the speaker exists.")
    }

    /// Stereo-pair primary + invisible right half. The right speaker
    /// is in `devices` but not in `group.members`. The fold pulls it
    /// in via `stereoChannelMaps` and tags both sides with Left/Right.
    func testTopologySnapshotIncludesStereoPairRightHalf() {
        let left = SonosDevice(
            id: "RINCON_LEFT", ip: "192.168.1.20", roomName: "Bedroom",
            modelName: "Era 100", modelNumber: "S37", softwareVersion: "80.1-58220",
            swGen: "2", isCoordinator: true, groupID: "G3"
        )
        let right = SonosDevice(
            id: "RINCON_RIGHT", ip: "192.168.1.21", roomName: "Bedroom",
            modelName: "Era 100", modelNumber: "S37", softwareVersion: "80.1-58220",
            swGen: "2", groupID: "G3"
        )
        let group = SonosGroup(id: "G3", coordinatorID: "RINCON_LEFT", members: [left])
        let devicesDict: [String: SonosDevice] = [left.id: left, right.id: right]
        let stereoMap: [String: [(String, SpeakerChannel)]] = [
            "RINCON_LEFT": [
                ("RINCON_LEFT", .leftPair),
                ("RINCON_RIGHT", .rightPair)
            ]
        ]
        let snapshot = BugReportBundle.topologySnapshot(
            groups: [group], devices: devicesDict,
            stereoChannelMaps: stereoMap
        )

        XCTAssertEqual(snapshot.count, 2,
                       "Both halves of the stereo pair must be emitted.")
        let roles = snapshot.compactMap(\.surroundRole).sorted()
        XCTAssertEqual(roles, ["Left", "Right"])
    }

    /// `_MR` MediaRenderer sub-devices stored in `devices` for
    /// metadata-lookup purposes are NOT real speakers — the fallback
    /// must skip them so they don't appear as ghost rows in the
    /// snapshot.
    func testTopologySnapshotFallbackSkipsMRSiblings() {
        let arc = SonosDevice(
            id: "RINCON_ARC", ip: "192.168.1.10", roomName: "Living Room",
            modelName: "", modelNumber: "", softwareVersion: "",
            swGen: "2", isCoordinator: true, groupID: "G1"
        )
        let arcMR = SonosDevice(
            id: "RINCON_ARC_MR", ip: "192.168.1.10", roomName: "Living Room",
            modelName: "Arc", modelNumber: "S27", softwareVersion: "80.1-58220",
            swGen: "2", groupID: "G1"
        )
        let group = SonosGroup(id: "G1", coordinatorID: "RINCON_ARC", members: [arc])
        let devicesDict: [String: SonosDevice] = [arc.id: arc, arcMR.id: arcMR]
        let snapshot = BugReportBundle.topologySnapshot(
            groups: [group], devices: devicesDict
        )
        XCTAssertEqual(snapshot.count, 1,
                       "_MR sibling is a parsing artefact, not a physical speaker — fallback must skip it.")
        XCTAssertEqual(snapshot.first?.modelName, "Arc",
                       "The visible Arc record's empty modelName must still resolve via the _MR sibling.")
    }

    /// v2 body JSON round-trip — assembling a real envelope requires
    /// the maintainer pubkey from `Bundle.main.Info.plist` which the
    /// test target doesn't carry, so this asserts on the
    /// `BodyV2` codable contract directly (the same shape `assemble`
    /// serialises into ciphertext).
    func testV2BodyRoundTripCarriesEntriesAndDevices() throws {
        let entries = [
            makeRawEntry(message: "play tap on Kitchen", context: nil)
        ]
        let devices = [
            BugReportBundle.DevicePayload(
                roomName: "Kitchen", modelName: "Move 2", modelNumber: "S40",
                softwareVersion: "80.1-58220", systemVersion: "S2",
                isCoordinator: true, groupCoordinatorRoom: "Kitchen",
                isPortable: true, isAtmosCapable: false,
                surroundRole: nil
            )
        ]
        let bodyJSON = try JSONEncoder().encode(
            BugReportBundle.BodyV2(entries: entries, devices: devices)
        )
        let decoded = try JSONDecoder().decode(BugReportBundle.BodyV2.self, from: bodyJSON)
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.devices.count, 1)
        XCTAssertEqual(decoded.devices.first?.roomName, "Kitchen")
        XCTAssertEqual(decoded.devices.first?.isPortable, true)
        XCTAssertNil(decoded.devices.first?.surroundRole)
    }
}

