import Foundation

class TimeParser {
    
    // Use system locale instead of hardcoded locale
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale.current
        return cal
    }()
    
    func parse(text: String) -> Date? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()
        
        // 1. Relative duration: "30 min", "45m", "1h"
        let durationPattern = #"^(\d+)\s*(m|min|mins|minute|minutes|minuto|minutos|minuti|minuten|h|hr|hrs|hour|hours|hora|horas|heure|heures|ora|ore|stunde|stunden|std)$"#
        if let match = cleanText.matches(for: durationPattern)?.first {
            let value = Int(match.1) ?? 0
            let unit = match.2
            let hourUnits: Set<String> = [
                "h", "hr", "hrs", "hour", "hours",
                "hora", "horas", "heure", "heures",
                "ora", "ore", "stunde", "stunden", "std"
            ]
            
            if hourUnits.contains(unit) {
                return calendar.date(byAdding: .hour, value: value, to: now)
            } else {
                return calendar.date(byAdding: .minute, value: value, to: now)
            }
        }
        
        // 2. Absolute time (today or next day): "14:30", "9:05"
        let timePattern = #"^(\d{1,2})[:\.](\d{2})$"#
        if let match = cleanText.matches(for: timePattern)?.first {
            guard let hour = Int(match.1), let minute = Int(match.2) else { return nil }
            
            // Validate hour and minute ranges
            guard hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 else { return nil }
            
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            
            guard let targetDate = calendar.date(from: components) else { return nil }
            
            // RELAXED PAST-TIME CHECK:
            // If the time is in the past, assume the user means the NEXT occurrence.
            // This handles both:
            // - Times that just passed (for logging/reference purposes)
            // - Times that were meant for tomorrow
            if targetDate <= now {
                // Time is in the past - assume next day
                if let nextDayDate = calendar.date(byAdding: .day, value: 1, to: targetDate) {
                    return nextDayDate
                }
            }
            
            return targetDate
        }
        
        // 3. Date format: "03.02", "3.2", optionally with time "03.02 14:30"
        let datePattern = #"^(\d{1,2})[./](\d{1,2})(?:\s+(\d{1,2})[:\.](\d{2}))?$"#
        if let match = cleanText.matches(for: datePattern)?.first {
            guard let day = Int(match.1), let month = Int(match.2) else { return nil }
            
            // Validate day and month ranges
            guard day >= 1 && day <= 31 && month >= 1 && month <= 12 else { return nil }
            
            var components = calendar.dateComponents([.year], from: now)
            components.day = day
            components.month = month
            
            // Default time is 09:00 if not specified
            if let hStr = match.3, let mStr = match.4,
               !hStr.isEmpty, !mStr.isEmpty,
               let h = Int(hStr), let m = Int(mStr) {
                // Validate hour/minute
                guard h >= 0 && h <= 23 && m >= 0 && m <= 59 else { return nil }
                components.hour = h
                components.minute = m
            } else {
                components.hour = 9
                components.minute = 0
            }
            components.second = 0
            
            guard let targetDate = calendar.date(from: components) else { return nil }
            
            // If the date has passed this year, assume next year
            if targetDate < now {
                components.year = (components.year ?? calendar.component(.year, from: now)) + 1
                if let nextYearDate = calendar.date(from: components) {
                    return nextYearDate
                }
            }
            
            return targetDate
        }
        
        return nil
    }
}

// MARK: - String Regex Extension

extension String {
    /// Matches the string against a regex pattern and returns captured groups.
    /// Returns an array of tuples containing the full match and up to 4 capture groups.
    func matches(for regex: String) -> [(String, String, String?, String?, String?)]? {
        do {
            let regex = try NSRegularExpression(pattern: regex, options: .caseInsensitive)
            let results = regex.matches(in: self, range: NSRange(self.startIndex..., in: self))
            
            return results.map { result in
                let text = self
                func stringForRange(_ range: NSRange) -> String? {
                    guard range.location != NSNotFound,
                          let swiftRange = Range(range, in: text) else {
                        return nil
                    }
                    return String(text[swiftRange])
                }
                
                // Extract capture groups safely
                let g1 = stringForRange(result.range(at: 1)) ?? ""
                let g2 = stringForRange(result.range(at: 2)) ?? ""
                
                let g3 = stringForRange(result.range(at: 3))
                let g4 = stringForRange(result.range(at: 4))
                
                let fullMatch = stringForRange(result.range(at: 0)) ?? ""
                return (fullMatch, g1, g2, g3, g4)
            }
        } catch {
            return nil
        }
    }
}
