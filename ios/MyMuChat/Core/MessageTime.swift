import Foundation

/// Short human label for a message timestamp — the same buckets the web
/// client's `formatMessageTimestamp` uses, so both products narrate time
/// identically: "Just now", "12 mins ago", "3 hours ago", "Yesterday 14:32",
/// "Mon 09:10", and a full date once a week has passed.
enum MessageTime {
    static func label(_ iso: String?, now: Date = Date()) -> String? {
        guard let iso, let date = RelayClient.parseISO(iso) else { return nil }
        let elapsed = now.timeIntervalSince(date)
        // Clock-skew / same-minute sends land here too.
        if elapsed < 60 { return "Just now" }

        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let dayDiff = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                         to: cal.startOfDay(for: now)).day ?? 0
        if dayDiff <= 0 {
            let mins = Int(elapsed / 60)
            if mins < 60 { return mins == 1 ? "1 min ago" : "\(mins) mins ago" }
            let hours = Int(elapsed / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        if dayDiff == 1 { return "Yesterday \(time)" }
        if dayDiff < 7 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return "\(date.formatted(date: .numeric, time: .omitted)) \(time)"
    }
}
