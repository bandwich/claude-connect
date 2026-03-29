// ios-voice-app/ClaudeConnect/ClaudeConnect/Utils/TimeFormatter.swift
import Foundation

enum TimeFormatter {
    static func relativeTimeString(from timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            let seconds = Int(interval)
            return seconds == 1 ? "1 second ago" : "\(seconds) seconds ago"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        } else if interval < 172800 {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return formatter.string(from: date)
        }
    }
}
