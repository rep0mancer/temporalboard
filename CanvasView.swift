import SwiftUI
import PencilKit
import Vision

struct CanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var timers: [BoardTimer]
    let onUpdateTimers: ([BoardTimer]) -> Void
    let onSaveDrawing: () -> Void
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 10)
        canvasView.drawingPolicy = .anyInput
        canvasView.delegate = context.coordinator
        canvasView.backgroundColor = .secondarySystemBackground
        canvasView.isOpaque = true
        
        // Unendliches Scrollen erlauben
        canvasView.alwaysBounceVertical = true
        canvasView.alwaysBounceHorizontal = true
        
        // Toolpicker aktivieren
        let toolPicker = PKToolPicker()
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()
        
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Hier aktualisieren wir die visuellen Timer-Labels basierend auf dem State
        context.coordinator.updateTimerViews(in: uiView, with: timers)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        var parent: CanvasView
        var recognitionWorkItem: DispatchWorkItem?
        var saveWorkItem: DispatchWorkItem?
        var recognitionToken: UUID?
        var timeParser = TimeParser()
        
        // Cache für die Timer-Views (UIView), damit wir sie nicht ständig neu erstellen
        var timerViews: [UUID: UILabel] = [:]
        
        init(_ parent: CanvasView) {
            self.parent = parent
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Debounce: Bestehenden Task abbrechen, neuen planen
            recognitionWorkItem?.cancel()
            
            let item = DispatchWorkItem { [weak self] in
                self?.performRecognition(on: canvasView)
            }
            recognitionWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
            
            // Speichern separat debounced
            saveWorkItem?.cancel()
            let saveItem = DispatchWorkItem { [weak self] in
                self?.parent.onSaveDrawing()
            }
            saveWorkItem = saveItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: saveItem)
        }
        
        func performRecognition(on canvasView: PKCanvasView) {
            // Gesamte Zeichnung als Bild holen
            let drawing = canvasView.drawing
            let bounds = drawing.bounds
            
            // Performance-Check: Wenn leer, nichts tun
            if bounds.isEmpty { return }
            
            // Bild generieren
            let image = drawing.image(from: bounds, scale: 1.0)
            guard let cgImage = image.cgImage else { return }
            
            let token = UUID()
            recognitionToken = token
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                
                let request = VNRecognizeTextRequest { [weak self] request, error in
                    guard let self = self,
                          let observations = request.results as? [VNRecognizedTextObservation],
                          self.recognitionToken == token else { return }
                    
                    DispatchQueue.main.async {
                        self.processObservations(observations, in: bounds, canvasView: canvasView)
                    }
                }
                
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["de-DE", "en-US"] // Deutsch priorisieren
                
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
            }
        }
        
        func processObservations(_ observations: [VNRecognizedTextObservation], in drawingBounds: CGRect, canvasView: PKCanvasView) {
            var newTimers: [BoardTimer] = []
            
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                
                // Prüfen, ob es eine Zeit ist
                if let targetDate = timeParser.parse(text: text) {
                    
                    // Koordinaten umrechnen: Vision (0,0 unten-links) -> UIKit (0,0 oben-links)
                    // Vision Coordinates sind normalisiert (0 bis 1) relativ zum Bildrechteck (drawingBounds)
                    let boundingBox = observation.boundingBox
                    
                    // Umrechnung in Canvas-Content-Koordinaten
                    let w = drawingBounds.width
                    let h = drawingBounds.height
                    let x = drawingBounds.origin.x + (boundingBox.origin.x * w)
                    // Vision Y ist von unten, UIKit Y ist von oben
                    let y = drawingBounds.origin.y + ((1 - boundingBox.origin.y - boundingBox.height) * h)
                    
                    let centerX = x + (boundingBox.width * w) / 2
                    let centerY = y + (boundingBox.height * h) / 2
                    
                    // Duplikate vermeiden: Gibt es schon einen Timer in der Nähe (< 50pt)?
                    let alreadyExists = parent.timers.contains { existing in
                        let dx = existing.anchorX - centerX
                        let dy = existing.anchorY - centerY
                        let distanceMatch = (dx*dx + dy*dy) < 2500 // 50^2
                        let textMatch = normalizedText == existing.originalText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let timeMatch = abs(existing.targetDate.timeIntervalSince(targetDate)) < 60
                        return distanceMatch && (textMatch || timeMatch)
                    }
                    
                    if !alreadyExists {
                        let newTimer = BoardTimer(
                            originalText: text,
                            targetDate: targetDate,
                            anchorX: centerX,
                            anchorY: centerY
                        )
                        newTimers.append(newTimer)
                    }
                }
            }
            
            if !newTimers.isEmpty {
                // Timer hinzufügen
                var updatedTimers = parent.timers
                updatedTimers.append(contentsOf: newTimers)
                parent.timers = updatedTimers
                parent.onUpdateTimers(updatedTimers)
            }
        }
        
        // Rendert die Timer als UIViews direkt auf den Canvas
        func updateTimerViews(in canvasView: PKCanvasView, with timers: [BoardTimer]) {
            // 1. Alte Views entfernen, die nicht mehr in der Liste sind
            let currentIDs = Set(timers.map { $0.id })
            for (id, label) in timerViews {
                if !currentIDs.contains(id) {
                    label.removeFromSuperview()
                    timerViews.removeValue(forKey: id)
                }
            }
            
            // 2. Neue Views erstellen oder bestehende updaten
            for timer in timers {
                let label: UILabel
                if let existing = timerViews[timer.id] {
                    label = existing
                } else {
                    label = UILabel()
                    label.font = UIFont.systemFont(ofSize: 14, weight: .medium) // Handschrift-Stil wäre "Noteworthy", aber System requested
                    label.font = UIFont(descriptor: label.font.fontDescriptor.withDesign(.rounded) ?? label.font.fontDescriptor, size: 14)
                    label.textColor = .systemBlue
                    label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
                    label.layer.cornerRadius = 4
                    label.clipsToBounds = true
                    label.textAlignment = .center
                    label.isUserInteractionEnabled = false // Events sollen durchgehen zum Canvas
                    canvasView.addSubview(label) // Direkt in den Scrollable Content adden
                    timerViews[timer.id] = label
                }
                
                // Position setzen
                label.frame.size = CGSize(width: 80, height: 24)
                let contentPoint = CGPoint(x: timer.anchorX, y: timer.anchorY + 30) // Etwas unter den Text schieben
                let viewPoint = convertContentPoint(contentPoint, in: canvasView)
                label.center = viewPoint
                
                // Text berechnen
                let now = Date()
                let remaining = timer.targetDate.timeIntervalSince(now)
                
                if remaining <= 0 {
                    label.text = "Done"
                    label.alpha = 0.5
                    label.textColor = .gray
                } else {
                    label.alpha = 1.0
                    if remaining > 3600 {
                        let h = Int(remaining) / 3600
                        let m = (Int(remaining) % 3600) / 60
                        label.text = String(format: "%dh %02dm", h, m)
                    } else {
                        let m = Int(remaining) / 60
                        let s = Int(remaining) % 60
                        label.text = String(format: "%02d:%02d", m, s)
                    }
                }
            }
        }
        
        private func convertContentPoint(_ point: CGPoint, in canvasView: PKCanvasView) -> CGPoint {
            let zoomScale = canvasView.zoomScale
            let offset = canvasView.contentOffset
            return CGPoint(
                x: (point.x - offset.x) * zoomScale,
                y: (point.y - offset.y) * zoomScale
            )
        }
        
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let canvasView = scrollView as? PKCanvasView else { return }
            updateTimerViews(in: canvasView, with: parent.timers)
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let canvasView = scrollView as? PKCanvasView else { return }
            updateTimerViews(in: canvasView, with: parent.timers)
        }
    }
}
