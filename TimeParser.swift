import Foundation

/// Result of parsing a time expression from within a larger text.
struct TimeParseResult {
    /// The date/time that was parsed (either absolute or relative from now).
    let targetDate: Date
    /// The range of the time expression within the original text.
    let matchRange: Range<String.Index>
    /// Whether this is a countdown duration (e.g. "15 min") vs an absolute clock time.
    let isDuration: Bool
    /// Contextual label extracted from the surrounding text (e.g. "Call Mom" from
    /// "Call Mom in 15 min"). `nil` when the text contains only the time expression.
    let label: String?
    
    init(targetDate: Date, matchRange: Range<String.Index>, isDuration: Bool, label: String? = nil) {
        self.targetDate = targetDate
        self.matchRange = matchRange
        self.isDuration = isDuration
        self.label = label
    }
}

class TimeParser {
    
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale.current
        return cal
    }()
    
    // MARK: - Pre-compiled Regex Patterns
    // Compiled once and reused across all parsing calls to avoid repeated allocation.
    
    private static let compoundDurationRegex: NSRegularExpression = {
        let hourUnits = "h|hr|hrs|hour|hours|hora|horas|heure|heures|ora|ore|stunde|stunden|std"
        let minuteUnits = "m|min|mins|minute|minutes|minuto|minutos|minuti|minuten"
        let pattern = #"(\d{1,3}(?:\.\d+)?)\s*(?:"# + hourUnits + #")\s*(\d{1,3}(?:\.\d+)?)\s*(?:"# + minuteUnits + #")"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
    
    private static let durationRegex: NSRegularExpression = {
        let secondUnits = "s|sec|secs|second|seconds|sekunde|sekunden|sek"
        let minuteUnits = "m|min|mins|minute|minutes|minuto|minutos|minuti|minuten"
        let hourUnits = "h|hr|hrs|hour|hours|hora|horas|heure|heures|ora|ore|stunde|stunden|std"
        let pattern = #"(?:^|\s|[^\d])(\d{1,4}(?:\.\d+)?)\s*("# + secondUnits + "|" + minuteUnits + "|" + hourUnits + #")(?:\s|$|[^\w])"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
    
    private static let absoluteTimeAMPMRegex: NSRegularExpression = {
        let pattern = #"(?:^|\s)(\d{1,2})[:\.](\d{2})\s*(am|pm|a\.m\.|p\.m\.)(?:\s|$|[^\w])"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
    
    private static let absoluteTimeRegex: NSRegularExpression = {
        let pattern = #"(?:^|\s)(\d{1,2})[:\.](\d{2})(?:\s|$|[^\w\d])"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
    
    private static let atTimeRegex: NSRegularExpression = {
        let pattern = #"(?:^|\s)(?:at|@|um|à)\s+(\d{1,2})(?:[:\.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?:\s|$|[^\w])"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
    
    private static let bareHourAMPMRegex: NSRegularExpression = {
        let pattern = #"(?:^|\s)(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)(?:\s|$|[^\w])"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
    
    private static let dateRegex: NSRegularExpression = {
        let pattern = #"(?:^|\s)(\d{1,2})[./](\d{1,2})(?:\s+(\d{1,2})[:\.](\d{2}))?(?:\s|$)"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
    
    // MARK: - Public API
    
    /// Parse the first recognized time expression found anywhere in the text.
    /// Returns a Date suitable for use as a timer target, or nil if no time found.
    func parse(text: String) -> Date? {
        return parseDetailed(text: text)?.targetDate
    }
    
    /// Parse with full details including the matched range within the source text.
    /// Also extracts a contextual label from the surrounding text (e.g. "Call Mom"
    /// from "Call Mom in 15 min").
    func parseDetailed(text: String) -> TimeParseResult? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        let now = Date()
        
        // Try each pattern in priority order.
        // Higher-specificity patterns first to avoid false positives.
        
        var rawResult: TimeParseResult?
        
        // 1. Compound duration: "1h 30m", "1 hour 30 minutes"
        if rawResult == nil { rawResult = parseCompoundDuration(in: cleanText, now: now) }
        
        // 2. Simple duration: "30 min", "45m", "2h", "1 stunde", "90s"
        if rawResult == nil { rawResult = parseDuration(in: cleanText, now: now) }
        
        // 3. Absolute time with AM/PM: "2:30 PM", "11am"
        if rawResult == nil { rawResult = parseAbsoluteTimeAMPM(in: cleanText, now: now) }
        
        // 4. Absolute time 24h: "14:30", "9:05", "9.05"
        if rawResult == nil { rawResult = parseAbsoluteTime(in: cleanText, now: now) }
        
        // 5. "at" prefixed time: "at 3", "at 15", "at 3pm"
        if rawResult == nil { rawResult = parseAtTime(in: cleanText, now: now) }
        
        // 6. Bare hour with am/pm: "3pm", "11am"
        if rawResult == nil { rawResult = parseBareHourAMPM(in: cleanText, now: now) }
        
        // 7. Date with optional time: "03.02", "03/02 14:30"
        if rawResult == nil { rawResult = parseDateExpression(in: cleanText, now: now) }
        
        guard let result = rawResult else { return nil }
        
        // Extract a contextual label from the text surrounding the time expression.
        let label = extractLabel(from: cleanText, excluding: result.matchRange)
        
        return TimeParseResult(
            targetDate: result.targetDate,
            matchRange: result.matchRange,
            isDuration: result.isDuration,
            label: label
        )
    }
    
    // MARK: - Compound Duration ("1h 30m", "1 hour 30 min", "2h30m")
    
    private func parseCompoundDuration(in text: String, now: Date) -> TimeParseResult? {
        let regex = Self.compoundDurationRegex
        let nsRange = NSRange(text.startIndex..., in: text)
        
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        
        guard let hoursRange = Range(match.range(at: 1), in: text),
              let minutesRange = Range(match.range(at: 2), in: text) else { return nil }
        
        guard let hours = Double(text[hoursRange]), hours >= 0, hours <= 48,
              let minutes = Double(text[minutesRange]), minutes >= 0, minutes <= 59 else { return nil }
        
        // Convert to total seconds so decimal values (e.g. 1.5h 30m) are calculated correctly.
        let totalSeconds = Int(round(hours * 3600 + minutes * 60))
        guard totalSeconds > 0 else { return nil }
        
        guard let targetDate = calendar.date(byAdding: .second, value: totalSeconds, to: now) else { return nil }
        
        guard let fullRange = Range(match.range(at: 0), in: text) else { return nil }
        
        return TimeParseResult(targetDate: targetDate, matchRange: fullRange, isDuration: true)
    }
    
    // MARK: - Simple Duration ("30 min", "2h", "45m", "1 stunde", "90s", "90 sec")
    
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
        let regex = Self.durationRegex
        let nsRange = NSRange(text.startIndex..., in: text)
        
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        
        guard let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        
        let valueStr = String(text[valueRange])
        let unitStr = String(text[unitRange]).lowercased()
        
        guard let value = Double(valueStr), value > 0, value <= 2880 else { return nil }
        
        // Convert to total seconds so decimal values (e.g. 1.5h = 90 min) are exact.
        let totalSeconds: Int
        if Self.hourUnitsSet.contains(unitStr) {
            totalSeconds = Int(round(value * 3600))
        } else if Self.secondUnitsSet.contains(unitStr) {
            totalSeconds = Int(round(value))
        } else {
            // Minutes
            totalSeconds = Int(round(value * 60))
        }
        
        let targetDate = calendar.date(byAdding: .second, value: totalSeconds, to: now)
        
        guard let date = targetDate else { return nil }
        
        let fullRange = valueRange.lowerBound..<unitRange.upperBound
        return TimeParseResult(targetDate: date, matchRange: fullRange, isDuration: true)
    }
    
    // MARK: - Absolute Time with AM/PM ("2:30 PM", "11:00am", "2.30 pm")
    
    private func parseAbsoluteTimeAMPM(in text: String, now: Date) -> TimeParseResult? {
        let regex = Self.absoluteTimeAMPMRegex
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
    
    private func parseAbsoluteTime(in text: String, now: Date) -> TimeParseResult? {
        let regex = Self.absoluteTimeRegex
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
    
    private func parseAtTime(in text: String, now: Date) -> TimeParseResult? {
        let regex = Self.atTimeRegex
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
    
    private func parseBareHourAMPM(in text: String, now: Date) -> TimeParseResult? {
        let regex = Self.bareHourAMPMRegex
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
    
    private func parseDateExpression(in text: String, now: Date) -> TimeParseResult? {
        let regex = Self.dateRegex
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
        
        guard var targetDate = calendar.date(from: components) else { return nil }
        
        // If the date is in the past, roll forward to the same date next year.
        if targetDate < now {
            guard let year = components.year else { return nil }
            components.year = year + 1
            guard let nextYear = calendar.date(from: components) else { return nil }
            targetDate = nextYear
        }
        
        let fullRange = dayRange.lowerBound..<endBound
        return TimeParseResult(targetDate: targetDate, matchRange: fullRange, isDuration: false)
    }
    
    // MARK: - Contextual Label Extraction
    
    /// Prepositions / connector words that commonly bridge a label and a time
    /// expression. These are stripped from the edges of the extracted label so
    /// "Call Mom in 15 min" yields "Call Mom" rather than "Call Mom in".
    /// Kept intentionally conservative — only words that serve purely as
    /// time-expression connectors, not content words.
    private static let connectorWords: Set<String> = [
        // English
        "in", "at", "for", "by", "after", "before", "about", "around", "within",
        // German
        "um", "für", "nach", "bis", "gegen", "etwa",
        // French
        "à", "dans", "pour", "vers",
        // Italian / Spanish
        "tra", "fra", "en", "sobre"
    ]
    
    /// Extract a human-readable label from the text surrounding the matched
    /// time expression.  Returns `nil` when the text is *only* the time
    /// expression (e.g. "15 min") with no meaningful surrounding context.
    ///
    /// Examples:
    /// - "Call Mom in 15 min"  → "Call Mom"
    /// - "Meeting 2pm"         → "Meeting"
    /// - "15 min"              → nil
    /// - "Pick up kids at 3:30 PM" → "Pick up kids"
    private func extractLabel(from text: String, excluding matchRange: Range<String.Index>) -> String? {
        let before = text[text.startIndex..<matchRange.lowerBound]
        let after  = text[matchRange.upperBound..<text.endIndex]
        
        var combined = (String(before) + " " + String(after))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Iteratively strip connector words from the end.
        var changed = true
        while changed && !combined.isEmpty {
            changed = false
            let lower = combined.lowercased()
            for connector in Self.connectorWords {
                if lower == connector {
                    combined = ""
                    changed = true
                    break
                }
                if lower.hasSuffix(" " + connector) {
                    combined = String(combined.dropLast(connector.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }
        
        // Iteratively strip connector words from the start.
        changed = true
        while changed && !combined.isEmpty {
            changed = false
            let lower = combined.lowercased()
            for connector in Self.connectorWords {
                if lower == connector {
                    combined = ""
                    changed = true
                    break
                }
                if lower.hasPrefix(connector + " ") {
                    combined = String(combined.dropFirst(connector.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }
        
        // Clean up stray punctuation at edges.
        combined = combined.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-–—,;."))
        )
        
        return combined.isEmpty ? nil : combined
    }
}

