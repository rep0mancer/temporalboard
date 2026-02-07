import EventKit
import Foundation

// MARK: - CalendarManager (EventKit Singleton)

/// Manages iOS Calendar integration for long-term or important timers.
/// Automatically creates / removes events in the user's default calendar.
///
/// A timer qualifies for a calendar event when:
/// - Its `targetDate` is more than 24 hours in the future, OR
/// - Its extracted `label` contains keywords like "Meeting", "Appointment",
///   "Call", "Doctor", "Dentist", "Birthday".
final class CalendarManager {
    
    static let shared = CalendarManager()
    
    private let store = EKEventStore()
    
    /// Keywords (lowercased) that mark a timer as "important" regardless of
    /// how far away the target date is.
    private static let importantKeywords: [String] = [
        "meeting", "appointment", "call", "doctor", "dentist", "birthday",
        "interview", "flight", "exam", "deadline", "conference", "review"
    ]
    
    private init() {}
    
    // MARK: - Authorization
    
    /// Current authorization status for calendar events (read-only convenience).
    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }
    
    /// Request calendar access.  Returns `true` when authorized.
    /// Handles `.authorized`, `.denied`, `.notDetermined`, and `.fullAccess` /
    /// `.writeOnly` introduced in iOS 17.
    @discardableResult
    func requestAccess() async -> Bool {
        let status = authorizationStatus
        
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            // iOS 17+ has a new two-tier API; fall back to the legacy path
            // on older versions.
            if #available(iOS 17.0, *) {
                do {
                    return try await store.requestFullAccessToEvents()
                } catch {
                    return false
                }
            } else {
                do {
                    return try await store.requestAccess(to: .event)
                } catch {
                    return false
                }
            }
        default:
            // Covers `.fullAccess` / `.writeOnly` on iOS 17+.
            // `.fullAccess` is what we need.  `.writeOnly` still allows
            // creating events but not reading them back — acceptable.
            return true
        }
    }
    
    // MARK: - Event Criteria
    
    /// Determines whether a timer qualifies for an iOS Calendar event.
    ///
    /// Criteria:
    /// 1. `targetDate` is more than 24 hours from now, OR
    /// 2. `label` contains an "important" keyword.
    func shouldCreateCalendarEvent(targetDate: Date, label: String?) -> Bool {
        // Criterion 1: long-term timer (> 24 h away)
        let hoursAway = targetDate.timeIntervalSince(Date()) / 3600
        if hoursAway > 24 {
            return true
        }
        
        // Criterion 2: important keyword in the label
        if let label = label {
            let lowered = label.lowercased()
            for keyword in Self.importantKeywords {
                if lowered.contains(keyword) {
                    return true
                }
            }
        }
        
        return false
    }
    
    // MARK: - Add Event
    
    /// Creates a 1-hour event in the user's default calendar.
    /// - Parameters:
    ///   - title: The event title (typically the timer label or original text).
    ///   - date: The start date for the event.
    /// - Returns: The `eventIdentifier` string if the event was saved, or `nil`
    ///   on failure / denied access.
    func addEvent(title: String, date: Date) async -> String? {
        guard await requestAccess() else { return nil }
        
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = date
        event.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date
        event.calendar = store.defaultCalendarForNewEvents
        
        // Add a 15-minute reminder so the user gets an alert before the event.
        let alarm = EKAlarm(relativeOffset: -15 * 60)
        event.addAlarm(alarm)
        
        event.notes = "Created by TemporalBoard"
        
        do {
            try store.save(event, span: .thisEvent)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }
    
    // MARK: - Delete Event
    
    /// Removes a previously created calendar event by its identifier.
    /// Fails silently if the event no longer exists or access is denied.
    func deleteEvent(identifier: String) {
        guard authorizationStatus == .authorized ||
              authorizationStatus != .denied else { return }
        
        guard let event = store.event(withIdentifier: identifier) else { return }
        
        try? store.remove(event, span: .thisEvent)
    }
}
