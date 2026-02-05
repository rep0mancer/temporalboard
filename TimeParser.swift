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
        // Higher-specificity patterns first to avoid false positives.
        
        // 1. Compound duration: "1h 30m", "1 hour 30 minutes"
        if let result = parseCompoundDuration(in: cleanText, now: now) {
            return result
        }
        
        // 2. Simple duration: "30 min", "45m", "2h", "1 stunde", "90s"
        if let result = parseDuration(in: cleanText, now: now) {
            return result
        }
        
        // 3. Absolute time with AM/PM: "2:30 PM", "11am"
        if let result = parseAbsoluteTimeAMPM(in: cleanText, now: now) {
            return result
        }
        
        // 4. Absolute time 24h: "14:30", "9:05", "9.05"
        if let result = parseAbsoluteTime(in: cleanText, now: now) {
            return result
        }
        
        // 5. "at" prefixed time: "at 3", "at 15", "at 3pm"
        if let result = parseAtTime(in: cleanText, now: now) {
            return result
        }
        
        // 6. Bare hour with am/pm: "3pm", "11am"
        if let result = parseBareHourAMPM(in: cleanText, now: now) {
            return result
        }
        
        // 7. Date with optional time: "03.02", "03/02 14:30"
        if let result = parseDateExpression(in: cleanText, now: now) {
            return result
        }
        
        return nil
    }
    
    // MARK: - Compound Duration ("1h 30m", "1 hour 30 min", "2h30m")
    
    private let compoundDurationPattern: String = {
        let hourUnits = "h|hr|hrs|hour|hours|hora|horas|heure|heures|ora|ore|stunde|stunden|std"
        let minuteUnits = "m|min|mins|minute|minutes|minuto|minutos|minuti|minuten"
        // Matches: 1h 30m, 1h30m, 1 hour 30 minutes, etc.
        return #"(\d{1,3})\s*(?:"# + hourUnits + #")\s*(\d{1,3})\s*(?:"# + minuteUnits + #")"#
    }()
    
    private func parseCompoundDuration(in text: String, now: Date) -> TimeParseResult? {
        guard let regex = try? NSRegularExpression(pattern: compoundDurationPattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        
        guard let hoursRange = Range(match.range(at: 1), in: text),
              let minutesRange = Range(match.range(at: 2), in: text) else { return nil }
        
        guard let hours = Int(text[hoursRange]), hours >= 0, hours <= 48,
              let minutes = Int(text[minutesRange]), minutes >= 0, minutes <= 59 else { return nil }
        
        let totalMinutes = hours * 60 + minutes
        guard totalMinutes > 0 else { return nil }
        
        guard let targetDate = calendar.date(byAdding: .minute, value: totalMinutes, to: now) else { return nil }
        
        guard let fullRange = Range(match.range(at: 0), in: text) else { return nil }
        
        return TimeParseResult(targetDate: targetDate, matchRange: fullRange, isDuration: true)
    }
    
    // MARK: - Simple Duration ("30 min", "2h", "45m", "1 stunde", "90s", "90 sec")
    
    private let durationPattern: String = {
        let secondUnits = "s|sec|secs|second|seconds|sekunde|sekunden|sek"
        let minuteUnits = "m|min|mins|minute|minutes|minuto|minutos|minuti|minuten"
        let hourUnits = "h|hr|hrs|hour|hours|hora|horas|heure|heures|ora|ore|stunde|stunden|std"
        return #"(?:^|\s|[^\d])(\d{1,4})\s*("# + secondUnits + "|" + minuteUnits + "|" + hourUnits + #")(?:\s|$|[^\w])"#
    }()
    
    private static let hourUnitsSet: Set<String> = [
        "h", "hr", "hrs", "hour", "hours",
        "hora", "horas", "heure", "heures",
        "ora", "ore", "stunde", "stunden", "std"
    ]
    
    private static let secondUnitsSet: Set<String> = [
        "s", "sec", "secs", "second", "seconds",
        "sekunde", "sekunden", "sek"
    ]
    
    private func parseDuration(in text: String, now: Date) -> TimeParseResult? {
        guard let regex = try? NSRegularExpression(pattern: durationPattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        
        guard let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        
        let valueStr = String(text[valueRange])
        let unitStr = String(text[unitRange]).lowercased()
        
        guard let value = Int(valueStr), value > 0, value <= 2880 else { return nil }
        
        let targetDate: Date?
        if Self.hourUnitsSet.contains(unitStr) {
            targetDate = calendar.date(byAdding: .hour, value: value, to: now)
        } else if Self.secondUnitsSet.contains(unitStr) {
            targetDate = calendar.date(byAdding: .second, value: value, to: now)
        } else {
            targetDate = calendar.date(byAdding: .minute, value: value, to: now)
        }
        
        guard let date = targetDate else { return nil }
        
        let fullRange = valueRange.lowerBound..<unitRange.upperBound
        return TimeParseResult(targetDate: date, matchRange: fullRange, isDuration: true)
    }
    
    // MARK: - Absolute Time with AM/PM ("2:30 PM", "11:00am", "2.30 pm")
    
    private let absoluteTimeAMPMPattern = #"(?:^|\s)(\d{1,2})[:\.](\d{2})\s*(am|pm|a\.m\.|p\.m\.)(?:\s|$|[^\w])"#
    
    private func parseAbsoluteTimeAMPM(in text: String, now: Date) -> TimeParseResult? {
        guard let regex = try? NSRegularExpression(pattern: absoluteTimeAMPMPattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        
        guard let hourRange = Range(match.range(at: 1), in: text),
              let minuteRange = Range(match.range(at: 2), in: text),
              let periodRange = Range(match.range(at: 3), in: text) else { return nil }
        
        guard var hour = Int(text[hourRange]),
              let minute = Int(text[minuteRange]) else { return nil }
        
        guard hour >= 1 && hour <= 12 && minute >= 0 && minute <= 59 else { return nil }
        
        let period = text[periodRange].lowercased().replacingOccurrences(of: ".", with: "")
        
        // Convert to 24h
        if period == "am" {
            if hour == 12 { hour = 0 }
        } else {
            if hour != 12 { hour += 12 }
        }
        
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        
        guard var targetDate = calendar.date(from: components) else { return nil }
        
        if targetDate <= now {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDate) else { return nil }
            targetDate = nextDay
        }
        
        let fullRange = hourRange.lowerBound..<periodRange.upperBound
        return TimeParseResult(targetDate: targetDate, matchRange: fullRange, isDuration: false)
    }
    
    // MARK: - Absolute Time 24h ("14:30", "9:05", "9.05")
    
    private let absoluteTimePattern = #"(?:^|\s)(\d{1,2})[:\.](\d{2})(?:\s|$|[^\w\d])"#
    
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
        
        if targetDate <= now {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDate) else { return nil }
            targetDate = nextDay
        }
        
        let fullRange = hourRange.lowerBound..<minuteRange.upperBound
        return TimeParseResult(targetDate: targetDate, matchRange: fullRange, isDuration: false)
    }
    
    // MARK: - "at" prefixed time ("at 3", "at 15", "at 3pm", "at 3:30")
    
    private let atTimePattern = #"(?:^|\s)(?:at|@|um|à)\s+(\d{1,2})(?:[:\.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?:\s|$|[^\w])"#
    
    private func parseAtTime(in text: String, now: Date) -> TimeParseResult? {
        guard let regex = try? NSRegularExpression(pattern: atTimePattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        
        guard let hourRange = Range(match.range(at: 1), in: text) else { return nil }
        guard var hour = Int(text[hourRange]) else { return nil }
        
        var minute = 0
        var endBound = hourRange.upperBound
        
        // Optional minute
        if match.range(at: 2).location != NSNotFound,
           let minRange = Range(match.range(at: 2), in: text),
           let m = Int(text[minRange]) {
            minute = m
            endBound = minRange.upperBound
        }
        
        // Optional AM/PM
        if match.range(at: 3).location != NSNotFound,
           let periodRange = Range(match.range(at: 3), in: text) {
            let period = text[periodRange].lowercased().replacingOccurrences(of: ".", with: "")
            if hour >= 1 && hour <= 12 {
                if period == "am" {
                    if hour == 12 { hour = 0 }
                } else {
                    if hour != 12 { hour += 12 }
                }
            }
            endBound = periodRange.upperBound
        }
        
        guard hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 else { return nil }
        
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        
        guard var targetDate = calendar.date(from: components) else { return nil }
        
        if targetDate <= now {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDate) else { return nil }
            targetDate = nextDay
        }
        
        let fullRange = hourRange.lowerBound..<endBound
        return TimeParseResult(targetDate: targetDate, matchRange: fullRange, isDuration: false)
    }
    
    // MARK: - Bare hour with AM/PM ("3pm", "11am", "3 pm")
    
    private let bareHourAMPMPattern = #"(?:^|\s)(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)(?:\s|$|[^\w])"#
    
    private func parseBareHourAMPM(in text: String, now: Date) -> TimeParseResult? {
        guard let regex = try? NSRegularExpression(pattern: bareHourAMPMPattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        
        guard let hourRange = Range(match.range(at: 1), in: text),
              let periodRange = Range(match.range(at: 2), in: text) else { return nil }
        
        guard var hour = Int(text[hourRange]) else { return nil }
        guard hour >= 1 && hour <= 12 else { return nil }
        
        let period = text[periodRange].lowercased().replacingOccurrences(of: ".", with: "")
        
        if period == "am" {
            if hour == 12 { hour = 0 }
        } else {
            if hour != 12 { hour += 12 }
        }
        
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = 0
        components.second = 0
        
        guard var targetDate = calendar.date(from: components) else { return nil }
        
        if targetDate <= now {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDate) else { return nil }
            targetDate = nextDay
        }
        
        let fullRange = hourRange.lowerBound..<periodRange.upperBound
        return TimeParseResult(targetDate: targetDate, matchRange: fullRange, isDuration: false)
    }
    
    // MARK: - Date Expression ("03.02", "03.02 14:30", "3/2")
    
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
