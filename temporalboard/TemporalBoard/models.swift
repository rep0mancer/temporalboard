import Foundation
import CoreGraphics
import UIKit

struct BoardTimer: Identifiable, Codable {
    var id: UUID = UUID()
    var originalText: String
    var targetDate: Date
    /// Centre of the recognized text, relative to canvas content coordinates.
    var anchorX: CGFloat
    var anchorY: CGFloat
    /// Full bounding rect of the recognized handwritten line (content coordinates).
    var textRect: CGRect = .zero
    var isExpired: Bool = false
    /// Whether the timer is a countdown duration (true) vs absolute clock time (false).
    var isDuration: Bool = true
    /// Pen color captured from the strokes at recognition time (stored as hex).
    var penColorHex: String = "#000000"
    /// Whether the user has acknowledged / dismissed the expiration alert.
    var isDismissed: Bool = false
    /// Contextual label extracted from the surrounding handwritten text
    /// (e.g. "Call Mom" from "Call Mom in 15 min"). `nil` when the text
    /// contained only the time expression.
    var label: String?
    /// EventKit event identifier when the timer has been added to the iOS
    /// Calendar (long-term or keyword-important timers). `nil` otherwise.
    var calendarEventID: String?
    /// True when the recognized time came from an explicit date expression
    /// (e.g. "24.02 10:00", "24. Februar 10:00"), not just a relative duration
    /// or standalone clock time.
    var isExplicitDate: Bool = false
    
    // MARK: - Codable conformance for CGRect
    
    enum CodingKeys: String, CodingKey {
        case id, originalText, targetDate, anchorX, anchorY
        case textRectX, textRectY, textRectW, textRectH
        case isExpired, isDuration, penColorHex, isDismissed
        case label, calendarEventID, isExplicitDate
    }
    
    init(originalText: String, targetDate: Date, anchorX: CGFloat, anchorY: CGFloat,
         textRect: CGRect = .zero, isDuration: Bool = true, penColorHex: String = "#000000",
         label: String? = nil, calendarEventID: String? = nil, isExplicitDate: Bool = false) {
        self.originalText = originalText
        self.targetDate = targetDate
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.textRect = textRect
        self.isDuration = isDuration
        self.penColorHex = penColorHex
        self.label = label
        self.calendarEventID = calendarEventID
        self.isExplicitDate = isExplicitDate
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        originalText = try c.decode(String.self, forKey: .originalText)
        targetDate = try c.decode(Date.self, forKey: .targetDate)
        anchorX = try c.decode(CGFloat.self, forKey: .anchorX)
        anchorY = try c.decode(CGFloat.self, forKey: .anchorY)
        isExpired = try c.decodeIfPresent(Bool.self, forKey: .isExpired) ?? false
        isDuration = try c.decodeIfPresent(Bool.self, forKey: .isDuration) ?? true
        penColorHex = try c.decodeIfPresent(String.self, forKey: .penColorHex) ?? "#000000"
        isDismissed = try c.decodeIfPresent(Bool.self, forKey: .isDismissed) ?? false
        label = try c.decodeIfPresent(String.self, forKey: .label)
        calendarEventID = try c.decodeIfPresent(String.self, forKey: .calendarEventID)
        isExplicitDate = try c.decodeIfPresent(Bool.self, forKey: .isExplicitDate) ?? false
        let x = try c.decodeIfPresent(CGFloat.self, forKey: .textRectX) ?? 0
        let y = try c.decodeIfPresent(CGFloat.self, forKey: .textRectY) ?? 0
        let w = try c.decodeIfPresent(CGFloat.self, forKey: .textRectW) ?? 0
        let h = try c.decodeIfPresent(CGFloat.self, forKey: .textRectH) ?? 0
        textRect = CGRect(x: x, y: y, width: w, height: h)
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(originalText, forKey: .originalText)
        try c.encode(targetDate, forKey: .targetDate)
        try c.encode(anchorX, forKey: .anchorX)
        try c.encode(anchorY, forKey: .anchorY)
        try c.encode(isExpired, forKey: .isExpired)
        try c.encode(isDuration, forKey: .isDuration)
        try c.encode(penColorHex, forKey: .penColorHex)
        try c.encode(isDismissed, forKey: .isDismissed)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(calendarEventID, forKey: .calendarEventID)
        try c.encode(isExplicitDate, forKey: .isExplicitDate)
        try c.encode(textRect.origin.x, forKey: .textRectX)
        try c.encode(textRect.origin.y, forKey: .textRectY)
        try c.encode(textRect.size.width, forKey: .textRectW)
        try c.encode(textRect.size.height, forKey: .textRectH)
    }
}

// MARK: - UIColor Hex Helpers

extension UIColor {
    /// Creates a color from a hex string (e.g. "#FF0000" or "FF0000").
    /// Falls back to `.label` if the string is malformed.
    convenience init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        // Validate that we have exactly 6 hex characters
        guard hexSanitized.count == 6,
              hexSanitized.allSatisfy({ $0.isHexDigit }) else {
            self.init(cgColor: UIColor.label.cgColor)
            return
        }
        
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
    
    /// Returns a hex string representation of this color in sRGB space.
    /// Converts from extended (Display P3) color spaces to avoid clamping issues.
    var hexString: String {
        // Convert to sRGB to avoid issues with Display P3 or other wide-gamut colors.
        guard let sRGB = cgColor.converted(to: CGColorSpaceCreateDeviceRGB(),
                                           intent: .defaultIntent,
                                           options: nil) else {
            return "#000000"
        }
        
        let components = sRGB.components ?? [0, 0, 0]
        let r = max(0, min(1, components.count > 0 ? components[0] : 0))
        let g = max(0, min(1, components.count > 1 ? components[1] : 0))
        let b = max(0, min(1, components.count > 2 ? components[2] : 0))
        
        return String(format: "#%02X%02X%02X",
                      Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
