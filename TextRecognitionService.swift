import Foundation
import PencilKit
import Vision
import UIKit

struct TimerMigration {
    let timerID: UUID
    let anchorX: CGFloat
    let anchorY: CGFloat
    let textRect: CGRect
}

struct TextRecognitionResult {
    let newTimers: [BoardTimer]
    let zombieIDs: Set<UUID>
    let migratedTimers: [TimerMigration]
    let updatedStrokeCount: Int
}

final class TextRecognitionService {
    private let timeParser = TimeParser()
    private let proximityDistanceSquared: CGFloat = 2500

    private struct RecognizedText {
        let text: String
        let normalizedText: String
        let centerX: CGFloat
        let centerY: CGFloat
        let textRect: CGRect
    }


    func recognize(
        drawing: PKDrawing,
        existingTimers: [BoardTimer],
        lastRecognizedStrokeCount: Int,
        displayScale: CGFloat,
        completion: @escaping (TextRecognitionResult) -> Void
    ) {
        let allStrokes = drawing.strokes
        let currentStrokeCount = allStrokes.count

        guard !allStrokes.isEmpty else {
            completion(TextRecognitionResult(newTimers: [], zombieIDs: [], migratedTimers: [], updatedStrokeCount: 0))
            return
        }

        let scanRect: CGRect
        if currentStrokeCount > lastRecognizedStrokeCount && lastRecognizedStrokeCount > 0 {
            let newStrokes = allStrokes[lastRecognizedStrokeCount...]
            var unionRect = CGRect.null
            for stroke in newStrokes {
                unionRect = unionRect.union(stroke.renderBounds)
            }
            scanRect = unionRect.insetBy(dx: -50, dy: -50)
        } else {
            scanRect = drawing.bounds
        }

        guard !scanRect.isEmpty, !scanRect.isNull else {
            completion(TextRecognitionResult(newTimers: [], zombieIDs: [], migratedTimers: [], updatedStrokeCount: currentStrokeCount))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let image = drawing.image(from: scanRect, scale: max(displayScale, 1))
            guard let cgImage = image.cgImage else {
                completion(TextRecognitionResult(newTimers: [], zombieIDs: [], migratedTimers: [], updatedStrokeCount: currentStrokeCount))
                return
            }

            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let processed = self.process(
                    observations: observations,
                    in: scanRect,
                    strokes: allStrokes,
                    existingTimers: existingTimers
                )
                completion(TextRecognitionResult(
                    newTimers: processed.newTimers,
                    zombieIDs: processed.zombieIDs,
                    migratedTimers: processed.migratedTimers,
                    updatedStrokeCount: currentStrokeCount
                ))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = self.recognitionLanguages()

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    private func recognitionLanguages() -> [String] {
        var languages: [String] = []
        for identifier in Locale.preferredLanguages {
            let normalized = Locale(identifier: identifier).identifier
            if !normalized.isEmpty, !languages.contains(normalized) {
                languages.append(normalized)
            }
        }
        for fallback in ["en-US", "de-DE"] where !languages.contains(fallback) {
            languages.append(fallback)
        }
        return Array(languages.prefix(3))
    }

    private func process(
        observations: [VNRecognizedTextObservation],
        in scanRect: CGRect,
        strokes: [PKStroke],
        existingTimers: [BoardTimer]
    ) -> (newTimers: [BoardTimer], zombieIDs: Set<UUID>, migratedTimers: [TimerMigration]) {
        var recognizedTexts: [RecognizedText] = []
        var newTimers: [BoardTimer] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            let box = observation.boundingBox
            let w = scanRect.width
            let h = scanRect.height
            let x = scanRect.origin.x + (box.origin.x * w)
            let y = scanRect.origin.y + ((1 - box.origin.y - box.height) * h)
            let rect = CGRect(x: x, y: y, width: box.width * w, height: box.height * h)
            let centerX = rect.midX
            let centerY = rect.midY
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            recognizedTexts.append(.init(text: text, normalizedText: normalized, centerX: centerX, centerY: centerY, textRect: rect))

            guard let parseResult = timeParser.parseDetailed(text: text) else { continue }

            let alreadyExists = existingTimers.contains { existing in
                let dx = existing.anchorX - centerX
                let dy = existing.anchorY - centerY
                let distanceMatch = (dx * dx + dy * dy) < proximityDistanceSquared
                let textMatch = normalized == existing.originalText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let timeMatch = abs(existing.targetDate.timeIntervalSince(parseResult.targetDate)) < 60
                return distanceMatch && (textMatch || timeMatch)
            }

            guard !alreadyExists else { continue }
            let penColor = dominantStrokeColor(near: rect, in: strokes)
            newTimers.append(BoardTimer(
                originalText: text,
                targetDate: parseResult.targetDate,
                anchorX: centerX,
                anchorY: centerY,
                textRect: rect,
                isDuration: parseResult.isDuration,
                penColorHex: penColor.hexString,
                label: parseResult.label
            ))
        }

        let migratedTimers = detectMigrations(existingTimers: existingTimers, recognizedTexts: recognizedTexts, scanRect: scanRect)
        let migratedTimerIDs = Set(migratedTimers.map { $0.timerID })

        if !migratedTimerIDs.isEmpty {
            newTimers.removeAll { candidate in
                migratedTimers.contains { migrated in
                    let dx = migrated.anchorX - candidate.anchorX
                    let dy = migrated.anchorY - candidate.anchorY
                    return (dx * dx + dy * dy) < proximityDistanceSquared
                }
            }
        }

        var zombieIDs: Set<UUID> = []
        for timer in existingTimers {
            guard !migratedTimerIDs.contains(timer.id) else { continue }

            let anchor = CGPoint(x: timer.anchorX, y: timer.anchorY)
            let intersectsScanRect = scanRect.contains(anchor)
                || (!timer.textRect.isEmpty && timer.textRect.intersects(scanRect))
            guard intersectsScanRect else { continue }

            let timerText = timer.originalText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let stillPresent = recognizedTexts.contains { recognized in
                let dx = timer.anchorX - recognized.centerX
                let dy = timer.anchorY - recognized.centerY
                let closeEnough = (dx * dx + dy * dy) < proximityDistanceSquared
                let textMatch = timerText == recognized.normalizedText
                    || timerText.contains(recognized.normalizedText)
                    || recognized.normalizedText.contains(timerText)
                return closeEnough && textMatch
            }

            if !stillPresent {
                zombieIDs.insert(timer.id)
            }
        }

        return (newTimers, zombieIDs, migratedTimers)
    }

    private func detectMigrations(
        existingTimers: [BoardTimer],
        recognizedTexts: [RecognizedText],
        scanRect: CGRect
    ) -> [TimerMigration] {
        var claimedRecognizedIndices: Set<Int> = []
        var migrations: [TimerMigration] = []

        for timer in existingTimers {
            let anchor = CGPoint(x: timer.anchorX, y: timer.anchorY)
            let intersectsScanRect = scanRect.contains(anchor)
                || (!timer.textRect.isEmpty && timer.textRect.intersects(scanRect))
            guard intersectsScanRect else { continue }

            let timerText = timer.originalText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var bestMatchIndex: Int?
            var bestDistanceSquared = CGFloat.greatestFiniteMagnitude

            for (idx, recognized) in recognizedTexts.enumerated() {
                guard !claimedRecognizedIndices.contains(idx) else { continue }

                let textMatch = timerText == recognized.normalizedText
                    || timerText.contains(recognized.normalizedText)
                    || recognized.normalizedText.contains(timerText)
                guard textMatch else { continue }

                let dx = timer.anchorX - recognized.centerX
                let dy = timer.anchorY - recognized.centerY
                let distanceSquared = dx * dx + dy * dy

                // Not a migration if it still overlaps the same area.
                guard distanceSquared >= proximityDistanceSquared else { continue }

                if distanceSquared < bestDistanceSquared {
                    bestDistanceSquared = distanceSquared
                    bestMatchIndex = idx
                }
            }

            if let matchIndex = bestMatchIndex {
                let matched = recognizedTexts[matchIndex]
                migrations.append(TimerMigration(
                    timerID: timer.id,
                    anchorX: matched.centerX,
                    anchorY: matched.centerY,
                    textRect: matched.textRect
                ))
                claimedRecognizedIndices.insert(matchIndex)
            }
        }

        return migrations
    }

    private func dominantStrokeColor(near rect: CGRect, in strokes: [PKStroke]) -> UIColor {
        let expandedRect = rect.insetBy(dx: -20, dy: -20)
        var colorCounts: [String: (UIColor, Int)] = [:]

        for stroke in strokes where stroke.renderBounds.intersects(expandedRect) {
            let hex = stroke.ink.color.hexString
            if let existing = colorCounts[hex] {
                colorCounts[hex] = (existing.0, existing.1 + 1)
            } else {
                colorCounts[hex] = (stroke.ink.color, 1)
            }
        }

        return colorCounts.values.max(by: { $0.1 < $1.1 })?.0 ?? .label
    }
}
