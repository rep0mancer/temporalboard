import Foundation

class TimeParser {
    
    // Wir nutzen den gregorianischen Kalender mit deutscher Locale für das Parsen
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "de_AT")
        return cal
    }()
    
    private let defaultHour: Int
    private let defaultMinute: Int
    
    init(defaultHour: Int, defaultMinute: Int) {
        self.defaultHour = defaultHour
        self.defaultMinute = defaultMinute
    }
    
    func parse(text: String) -> Date? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()
        
        // 1. Relative Dauer: "30 min", "45m", "1h"
        // Regex für Zahl gefolgt von m, min, mins, h, hour
        let durationPattern = #"^(\d+)\s*(m|min|mins|minutes|h|hour|hours)$"#
        if let match = cleanText.matches(for: durationPattern).first {
            let value = Int(match.1) ?? 0
            let unit = match.2
            
            if unit.starts(with: "h") {
                return calendar.date(byAdding: .hour, value: value, to: now)
            } else {
                return calendar.date(byAdding: .minute, value: value, to: now)
            }
        }
        
        // 2. Absolute Uhrzeit (Heute): "14:30", "9:05"
        let timePattern = #"^(\d{1,2})[:\.](\d{2})$"#
        if let match = cleanText.matches(for: timePattern).first {
            guard let hour = Int(match.1), let minute = Int(match.2) else { return nil }
            
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            
            guard let targetDate = calendar.date(from: components) else { return nil }
            
            // Wenn die Zeit heute schon vorbei ist (> 5 min Toleranz), ignorieren wir sie laut Anforderung
            if targetDate.timeIntervalSince(now) < -300 {
                return nil
            }
            // Wenn es knapp vorbei ist oder in der Zukunft liegt, nehmen wir es
            // (Optional: Wenn man 09:00 schreibt und es ist 14:00, könnte man morgen meinen, 
            // aber laut Anforderung: "Today")
            return targetDate
        }
        
        // 3. Datum (Zukunft): "03.02", "3.2" (optional mit Zeit)
        // Einfache Implementierung für "dd.MM" -> 09:00 Uhr Standard
        let datePattern = #"^(\d{1,2})[./](\d{1,2})(?:\s+(\d{1,2})[:\.](\d{2}))?$"#
        if let match = cleanText.matches(for: datePattern).first {
            guard let day = Int(match.1), let month = Int(match.2) else { return nil }
            
            var components = calendar.dateComponents([.year], from: now)
            components.day = day
            components.month = month
            
            // Standardzeit konfigurieren, falls keine Zeit angegeben
            if match.count > 3, let hStr = match.3, let mStr = match.4, let h = Int(hStr), let m = Int(mStr) {
                components.hour = h
                components.minute = m
            } else {
                components.hour = defaultHour
                components.minute = defaultMinute
            }
            
            guard let targetDate = calendar.date(from: components) else { return nil }
            
            // Falls das Datum dieses Jahr schon war, nehmen wir nächstes Jahr an?
            // V0-Regel: Einfach das Datum nehmen.
            if targetDate < now {
                 // Optionale Logik für Jahreswechsel hier einfügen, falls gewünscht
            }
            return targetDate
        }
        
        return nil
    }
}

// Hilfserweiterung für Regex
extension String {
    func matches(for regex: String) -> [(String, String, String?, String?, String?)]? {
        do {
            let regex = try NSRegularExpression(pattern: regex, options: .caseInsensitive)
            let results = regex.matches(in: self, range: NSRange(self.startIndex..., in: self))
            return results.map {
                let text = self
                // Wir extrahieren bis zu 4 Gruppen
                let g1 = $0.range(at: 1).location != NSNotFound ? String(text[Range($0.range(at: 1), in: text)!]) : ""
                let g2 = $0.range(at: 2).location != NSNotFound ? String(text[Range($0.range(at: 2), in: text)!]) : ""
                
                var g3: String? = nil
                if $0.numberOfRanges > 3, $0.range(at: 3).location != NSNotFound {
                    g3 = String(text[Range($0.range(at: 3), in: text)!])
                }
                var g4: String? = nil
                if $0.numberOfRanges > 4, $0.range(at: 4).location != NSNotFound {
                    g4 = String(text[Range($0.range(at: 4), in: text)!])
                }
                
                return (String(text[Range($0.range(at: 0), in: text)!]), g1, g2, g3, g4)
            }
        } catch {
            return nil
        }
    }
}
