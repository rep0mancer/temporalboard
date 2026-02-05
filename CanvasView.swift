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
        
        // Store references in coordinator
        context.coordinator.canvasView = canvasView
        context.coordinator.toolPicker = toolPicker
        
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Update drawing if data changed externally
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
        
        weak var canvasView: PKCanvasView?
        var toolPicker: PKToolPicker?
        
        // Timer display components
        var timerLabels: [UUID: TimerLabel] = [:]
        var highlightViews: [UUID: HighlightOverlayView] = [:]
        
        // Track which timers already triggered haptic feedback
        var hapticsTriggered: Set<UUID> = []
        
        init(_ parent: CanvasView) {
            self.parent = parent
            super.init()
            
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
            saveWorkItem?.cancel()
            let saveItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.parent.drawing = canvasView.drawing
                }
            }
            saveWorkItem = saveItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: saveItem)
            
            // Debounce recognition — 1.5s after the user stops drawing
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
            
            if bounds.isEmpty { return }
            
            let token = UUID()
            recognitionToken = token
            let scale = UIScreen.main.scale
            let languages = recognitionLanguages()
            let allStrokes = drawing.strokes
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                
                let image = drawing.image(from: bounds, scale: scale)
                guard let cgImage = image.cgImage else { return }
                
                let request = VNRecognizeTextRequest { [weak self] request, error in
                    guard let self = self,
                          let observations = request.results as? [VNRecognizedTextObservation],
                          self.recognitionToken == token else { return }
                    
                    DispatchQueue.main.async {
                        self.processObservations(observations, in: bounds, strokes: allStrokes)
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
        
        func processObservations(_ observations: [VNRecognizedTextObservation],
                                 in drawingBounds: CGRect,
                                 strokes: [PKStroke]) {
            var newTimers: [BoardTimer] = []
            
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                
                // Use the new parser that searches within text
                guard let parseResult = timeParser.parseDetailed(text: text) else { continue }
                
                // Convert Vision coordinates (0,0 bottom-left) -> content coordinates
                let boundingBox = observation.boundingBox
                let w = drawingBounds.width
                let h = drawingBounds.height
                let x = drawingBounds.origin.x + (boundingBox.origin.x * w)
                let y = drawingBounds.origin.y + ((1 - boundingBox.origin.y - boundingBox.height) * h)
                let rectWidth = boundingBox.width * w
                let rectHeight = boundingBox.height * h
                
                let textRect = CGRect(x: x, y: y, width: rectWidth, height: rectHeight)
                let centerX = x + rectWidth / 2
                let centerY = y + rectHeight / 2
                
                let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                
                // Avoid duplicates
                let alreadyExists = parent.timers.contains { existing in
                    let dx = existing.anchorX - centerX
                    let dy = existing.anchorY - centerY
                    let distanceMatch = (dx*dx + dy*dy) < 2500
                    let textMatch = normalizedText == existing.originalText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let timeMatch = abs(existing.targetDate.timeIntervalSince(parseResult.targetDate)) < 60
                    return distanceMatch && (textMatch || timeMatch)
                }
                
                if !alreadyExists {
                    // Determine pen color from nearby strokes
                    let penColor = dominantStrokeColor(near: textRect, in: strokes)
                    
                    let newTimer = BoardTimer(
                        originalText: text,
                        targetDate: parseResult.targetDate,
                        anchorX: centerX,
                        anchorY: centerY,
                        textRect: textRect,
                        isDuration: parseResult.isDuration,
                        penColorHex: penColor.hexString
                    )
                    newTimers.append(newTimer)
                }
            }
            
            if !newTimers.isEmpty {
                parent.onAddTimers(newTimers)
                
                // Light haptic to confirm timer was recognized
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
            }
        }
        
        /// Find the dominant ink color of strokes that overlap the given rect.
        private func dominantStrokeColor(near rect: CGRect, in strokes: [PKStroke]) -> UIColor {
            let expandedRect = rect.insetBy(dx: -20, dy: -20)
            var colorCounts: [String: (UIColor, Int)] = [:]
            
            for stroke in strokes {
                if stroke.renderBounds.intersects(expandedRect) {
                    let hex = stroke.ink.color.hexString
                    if let existing = colorCounts[hex] {
                        colorCounts[hex] = (existing.0, existing.1 + 1)
                    } else {
                        colorCounts[hex] = (stroke.ink.color, 1)
                    }
                }
            }
            
            // Return the most common color, or black as fallback
            return colorCounts.values.max(by: { $0.1 < $1.1 })?.0 ?? .black
        }
        
        // MARK: - Timer & Highlight Views Management
        
        func updateTimerViews(in canvasView: PKCanvasView, with timers: [BoardTimer]) {
            let currentIDs = Set(timers.map { $0.id })
            
            // Remove labels and highlights for timers that no longer exist
            for id in timerLabels.keys where !currentIDs.contains(id) {
                timerLabels[id]?.stopTimer()
                timerLabels[id]?.removeFromSuperview()
                timerLabels.removeValue(forKey: id)
            }
            for id in highlightViews.keys where !currentIDs.contains(id) {
                highlightViews[id]?.stopAnimating()
                highlightViews[id]?.removeFromSuperview()
                highlightViews.removeValue(forKey: id)
            }
            
            for timer in timers {
                let penColor = UIColor(hex: timer.penColorHex)
                
                // --- Timer Label ---
                let label: TimerLabel
                if let existing = timerLabels[timer.id] {
                    label = existing
                    if label.targetDate != timer.targetDate {
                        label.targetDate = timer.targetDate
                    }
                    label.updatePenColor(penColor)
                } else {
                    label = TimerLabel(timerID: timer.id, targetDate: timer.targetDate, penColor: penColor)
                    label.onExpired = { [weak self] timerID in
                        self?.handleTimerExpired(timerID: timerID)
                    }
                    label.addGestureRecognizer(UITapGestureRecognizer(
                        target: self, action: #selector(handleTimerLabelTap(_:))
                    ))
                    canvasView.addSubview(label)
                    timerLabels[timer.id] = label
                }
                
                // Position below the text
                let labelWidth: CGFloat = max(90, timer.textRect.width * 0.5)
                let contentX = timer.anchorX - labelWidth / 2
                let contentY = timer.anchorY + max(timer.textRect.height / 2, 10) + 8
                label.frame = CGRect(x: contentX, y: contentY, width: labelWidth, height: 28)
                
                // --- Highlight Overlay ---
                let isExpiredNow = timer.targetDate <= Date()
                
                if isExpiredNow && !timer.isDismissed && timer.textRect != .zero {
                    let highlight: HighlightOverlayView
                    if let existing = highlightViews[timer.id] {
                        highlight = existing
                    } else {
                        highlight = HighlightOverlayView(penColor: penColor)
                        canvasView.insertSubview(highlight, at: 0)
                        highlightViews[timer.id] = highlight
                    }
                    // Expand rect slightly for visual effect
                    let padding: CGFloat = 6
                    highlight.frame = timer.textRect.insetBy(dx: -padding, dy: -padding)
                    highlight.startAnimating()
                } else {
                    // Remove highlight if timer is not expired or dismissed
                    if let existing = highlightViews[timer.id] {
                        existing.stopAnimating()
                        existing.removeFromSuperview()
                        highlightViews.removeValue(forKey: timer.id)
                    }
                }
            }
        }
        
        // MARK: - Timer Expired Callback
        
        private func handleTimerExpired(timerID: UUID) {
            guard !hapticsTriggered.contains(timerID) else { return }
            hapticsTriggered.insert(timerID)
            
            // Strong haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
            
            // Mark expired in model
            DispatchQueue.main.async {
                if let idx = self.parent.timers.firstIndex(where: { $0.id == timerID }) {
                    self.parent.timers[idx].isExpired = true
                }
            }
        }
        
        // MARK: - Timer Interaction (Tap)
        
        @objc private func handleTimerLabelTap(_ gesture: UITapGestureRecognizer) {
            guard let label = gesture.view as? TimerLabel else { return }
            let timerID = label.timerID
            guard let timer = parent.timers.first(where: { $0.id == timerID }) else { return }
            presentTimerActionSheet(for: timer)
        }
        
        private func presentTimerActionSheet(for timer: BoardTimer) {
            let isExpired = timer.targetDate <= Date()
            
            let alert = UIAlertController(
                title: timer.originalText,
                message: isExpired ? "Timer finished!" : "Timer active",
                preferredStyle: .actionSheet
            )
            
            if isExpired {
                // Dismiss alert (stop blinking)
                alert.addAction(UIAlertAction(title: "Dismiss Alert", style: .default) { [weak self] _ in
                    self?.dismissTimerAlert(timer.id)
                })
                
                // Restart same duration
                if timer.isDuration {
                    alert.addAction(UIAlertAction(title: "Restart Timer", style: .default) { [weak self] _ in
                        self?.restartTimer(timer)
                    })
                }
                
                // Quick extend options
                for minutes in [1, 5, 10, 15] {
                    alert.addAction(UIAlertAction(title: "+\(minutes) min", style: .default) { [weak self] _ in
                        self?.extendTimer(timer.id, byMinutes: minutes)
                    })
                }
            } else {
                // Quick extend for running timers too
                for minutes in [5, 10, 15, 30] {
                    alert.addAction(UIAlertAction(title: "+\(minutes) min", style: .default) { [weak self] _ in
                        self?.extendTimer(timer.id, byMinutes: minutes)
                    })
                }
            }
            
            // Edit
            alert.addAction(UIAlertAction(title: "Edit Time...", style: .default) { [weak self] _ in
                self?.presentTimerEditAlert(for: timer)
            })
            
            // Delete
            alert.addAction(UIAlertAction(title: "Delete Timer", style: .destructive) { [weak self] _ in
                self?.deleteTimer(timer.id)
            })
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            
            // For iPad: position the popover at the timer label
            if let popover = alert.popoverPresentationController,
               let label = timerLabels[timer.id] {
                popover.sourceView = label
                popover.sourceRect = label.bounds
            }
            
            presentAlert(alert)
        }
        
        private func dismissTimerAlert(_ timerID: UUID) {
            DispatchQueue.main.async {
                if let idx = self.parent.timers.firstIndex(where: { $0.id == timerID }) {
                    self.parent.timers[idx].isDismissed = true
                }
            }
        }
        
        private func extendTimer(_ timerID: UUID, byMinutes minutes: Int) {
            DispatchQueue.main.async {
                guard let idx = self.parent.timers.firstIndex(where: { $0.id == timerID }) else { return }
                let now = Date()
                let currentTarget = self.parent.timers[idx].targetDate
                // If expired, extend from now; if active, extend from current target
                let base = currentTarget > now ? currentTarget : now
                if let newDate = Calendar.current.date(byAdding: .minute, value: minutes, to: base) {
                    self.parent.timers[idx].targetDate = newDate
                    self.parent.timers[idx].isExpired = false
                    self.parent.timers[idx].isDismissed = false
                    self.hapticsTriggered.remove(timerID)
                }
            }
        }
        
        private func restartTimer(_ timer: BoardTimer) {
            DispatchQueue.main.async {
                guard let idx = self.parent.timers.firstIndex(where: { $0.id == timer.id }) else { return }
                // Re-parse the original text to get the same duration
                if let newDate = self.timeParser.parse(text: timer.originalText) {
                    self.parent.timers[idx].targetDate = newDate
                    self.parent.timers[idx].isExpired = false
                    self.parent.timers[idx].isDismissed = false
                    self.hapticsTriggered.remove(timer.id)
                }
            }
        }
        
        private func presentTimerEditAlert(for timer: BoardTimer) {
            let alert = UIAlertController(
                title: "Edit Timer",
                message: "Enter a new time or duration (e.g. \"15 min\" or \"14:30\").",
                preferredStyle: .alert
            )
            alert.addTextField { field in
                field.text = timer.originalText
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
            }
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
                guard let self = self else { return }
                let newText = alert?.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !newText.isEmpty else {
                    self.presentValidationAlert(message: "Please enter a time value.")
                    return
                }
                guard let newDate = self.timeParser.parse(text: newText) else {
                    self.presentValidationAlert(message: "Could not parse the time. Try formats like \"15 min\" or \"14:30\".")
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
                updatedTimers[index].isDismissed = false
                self.hapticsTriggered.remove(timerID)
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

// MARK: - HighlightOverlayView
// Draws a translucent colored rectangle over the handwritten text that pulses/flashes
// when the timer expires to make the whole sentence noticeable.

class HighlightOverlayView: UIView {
    private var pulseTimer: Timer?
    private let penColor: UIColor
    
    init(penColor: UIColor) {
        self.penColor = penColor
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        layer.cornerRadius = 6
        clipsToBounds = true
        alpha = 0
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func startAnimating() {
        guard pulseTimer == nil else { return }
        
        // Use a warm highlight color derived from the pen color
        let highlightColor = penColor.withAlphaComponent(0.15)
        backgroundColor = highlightColor
        
        // Add a colored border
        layer.borderWidth = 2.0
        layer.borderColor = penColor.withAlphaComponent(0.6).cgColor
        
        // Pulse animation
        alpha = 0
        layer.removeAllAnimations()
        UIView.animate(withDuration: 0.7,
                       delay: 0,
                       options: [.autoreverse, .repeat, .allowUserInteraction, .curveEaseInOut],
                       animations: { [weak self] in
                           self?.alpha = 1.0
                       })
    }
    
    func stopAnimating() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        layer.removeAllAnimations()
        alpha = 0
    }
}

// MARK: - TimerLabel (Self-updating UILabel)

class TimerLabel: UILabel {
    let timerID: UUID
    var targetDate: Date {
        didSet {
            expiredCallbackFired = false
            updateDisplay()
            startTimerIfNeeded()
        }
    }
    
    var onExpired: ((UUID) -> Void)?
    
    private var displayTimer: Timer?
    private var isBlinking = false
    private var expiredCallbackFired = false
    private var penColor: UIColor
    
    init(timerID: UUID, targetDate: Date, penColor: UIColor = .black) {
        self.timerID = timerID
        self.targetDate = targetDate
        self.penColor = penColor
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
    
    func updatePenColor(_ color: UIColor) {
        penColor = color
        // Update border and text tint
        layer.borderColor = penColor.withAlphaComponent(0.4).cgColor
        if targetDate.timeIntervalSince(Date()) > 0 {
            textColor = penColor.withAlphaComponent(0.85)
        }
    }
    
    private func setupAppearance() {
        // Use a handwriting-style rounded font
        let size: CGFloat = 15
        if let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
            .withDesign(.rounded)?
            .withSymbolicTraits(.traitBold) {
            font = UIFont(descriptor: descriptor, size: size)
        } else {
            font = UIFont.systemFont(ofSize: size, weight: .semibold)
        }
        
        textColor = penColor.withAlphaComponent(0.85)
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        layer.cornerRadius = 6
        layer.borderWidth = 1.5
        layer.borderColor = penColor.withAlphaComponent(0.4).cgColor
        clipsToBounds = true
        textAlignment = .center
        isUserInteractionEnabled = true
        
        // Subtle shadow for depth
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 2
        layer.masksToBounds = false
        
        updateDisplay()
    }
    
    func startTimer() {
        updateDisplay()
        
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
            // Show overtime counter: how long past the deadline
            let overtime = abs(remaining)
            let prefix = "−" // minus sign
            if overtime > 3600 {
                let h = Int(overtime) / 3600
                let m = (Int(overtime) % 3600) / 60
                text = "\(prefix)\(h)h \(String(format: "%02d", m))m"
            } else {
                let m = Int(overtime) / 60
                let s = Int(overtime) % 60
                text = "\(prefix)\(String(format: "%02d:%02d", m, s))"
            }
            
            textColor = .systemRed
            layer.borderColor = UIColor.systemRed.withAlphaComponent(0.5).cgColor
            startBlinking()
            
            // Fire expired callback once
            if !expiredCallbackFired {
                expiredCallbackFired = true
                onExpired?(timerID)
            }
        } else {
            stopBlinking()
            alpha = 1.0
            textColor = penColor.withAlphaComponent(0.85)
            layer.borderColor = penColor.withAlphaComponent(0.4).cgColor
            
            if remaining > 3600 {
                let h = Int(remaining) / 3600
                let m = (Int(remaining) % 3600) / 60
                text = String(format: "%dh %02dm", h, m)
            } else {
                let m = Int(remaining) / 60
                let s = Int(remaining) % 60
                text = String(format: "%02d:%02d", m, s)
            }
            
            // Change color when close to expiry (< 60 seconds)
            if remaining < 60 {
                textColor = .systemOrange
                layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.5).cgColor
            }
        }
    }
    
    private func startTimerIfNeeded() {
        guard displayTimer == nil else { return }
        startTimer()
    }

    private func startBlinking() {
        guard !isBlinking else { return }
        isBlinking = true
        layer.removeAllAnimations()
        UIView.animate(withDuration: 0.6,
                       delay: 0,
                       options: [.autoreverse, .repeat, .allowUserInteraction],
                       animations: { [weak self] in
                           self?.alpha = 0.25
                       })
    }

    private func stopBlinking() {
        guard isBlinking else { return }
        isBlinking = false
        layer.removeAllAnimations()
        alpha = 1.0
    }
}
