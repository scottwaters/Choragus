import XCTest
@testable import SonosKit

final class PhysicalInputTests: XCTestCase {

    // MARK: - Model classification

    func testTVModelsClassifyAsTV() {
        for model in ["Sonos Arc", "Sonos Beam", "Sonos Playbar", "Sonos PLAYBASE", "Sonos Ray"] {
            XCTAssertEqual(PhysicalInput.kind(forModelName: model), .tv, model)
        }
    }

    func testAnalogModelsClassifyAsAnalog() {
        for model in ["Sonos Play:5", "Sonos Five", "Sonos Connect:Amp", "Sonos Amp", "Sonos Move", "Sonos Connect"] {
            XCTAssertEqual(PhysicalInput.kind(forModelName: model), .analog, model)
        }
    }

    func testModelsWithoutInputsReturnNil() {
        for model in ["Sonos One", "Sonos Era 100", "Sonos Play:1", "Sonos Roam", ""] {
            XCTAssertNil(PhysicalInput.kind(forModelName: model), model)
            XCTAssertFalse(PhysicalInput.isInputCapable(modelName: model), model)
        }
    }

    // MARK: - Discovery

    func testInputsMergeZonePlayerAndMediaRendererShadowByBaseID() {
        // Model name lives on the `_MR` shadow, room name on the ZonePlayer.
        let devices: [String: SonosDevice] = [
            "RINCON_AAA": SonosDevice(id: "RINCON_AAA", ip: "10.0.0.1", roomName: "Kitchen"),
            "RINCON_AAA_MR": SonosDevice(id: "RINCON_AAA_MR", ip: "10.0.0.1", roomName: "Kitchen", modelName: "Sonos Play:5"),
            "RINCON_BBB": SonosDevice(id: "RINCON_BBB", ip: "10.0.0.2", roomName: "Bedroom", modelName: "Sonos One"),
        ]
        let inputs = PhysicalInput.inputs(in: devices)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.deviceID, "RINCON_AAA")
        XCTAssertEqual(inputs.first?.roomName, "Kitchen")
        XCTAssertEqual(inputs.first?.modelName, "Sonos Play:5")
        XCTAssertEqual(inputs.first?.kind, .analog)
    }

    func testInputsSortByRoomName() {
        let devices: [String: SonosDevice] = [
            "RINCON_AAA": SonosDevice(id: "RINCON_AAA", ip: "10.0.0.1", roomName: "Lounge", modelName: "Sonos Arc"),
            "RINCON_BBB": SonosDevice(id: "RINCON_BBB", ip: "10.0.0.2", roomName: "kitchen", modelName: "Sonos Five"),
        ]
        XCTAssertEqual(PhysicalInput.inputs(in: devices).map(\.roomName), ["kitchen", "Lounge"])
    }

    // MARK: - Playback URI and DIDL

    func testAnalogInputURIAndTitle() {
        let input = PhysicalInput(deviceID: "RINCON_AAA", roomName: "Kitchen", modelName: "Sonos Play:5", kind: .analog)
        XCTAssertEqual(input.playURI, "x-rincon-stream:RINCON_AAA")
        XCTAssertEqual(input.title, "Line-In")
        XCTAssertEqual(input.browseItem.resourceURI, "x-rincon-stream:RINCON_AAA")
        XCTAssertEqual(input.browseItem.objectID, "linein:RINCON_AAA")
    }

    func testTVInputURIAndTitle() {
        let input = PhysicalInput(deviceID: "RINCON_BBB", roomName: "Lounge", modelName: "Sonos Arc", kind: .tv)
        XCTAssertEqual(input.playURI, "x-sonos-htastream:RINCON_BBB:spdif")
        XCTAssertEqual(input.title, "TV")
    }

    func testDIDLCarriesStreamURIAndEscapesRoomName() {
        let input = PhysicalInput(deviceID: "RINCON_AAA", roomName: "Tom & Jerry's", modelName: "Sonos Five", kind: .analog)
        let didl = input.didl
        XCTAssertTrue(didl.contains("<res protocolInfo=\"x-rincon-stream:*:*:*\">x-rincon-stream:RINCON_AAA</res>"))
        XCTAssertTrue(didl.contains("<upnp:class>object.item.audioItem.audioBroadcast</upnp:class>"))
        XCTAssertTrue(didl.contains("Tom &amp; Jerry"))
        XCTAssertFalse(didl.contains("Tom & Jerry"))
        XCTAssertEqual(input.browseItem.resourceMetadata, didl)
    }
}
