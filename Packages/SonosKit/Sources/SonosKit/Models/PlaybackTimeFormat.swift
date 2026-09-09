/// PlaybackTimeFormat.swift — One way to write a duration.
///
/// Hours are required: audiobook chapters and long DJ sets routinely exceed
/// an hour, and an hourless form reads a 78-minute chapter as "78:00".
///
/// Format is deliberately not localised: these are elapsed-time readouts
/// alongside a scrubber, where digits are read positionally, and every media
/// player writes them the same way.
import Foundation

public enum PlaybackTimeFormat {

    /// `m:ss`, or `h:mm:ss` once the duration reaches an hour.
    ///
    /// Negative and non-finite inputs are clamped to zero: a seek can briefly
    /// report a negative offset, and a NaN would render as "nan:0-1".
    public static func string(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0:00" }
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Convenience for the many call sites holding whole seconds.
    /// The speaker's own `res duration` form, hours always present:
    /// "0:03:20". Queue rows mix speaker-supplied and learned values,
    /// so both must read the same.
    public static func didlString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    public static func string(seconds: Int) -> String {
        string(TimeInterval(seconds))
    }

    /// The inverse: `h:mm:ss`, `m:ss`, or bare seconds, with an optional
    /// fractional tail (`0:03:45.120` — the DIDL `res@duration` form the
    /// speaker writes). Nil for anything that does not parse, so a missing
    /// or malformed duration counts as unknown rather than as zero.
    public static func seconds(from text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard let value = isLast ? Double(part) : Double(part).flatMap({ $0 == $0.rounded() ? $0 : nil }),
                  value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
