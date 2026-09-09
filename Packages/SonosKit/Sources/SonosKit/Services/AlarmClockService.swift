import Foundation

public struct SonosAlarm: Identifiable, Equatable {
    public let id: Int
    public var startTime: String // HH:MM:SS
    public var duration: String // HH:MM:SS
    public var recurrence: String // DAILY, WEEKDAYS, WEEKENDS, ONCE, ON_DDDDDD
    public var enabled: Bool
    public var roomUUID: String
    public var programURI: String
    public var programMetaData: String
    public var volume: Int
    public var includeLinkedZones: Bool
    /// SHUFFLE, REPEAT_ALL or NORMAL — what the Sonos app calls "Shuffle music".
    public var playMode: String
    public var roomName: String // resolved locally, not from SOAP

    public init(id: Int, startTime: String = "07:00:00", duration: String = "01:00:00",
                recurrence: String = "DAILY", enabled: Bool = true, roomUUID: String = "",
                programURI: String = "", programMetaData: String = "", volume: Int = 25,
                includeLinkedZones: Bool = false, playMode: String = "REPEAT_ALL", roomName: String = "") {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.recurrence = recurrence
        self.enabled = enabled
        self.roomUUID = roomUUID
        self.programURI = programURI
        self.programMetaData = programMetaData
        self.volume = volume
        self.includeLinkedZones = includeLinkedZones
        self.playMode = playMode
        self.roomName = roomName
    }

    /// The Sonos chime, or a URI-less alarm the speaker treats the same way.
    public static let chimeURI = "x-rincon-buzzer:0"
    public var isChime: Bool { programURI.isEmpty || programURI.hasPrefix("x-rincon-buzzer") }
    public var shuffle: Bool {
        get { playMode == "SHUFFLE" }
        set { playMode = newValue ? "SHUFFLE" : "REPEAT_ALL" }
    }
    /// An empty duration is "No limit" on the speaker.
    public var hasNoLimit: Bool { duration.isEmpty }
    public var durationMinutes: Int {
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
    public var isOnce: Bool { recurrence == "ONCE" }
    /// The title in the program's DIDL, else the URI's readable tail.
    /// The stored DIDL is normalised first: an alarm written with the
    /// favorite's still-escaped `r:resMD` sits on the speaker one escape
    /// level too deep and parses as text, not XML.
    public var programTitle: String {
        if isChime { return "" }
        if let parsed = XMLResponseParser.parseDIDLMetadata(DIDLNormalize.metadata(programMetaData)),
           !parsed.title.isEmpty { return parsed.title }
        return programURI
    }

    // MARK: Days

    /// Weekdays the alarm fires, Sunday = 0. Empty for a one-off.
    public var activeDays: Set<Int> {
        switch recurrence {
        case "DAILY": return Set(0...6)
        case "WEEKDAYS": return Set(1...5)
        case "WEEKENDS": return [0, 6]
        case "ONCE": return []
        default:
            // ON_135 lists the day numbers that are on.
            guard recurrence.hasPrefix("ON_") else { return [] }
            return Set(recurrence.dropFirst(3).compactMap { Int(String($0)) }.filter { (0...6).contains($0) })
        }
    }

    /// The recurrence string the speaker expects for a set of days.
    public static func recurrence(days: Set<Int>) -> String {
        let sorted = days.filter { (0...6).contains($0) }.sorted()
        switch Set(sorted) {
        case Set(0...6): return "DAILY"
        case Set(1...5): return "WEEKDAYS"
        case [0, 6]: return "WEEKENDS"
        case []: return "ONCE"
        default: return "ON_" + sorted.map(String.init).joined()
        }
    }

    public var displayTime: String {
        let parts = startTime.split(separator: ":")
        guard parts.count >= 2 else { return startTime }
        let hour = Int(parts[0]) ?? 0
        let minute = Int(parts[1]) ?? 0
        let ampm = hour >= 12 ? "PM" : "AM"
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return String(format: "%d:%02d %@", displayHour, minute, ampm)
    }

    public var recurrenceDisplay: String {
        switch recurrence {
        case "DAILY": return "Every Day"
        case "WEEKDAYS": return "Weekdays"
        case "WEEKENDS": return "Weekends"
        case "ONCE": return "Once"
        default:
            if recurrence.hasPrefix("ON_") {
                let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                return activeDays.sorted().map { dayNames[$0] }.joined(separator: ", ")
            }
            return recurrence
        }
    }
}

public final class AlarmClockService {
    private let soap: SOAPClient
    private static let path = "/AlarmClock/Control"
    private static let service = "AlarmClock"

    public init(soap: SOAPClient = SOAPClient()) {
        self.soap = soap
    }

    /// A household's alarm list and the id of the speaker that owns it.
    /// Every zone player answers ListAlarms, but only the master's copy
    /// is current right after an edit; the others catch up over the next
    /// seconds. `CurrentAlarmListVersion` is `<masterRINCON>:<revision>`.
    public struct AlarmList {
        public let alarms: [SonosAlarm]
        public let masterID: String?
    }

    public func listAlarmList(device: SonosDevice) async throws -> AlarmList {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "ListAlarms",
            arguments: []
        )
        let master = result["CurrentAlarmListVersion"]?.split(separator: ":").first.map(String.init)
        guard let alarmsXML = result["CurrentAlarmList"] else { return AlarmList(alarms: [], masterID: master) }
        return AlarmList(alarms: AlarmXMLParser.parse(alarmsXML), masterID: master)
    }

    public func listAlarms(device: SonosDevice) async throws -> [SonosAlarm] {
        try await listAlarmList(device: device).alarms
    }

    /// `ProgramMetaData` is sent as DIDL XML. A favorite's `resourceMetadata`
    /// arrives from Browse still entity-escaped (the speaker nests it inside
    /// `r:resMD`); the SOAP envelope escapes once more, so without the
    /// normalisation the AlarmClock service stores the DIDL as escaped text
    /// and every later read shows the raw URI instead of the title.
    public func createAlarm(device: SonosDevice, alarm: SonosAlarm) async throws -> Int {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "CreateAlarm",
            arguments: [
                ("StartLocalTime", alarm.startTime),
                ("Duration", alarm.duration),
                ("Recurrence", alarm.recurrence),
                ("Enabled", alarm.enabled ? "1" : "0"),
                ("RoomUUID", alarm.roomUUID),
                ("ProgramURI", alarm.programURI),
                ("ProgramMetaData", DIDLNormalize.metadata(alarm.programMetaData)),
                ("PlayMode", alarm.playMode),
                ("Volume", "\(alarm.volume)"),
                ("IncludeLinkedZones", alarm.includeLinkedZones ? "1" : "0")
            ]
        )
        return Int(result["AssignedID"] ?? "0") ?? 0
    }

    public func updateAlarm(device: SonosDevice, alarm: SonosAlarm) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "UpdateAlarm",
            arguments: [
                ("ID", "\(alarm.id)"),
                ("StartLocalTime", alarm.startTime),
                ("Duration", alarm.duration),
                ("Recurrence", alarm.recurrence),
                ("Enabled", alarm.enabled ? "1" : "0"),
                ("RoomUUID", alarm.roomUUID),
                ("ProgramURI", alarm.programURI),
                ("ProgramMetaData", DIDLNormalize.metadata(alarm.programMetaData)),
                ("PlayMode", alarm.playMode),
                ("Volume", "\(alarm.volume)"),
                ("IncludeLinkedZones", alarm.includeLinkedZones ? "1" : "0")
            ]
        )
    }

    public func destroyAlarm(device: SonosDevice, alarmID: Int) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "DestroyAlarm",
            arguments: [("ID", "\(alarmID)")]
        )
    }
}

// MARK: - Alarm XML Parser

class AlarmXMLParser: NSObject, XMLParserDelegate {
    private var alarms: [SonosAlarm] = []

    static func parse(_ xml: String) -> [SonosAlarm] {
        // The alarm list arrives from the SOAP layer already unescaped
        // exactly once — valid XML. A second unescape turned `&amp;` in
        // ProgramURI query strings (and escaped ProgramMetaData DIDL)
        // into bare `&`, aborting the parse and silently dropping alarms
        // (same defect class as issue #81).
        guard let data = xml.data(using: .utf8) else { return [] }
        let handler = AlarmXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        guard parser.parse() else {
            sonosDiagLog(.error, tag: "ALARMS",
                         "Alarm list parse aborted — discarding partial list",
                         context: ["parserError": String(describing: parser.parserError),
                                   "alarmsBeforeAbort": String(handler.alarms.count)])
            return []
        }
        return handler.alarms
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "Alarm" {
            let alarm = SonosAlarm(
                id: Int(attributes["ID"] ?? "0") ?? 0,
                startTime: attributes["StartTime"] ?? "07:00:00",
                duration: attributes["Duration"] ?? "01:00:00",
                recurrence: attributes["Recurrence"] ?? "DAILY",
                enabled: attributes["Enabled"] == "1",
                roomUUID: attributes["RoomUUID"] ?? "",
                programURI: attributes["ProgramURI"] ?? "",
                programMetaData: attributes["ProgramMetaData"] ?? "",
                volume: Int(attributes["Volume"] ?? "25") ?? 25,
                includeLinkedZones: attributes["IncludeLinkedZones"] == "1",
                playMode: attributes["PlayMode"] ?? "REPEAT_ALL"
            )
            alarms.append(alarm)
        }
    }
}
