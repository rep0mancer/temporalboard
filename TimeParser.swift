import Foundation

/// Result of parsing a time expression from within a larger text.
struct TimeParseResult {
    /// The date/time that was parsed (either absolute or relative from now).
    let targetDate: Date
    /// The range of the time expression within the original text.
    let matchRange: Range<String.Index>
    /// Whether this is a countdown duration (e.g. "15 min") vs an absolute clock time.
    let isDuration: Bool
}

class TimeParser {
    
    // Use system locale instead of hardcoded locale
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale.current
        return cal
    }()
    
    // MARK: - Public API
    
    /// Parse the first recognized time expression found anywhere in the text.
    /// Returns a Date suitable for use as a timer target, or nil if no time found.
    func parse(text: String) -> Date? {
        return parseDetailed(text: text)?.targetDate
    }
    
    /// Parse with full details including the matched range within the source text.
    func parseDetailed(text: String) -> TimeParseResult? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        let now = Date()
        
        // Try each pattern in priority order.
        // We search within the text (not requiring the entire text to match).
        
        // 1. Duration: "30 min", "45m", "2h", "1 stunde"
        if let result = parseDuration(in: cleanText, now: now) {
            return result
        }
        
        // 2. Absolute time: "14:30", "9:05", "9.05"
        if let result = parseAbsoluteTime(in: cleanText, now: now) {
            return result
        }
        
        // 3. Date with optional time: "03.02", "03.02 14:30"
        if let result = parseDateExpression(in: cleanText, now: now) {
            return result
        }
        
        return nil
    }
    
    // MARK: - Duration ("30 min", "2h", "45m", "1 stunde")
    
    private let durationPattern: String = {
        let minuteUnits = "m|min|mins|minute|minutes|minuto|minutos|minuti|minuten"
        let hourUnits = "h|hr|hrs|hour|hours|hora|horas|heure|heures|ora|ore|stunde|stunden|std"
        // Match a number followed by a unit, possibly separated by whitespace.
        // The pattern is NOT anchored — it can appear anywhere in the text.
        return #"(?:^|\s|[^\d])(\d{1,3})\s*("# + minuteUnits + "|" + hourUnits + #")(?:\s|$|[^\w])"#
    }()
    
    private static let hourUnitsSet: Set<String> = [
        "h", "hr", "hrs", "hour", "hours",
        "hora", "horas", "heure", "heures",
        "ora", "ore", "stunde", "stunden", "std"
    ]
    
    private func parseDuration(in text: String, now: Date) -> TimeParseResult? {
        guard let regex = try? NSRegularExpression(pattern: durationPattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        
        guard let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        
        let valueStr = String(text[valueRange])
        let unitStr = String(text[unitRange]).lowercased()
        
        guard let value = Int(valueStr), value > 0, value <= 1440 else { return nil }
        
        let isHour = Self.hourUnitsSet.contains(unitStr)
        let targetDate: Date?
        if isHour {
            targetDate = calendar.date(byAdding: .hour, value: value, to: now)
        } else {
            targetDate = calendar.date(byAdding: .minute, value: value, to: now)
        }
        
        guard let date = targetDate else { return nil }
        
        // The overall match range covers from number start to unit end
        let fullRange = valueRange.lowerBound..<unitRange.upperBound
        
        return TimeParseResult(targetDate: date, matchRange: fullRange, isDuration: true)
    }
    
    // MARK: - Absolute Time ("14:30", "9:05")
    
    private let absoluteTimePattern = #"(?:^|\s)(\d{1,2})[:\.](\d{2})(?:\s|$)"#
    
    private func parseAbsoluteTime(in text: String, now: Date) -> TimeParseResult? {
        guard let regex = try? NSRegularExpression(pattern: absoluteTimePattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        
        guard let hourRange = Range(match.range(at: 1), in: text),
              let minuteRange = Range(match.range(at: 2), in: text) else { return nil }
        
        guard let hour = Int(text[hourRange]),
              let minute = Int(text[minuteRange]) else { return nil }
        
        guard hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 else { return nil }
        
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        
        guard var targetDate = calendar.date(from: components) else { return nil }
        
        // If the time has already passed today, assume the next day
        if targetDate <= now {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDate) else { return nil }
            targetDate = nextDay
        }
        
        let fullRange = hourRange.lowerBound..<minuteRange.upperBound
        return TimeParseResult(targetDate: targetDate, matchRange: fullRange, isDuration: false)
    }
    
    // MARK: - Date Expression ("03.02", "03.02 14:30")
    
    private let datePattern = #"(?:^|\s)(\d{1,2})[./](\d{1,2})(?:\s+(\d{1,2})[:\.](\d{2}))?(?:\s|$)"#
    
    private func parseDateExpression(in text: String, now: Date) -> TimeParseResult? {
        guard let regex = try? NSRegularExpression(pattern: datePattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        
        guard let dayRange = Range(match.range(at: 1), in: text),
              let monthRange = Range(match.range(at: 2), in: text) else { return nil }
        
        guard let day = Int(text[dayRange]),
              let month = Int(text[monthRange]) else { return nil }
        
        guard day >= 1 && day <= 31 && month >= 1 && month <= 12 else { return nil }
        
        var components = calendar.dateComponents([.year], from: now)
        components.day = day
        components.month = month
        
        // Check for optional time component
        var endBound = monthRange.upperBound
        
        if match.range(at: 3).location != NSNotFound,
           match.range(at: 4).location != NSNotFound,
           let hRange = Range(match.range(at: 3), in: text),
           let mRange = Range(match.range(at: 4), in: text),
           let h = Int(text[hRange]),
           let m = Int(text[mRange]),
           h >= 0, h <= 23, m >= 0, m <= 59 {
            components.hour = h
            components.minute = m
            endBound = mRange.upperBound
        } else {
            components.hour = 9
            components.minute = 0
        }
        components.second = 0
        
        guard let targetDate = calendar.date(from: components) else { return nil }
        
        // Past dates are not valid timers
        if targetDate < now {
            return nil
        }
        
        let fullRange = dayRange.lowerBound..<endBound
        return TimeParseResult(targetDate: targetDate, matchRange: fullRange, isDuration: false)
    }
}

// MARK: - String Regex Extension

extension String {
    /// Matches the string against a regex pattern and returns captured groups.
    /// Returns an array of tuples containing the full match and up to 4 capture groups.
    func matches(for regex: String) -> [(String, String, String, String?, String?)]? {
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
