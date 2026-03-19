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
    public var roomName: String // resolved locally, not from SOAP

    public init(id: Int, startTime: String = "07:00:00", duration: String = "01:00:00",
                recurrence: String = "DAILY", enabled: Bool = true, roomUUID: String = "",
                programURI: String = "", programMetaData: String = "", volume: Int = 25,
                includeLinkedZones: Bool = false, roomName: String = "") {
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
        self.roomName = roomName
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
                let days = recurrence.dropFirst(3)
                let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                var result: [String] = []
                for (i, c) in days.enumerated() where c != "0" && i < dayNames.count {
                    result.append(dayNames[i])
                }
                return result.joined(separator: ", ")
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

    public func listAlarms(device: SonosDevice) async throws -> [SonosAlarm] {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "ListAlarms",
            arguments: []
        )

        guard let alarmsXML = result["CurrentAlarmList"] else { return [] }
        return AlarmXMLParser.parse(alarmsXML)
    }

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
                ("ProgramMetaData", alarm.programMetaData),
                ("PlayMode", "SHUFFLE"),
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
                ("ProgramMetaData", alarm.programMetaData),
                ("PlayMode", "SHUFFLE"),
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

private class AlarmXMLParser: NSObject, XMLParserDelegate {
    private var alarms: [SonosAlarm] = []

    static func parse(_ xml: String) -> [SonosAlarm] {
        let unescaped = XMLResponseParser.xmlUnescape(xml)
        guard let data = unescaped.data(using: .utf8) else { return [] }
        let handler = AlarmXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
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
                includeLinkedZones: attributes["IncludeLinkedZones"] == "1"
            )
            alarms.append(alarm)
        }
    }
}
