import Foundation

enum DateFormat {
    /// "Today", "Yesterday", "Monday", "Mar 5"
    static func relativeShort(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Mar 5, 2026"
    static func headerLong(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "2:34 PM" or "2:34:05 PM"
    static func timeOfDay(_ date: Date, includeSeconds: Bool = false) -> String {
        if includeSeconds {
            return date.formatted(.dateTime.hour().minute().second())
        }
        return date.formatted(.dateTime.hour().minute())
    }

    /// "5m ago", "2h ago", "3d ago", "just now"
    static func ageShort(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "\(elapsed)s ago" }
        if elapsed < 3600 { return "\(elapsed / 60)m ago" }
        if elapsed < 86400 { return "\(elapsed / 3600)h ago" }
        return "\(elapsed / 86400)d ago"
    }
}
