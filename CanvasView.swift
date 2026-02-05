import SwiftUI
import UIKit
import PencilKit
import Vision

// MARK: - CanvasView (UIViewRepresentable)

struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var timers: [BoardTimer]
    let onAddTimers: ([BoardTimer]) -> Void
    
    func makeUIView(context: Context) -> PKCanvasView {
        // Create PKCanvasView locally - not held in ViewModel
        let canvasView = PKCanvasView()
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 10)
        canvasView.drawingPolicy = .anyInput
        canvasView.delegate = context.coordinator
        canvasView.backgroundColor = .secondarySystemBackground
        canvasView.isOpaque = true
        
        // Allow infinite scrolling
        canvasView.alwaysBounceVertical = true
        canvasView.alwaysBounceHorizontal = true
        
        // Set initial drawing from data
        canvasView.drawing = drawing
        
        // Activate tool picker
        let toolPicker = PKToolPicker()
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()
        
        // Store reference in coordinator for updates
        context.coordinator.canvasView = canvasView
        context.coordinator.toolPicker = toolPicker
        
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Update drawing if data changed externally (two-way binding)
        if uiView.drawing.dataRepresentation() != drawing.dataRepresentation() {
            uiView.drawing = drawing
        }
        
        // Update timer views based on current state
        context.coordinator.updateTimerViews(in: uiView, with: timers)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CanvasView
        var recognitionWorkItem: DispatchWorkItem?
        var saveWorkItem: DispatchWorkItem?
        var recognitionToken: UUID?
        var timeParser = TimeParser()
        
        // Weak reference to canvas view for recognition callbacks
        weak var canvasView: PKCanvasView?
        // Keep tool picker alive
        var toolPicker: PKToolPicker?
        
        // Cache for timer labels - using self-updating TimerLabel
        var timerLabels: [UUID: TimerLabel] = [:]
        
        init(_ parent: CanvasView) {
            self.parent = parent
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppWillResignActive),
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppDidEnterBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        // MARK: - PKCanvasViewDelegate
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Sync drawing back to the binding (two-way binding)
            // Use debouncing to avoid excessive updates
            saveWorkItem?.cancel()
            let saveItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Update binding on main thread
                DispatchQueue.main.async {
                    self.parent.drawing = canvasView.drawing
                }
            }
            saveWorkItem = saveItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: saveItem)
            
            // Debounce recognition
            recognitionWorkItem?.cancel()
            let recognitionItem = DispatchWorkItem { [weak self] in
                self?.performRecognition(on: canvasView)
            }
            recognitionWorkItem = recognitionItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: recognitionItem)
        }

        @objc private func handleAppWillResignActive() {
            flushPendingDrawingUpdate()
        }

        @objc private func handleAppDidEnterBackground() {
            flushPendingDrawingUpdate()
        }

        private func flushPendingDrawingUpdate() {
            saveWorkItem?.cancel()
            guard let canvasView = canvasView else { return }
            if Thread.isMainThread {
                parent.drawing = canvasView.drawing
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let canvasView = self.canvasView else { return }
                    self.parent.drawing = canvasView.drawing
                }
            }
        }
        
        // MARK: - Text Recognition
        
        func performRecognition(on canvasView: PKCanvasView) {
            let drawing = canvasView.drawing
            let bounds = drawing.bounds
            
            // Skip if empty
            if bounds.isEmpty { return }
            
            let token = UUID()
            recognitionToken = token
            let scale = UIScreen.main.scale
            let languages = recognitionLanguages()
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                
                // Generate image off the main thread
                let image = drawing.image(from: bounds, scale: scale)
                guard let cgImage = image.cgImage else { return }
                
                let request = VNRecognizeTextRequest { [weak self] request, error in
                    guard let self = self,
                          let observations = request.results as? [VNRecognizedTextObservation],
                          self.recognitionToken == token else { return }
                    
                    DispatchQueue.main.async {
                        self.processObservations(observations, in: bounds)
                    }
                }
                
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                request.recognitionLanguages = languages
                
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
            let fallbacks = ["en-US", "de-DE"]
            for fallback in fallbacks where !languages.contains(fallback) {
                languages.append(fallback)
            }
            return Array(languages.prefix(3))
        }
        
        func processObservations(_ observations: [VNRecognizedTextObservation], in drawingBounds: CGRect) {
            var newTimers: [BoardTimer] = []
            
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                
                // Check if it's a time
                if let targetDate = timeParser.parse(text: text) {
                    // Convert Vision coordinates (0,0 bottom-left) -> UIKit (0,0 top-left)
                    let boundingBox = observation.boundingBox
                    
                    let w = drawingBounds.width
                    let h = drawingBounds.height
                    let x = drawingBounds.origin.x + (boundingBox.origin.x * w)
                    let y = drawingBounds.origin.y + ((1 - boundingBox.origin.y - boundingBox.height) * h)
                    
                    let centerX = x + (boundingBox.width * w) / 2
                    let centerY = y + (boundingBox.height * h) / 2
                    
                    // Avoid duplicates: check if timer already exists nearby
                    let alreadyExists = parent.timers.contains { existing in
                        let dx = existing.anchorX - centerX
                        let dy = existing.anchorY - centerY
                        let distanceMatch = (dx*dx + dy*dy) < 2500 // 50pt threshold
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
                parent.onAddTimers(newTimers)
            }
        }
        
        // MARK: - Timer Views Management
        
        func updateTimerViews(in canvasView: PKCanvasView, with timers: [BoardTimer]) {
            // 1. Remove labels for timers that no longer exist
            let currentIDs = Set(timers.map { $0.id })
            let idsToRemove = timerLabels.keys.filter { !currentIDs.contains($0) }
            for id in idsToRemove {
                guard let label = timerLabels[id] else { continue }
                label.stopTimer()
                label.removeFromSuperview()
                timerLabels.removeValue(forKey: id)
            }
            
            // 2. Create or update labels for existing timers
            for timer in timers {
                let label: TimerLabel
                if let existing = timerLabels[timer.id] {
                    label = existing
                    // Update target date if changed
                    if label.targetDate != timer.targetDate {
                        label.targetDate = timer.targetDate
                    }
                } else {
                    // Create new self-updating timer label
                    label = TimerLabel(timerID: timer.id, targetDate: timer.targetDate)
                    label.frame.size = CGSize(width: 80, height: 24)
                    label.addGestureRecognizer(UITapGestureRecognizer(
                        target: self,
                        action: #selector(handleTimerLabelTap(_:))
                    ))
                    
                    // Position at content coordinates - let PKCanvasView handle scrolling
                    // Add as subview to canvasView so it scrolls with content
                    canvasView.addSubview(label)
                    timerLabels[timer.id] = label
                }
                
                // Set position in content coordinates (not screen coordinates)
                // Place slightly below the recognized text
                let contentX = timer.anchorX - 40 // Center the 80pt wide label
                let contentY = timer.anchorY + 30 // Below the text
                label.frame.origin = CGPoint(x: contentX, y: contentY)
            }
        }
        
        // MARK: - Timer Editing
        
        @objc private func handleTimerLabelTap(_ gesture: UITapGestureRecognizer) {
            guard let label = gesture.view as? TimerLabel else { return }
            let timerID = label.timerID
            guard let timer = parent.timers.first(where: { $0.id == timerID }) else { return }
            presentTimerEditAlert(for: timer)
        }
        
        private func presentTimerEditAlert(for timer: BoardTimer) {
            let alert = UIAlertController(
                title: "Edit Timer",
                message: "Enter a new time.",
                preferredStyle: .alert
            )
            alert.addTextField { field in
                field.text = timer.originalText
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
            }
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                self?.deleteTimer(timer.id)
            })
            alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
                guard let self = self else { return }
                let newText = alert?.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !newText.isEmpty else {
                    self.presentValidationAlert(message: "Enter a time.")
                    return
                }
                guard let newDate = self.timeParser.parse(text: newText) else {
                    self.presentValidationAlert(message: "Could not parse time.")
                    return
                }
                self.updateTimer(timerID: timer.id, newText: newText, newDate: newDate)
            })
            
            presentAlert(alert)
        }
        
        private func updateTimer(timerID: UUID, newText: String, newDate: Date) {
            DispatchQueue.main.async {
                var updatedTimers = self.parent.timers
                guard let index = updatedTimers.firstIndex(where: { $0.id == timerID }) else { return }
                updatedTimers[index].originalText = newText
                updatedTimers[index].targetDate = newDate
                updatedTimers[index].isExpired = newDate <= Date()
                self.parent.timers = updatedTimers
            }
        }
        
        private func deleteTimer(_ timerID: UUID) {
            DispatchQueue.main.async {
                self.parent.timers.removeAll { $0.id == timerID }
            }
        }
        
        private func presentValidationAlert(message: String) {
            let alert = UIAlertController(title: "Invalid Time", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presentAlert(alert)
        }
        
        private func presentAlert(_ alert: UIAlertController) {
            guard let presenter = topViewController() else { return }
            presenter.present(alert, animated: true)
        }
        
        private func topViewController() -> UIViewController? {
            if let root = canvasView?.window?.rootViewController {
                return topViewController(from: root)
            }
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                return topViewController(from: root)
            }
            return nil
        }
        
        private func topViewController(from base: UIViewController?) -> UIViewController? {
            if let nav = base as? UINavigationController {
                return topViewController(from: nav.visibleViewController)
            }
            if let tab = base as? UITabBarController {
                return topViewController(from: tab.selectedViewController)
            }
            if let presented = base?.presentedViewController {
                return topViewController(from: presented)
            }
            return base
        }
    }
}

// MARK: - TimerLabel (Self-updating UILabel)
// This label manages its own timer to update the countdown display,
// preventing the need for a global timer that redraws the entire view hierarchy.

class TimerLabel: UILabel {
    let timerID: UUID
    var targetDate: Date {
        didSet {
            updateDisplay()
            startTimerIfNeeded()
        }
    }
    
    private var displayTimer: Timer?
    private var isBlinking = false
    
    init(timerID: UUID, targetDate: Date) {
        self.timerID = timerID
        self.targetDate = targetDate
        super.init(frame: .zero)
        setupAppearance()
        startTimer()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        stopTimer()
    }
    
    private func setupAppearance() {
        font = UIFont.systemFont(ofSize: 14, weight: .medium)
        if let roundedDescriptor = font.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: roundedDescriptor, size: 14)
        }
        textColor = .systemBlue
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
        layer.cornerRadius = 4
        clipsToBounds = true
        textAlignment = .center
        isUserInteractionEnabled = true
        
        updateDisplay()
    }
    
    func startTimer() {
        // Update display immediately
        updateDisplay()
        
        // Create timer that fires every second to update this label only
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateDisplay()
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }
    
    func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }
    
    private func updateDisplay() {
        let now = Date()
        let remaining = targetDate.timeIntervalSince(now)
        
        if remaining <= 0 {
            text = "Done"
            alpha = 1.0
            textColor = .gray
            startBlinking()
            // Stop the timer when expired
            stopTimer()
        } else {
            stopBlinking()
            alpha = 1.0
            textColor = .systemBlue
            
            if remaining > 3600 {
                let h = Int(remaining) / 3600
                let m = (Int(remaining) % 3600) / 60
                text = String(format: "%dh %02dm", h, m)
            } else {
                let m = Int(remaining) / 60
                let s = Int(remaining) % 60
                text = String(format: "%02d:%02d", m, s)
            }
        }
    }
    
    private func startTimerIfNeeded() {
        guard displayTimer == nil else { return }
        if targetDate.timeIntervalSince(Date()) > 0 {
            startTimer()
        }
    }

    private func startBlinking() {
        guard !isBlinking else { return }
        isBlinking = true
        layer.removeAllAnimations()
        UIView.animate(withDuration: 0.8,
                       delay: 0,
                       options: [.autoreverse, .repeat, .allowUserInteraction],
                       animations: { [weak self] in
                           self?.alpha = 0.3
                       })
    }

    private func stopBlinking() {
        guard isBlinking else { return }
        isBlinking = false
        layer.removeAllAnimations()
        alpha = 1.0
    }
}
