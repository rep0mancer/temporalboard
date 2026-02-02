import Foundation
import CoreGraphics

struct BoardTimer: Identifiable, Codable {
    var id: UUID = UUID()
    var originalText: String
    var targetDate: Date
    // Wir speichern das Zentrum des erkannten Textes relativ zum Canvas-Inhalt
    var anchorX: CGFloat
    var anchorY: CGFloat
    var isExpired: Bool = false
}
