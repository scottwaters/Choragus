import XCTest
@testable import SonosKit

final class SonosAlarmTests: XCTestCase {
    func testNamedRecurrencesExpandToDays() {
        XCTAssertEqual(SonosAlarm(id: 1, recurrence: "DAILY").activeDays, Set(0...6))
        XCTAssertEqual(SonosAlarm(id: 1, recurrence: "WEEKDAYS").activeDays, Set(1...5))
        XCTAssertEqual(SonosAlarm(id: 1, recurrence: "WEEKENDS").activeDays, [0, 6])
        XCTAssertEqual(SonosAlarm(id: 1, recurrence: "ONCE").activeDays, [])
        XCTAssertTrue(SonosAlarm(id: 1, recurrence: "ONCE").isOnce)
    }

    func testOnListIsDayNumbersNotABitmask() {
        // ON_135 means Monday, Wednesday, Friday on the speaker.
        let alarm = SonosAlarm(id: 1, recurrence: "ON_135")
        XCTAssertEqual(alarm.activeDays, [1, 3, 5])
        XCTAssertEqual(alarm.recurrenceDisplay, "Mon, Wed, Fri")
        XCTAssertEqual(SonosAlarm(id: 1, recurrence: "ON_06").activeDays, [0, 6])
        XCTAssertEqual(SonosAlarm(id: 1, recurrence: "ON_9x").activeDays, [])
    }

    func testDaysCollapseToTheSpeakerNames() {
        XCTAssertEqual(SonosAlarm.recurrence(days: Set(0...6)), "DAILY")
        XCTAssertEqual(SonosAlarm.recurrence(days: Set(1...5)), "WEEKDAYS")
        XCTAssertEqual(SonosAlarm.recurrence(days: [6, 0]), "WEEKENDS")
        XCTAssertEqual(SonosAlarm.recurrence(days: []), "ONCE")
        XCTAssertEqual(SonosAlarm.recurrence(days: [5, 1, 3]), "ON_135")
        XCTAssertEqual(SonosAlarm.recurrence(days: [2, 9]), "ON_2")
    }

    func testRoundTripThroughDays() {
        for recurrence in ["DAILY", "WEEKDAYS", "WEEKENDS", "ONCE", "ON_135", "ON_0"] {
            let alarm = SonosAlarm(id: 1, recurrence: recurrence)
            XCTAssertEqual(SonosAlarm.recurrence(days: alarm.activeDays), recurrence, recurrence)
        }
    }

    func testShuffleDurationAndChime() {
        var alarm = SonosAlarm(id: 1, duration: "", programURI: "")
        XCTAssertTrue(alarm.hasNoLimit)
        XCTAssertTrue(alarm.isChime)
        XCTAssertFalse(alarm.shuffle)
        alarm.shuffle = true
        XCTAssertEqual(alarm.playMode, "SHUFFLE")
        alarm.shuffle = false
        XCTAssertEqual(alarm.playMode, "REPEAT_ALL")
        alarm.duration = "01:30:00"
        XCTAssertEqual(alarm.durationMinutes, 90)
        alarm.programURI = "x-sonosapi-stream:s1?sid=254"
        alarm.programMetaData = #"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="a"><dc:title>Triple J</dc:title></item></DIDL-Lite>"#
        XCTAssertFalse(alarm.isChime)
        XCTAssertEqual(alarm.programTitle, "Triple J")
    }

    /// An alarm written from a favorite before the write path normalised
    /// `ProgramMetaData` sits on the speaker with the DIDL escaped one level
    /// too deep (`&amp;lt;DIDL-Lite` in the alarm-list XML). The title must
    /// still come out of it rather than the raw URI.
    func testProgramTitleReadsOverEscapedMetadata() {
        let xml = #"<Alarms><Alarm ID="171" StartTime="05:15:00" Duration="02:00:00" Recurrence="DAILY" Enabled="0" RoomUUID="RINCON_1" ProgramURI="x-rincon-cpcontainer:00040000album%3a1045520619?sid=204&amp;flags=4&amp;sn=17" ProgramMetaData="&amp;lt;DIDL-Lite xmlns:dc=&amp;quot;http://purl.org/dc/elements/1.1/&amp;quot; xmlns=&amp;quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&amp;quot;&amp;gt;&amp;lt;item id=&amp;quot;00040000album%3a1045520619&amp;quot;&amp;gt;&amp;lt;dc:title&amp;gt;Embrace the Storm&amp;lt;/dc:title&amp;gt;&amp;lt;/item&amp;gt;&amp;lt;/DIDL-Lite&amp;gt;" PlayMode="SHUFFLE" Volume="10" IncludeLinkedZones="0"/></Alarms>"#
        let list = AlarmXMLParser.parse(xml)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.programTitle, "Embrace the Storm")
    }

    func testParserReadsPlayModeAndEmptyDuration() {
        let xml = #"<Alarms><Alarm ID="9" StartTime="06:30:00" Duration="" Recurrence="ON_135" Enabled="1" RoomUUID="RINCON_1" ProgramURI="x-rincon-buzzer:0" ProgramMetaData="" PlayMode="SHUFFLE" Volume="12" IncludeLinkedZones="1"/></Alarms>"#
        let list = AlarmXMLParser.parse(xml)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.playMode, "SHUFFLE")
        XCTAssertEqual(list.first?.hasNoLimit, true)
        XCTAssertEqual(list.first?.activeDays, [1, 3, 5])
        XCTAssertEqual(list.first?.includeLinkedZones, true)
    }
}
