import SwiftUI
import UIKit
import PencilKit
import Vision
import AudioToolbox
import AVFoundation
import Combine

// MARK: - CanvasView (UIViewRepresentable)

struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var timers: [BoardTimer]
    let onAddTimers: ([BoardTimer]) -> Void
    let heartbeat: AnyPublisher<Date, Never>
    
    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.tool = PKInkingTool(.pen, color: .label, width: 3)
        canvasView.drawingPolicy = .anyInput
        canvasView.delegate = context.coordinator
        canvasView.isOpaque = true
        
        // Freeform-style background: light warm white with dot grid
        let bgView = DotGridBackgroundView()
        bgView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.insertSubview(bgView, at: 0)
        canvasView.backgroundColor = .clear
        
        // Allow infinite scrolling like Freeform
        canvasView.alwaysBounceVertical = true
        canvasView.alwaysBounceHorizontal = true
        canvasView.minimumZoomScale = 0.25
        canvasView.maximumZoomScale = 4.0
        canvasView.contentSize = CGSize(width: 5000, height: 5000)
        
        // Set initial drawing
        canvasView.drawing = drawing
        
        // Tool picker — Apple Freeform style
        let toolPicker = PKToolPicker()
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()
        
        // Store references in coordinator
        context.coordinator.canvasView = canvasView
        context.coordinator.toolPicker = toolPicker
        context.coordinator.backgroundView = bgView
        
        // Subscribe the coordinator to the single centralized heartbeat.
        // This replaces individual per-label Timers for energy efficiency.
        context.coordinator.heartbeatCancellable = heartbeat
            .sink { [weak coordinator = context.coordinator] _ in
                coordinator?.tickAllLabels()
            }
        
        // Canvas-level tap gesture for timer interaction.
        // Labels are non-interactive (isUserInteractionEnabled = false) so we
        // hit-test manually against their frames in the Coordinator.
        let canvasTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleCanvasTap(_:))
        )
        canvasTap.delegate = context.coordinator
        canvasView.addGestureRecognizer(canvasTap)
        
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // CanvasView is a value type — SwiftUI recreates it on every state change.
        // The Coordinator persists across those recreations, so its `parent`
        // reference must be refreshed here to avoid reading stale bindings.
        context.coordinator.parent = self
        
        // Avoid expensive full-data serialization comparison on every SwiftUI update.
        // Use lightweight heuristics (stroke count + bounds) to detect actual changes.
        let currentStrokes = uiView.drawing.strokes.count
        let newStrokes = drawing.strokes.count
        let boundsChanged = uiView.drawing.bounds != drawing.bounds
        if currentStrokes != newStrokes || boundsChanged {
            uiView.drawing = drawing
        }
        context.coordinator.updateTimerViews(in: uiView, with: timers)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var parent: CanvasView
        var recognitionWorkItem: DispatchWorkItem?
        var saveWorkItem: DispatchWorkItem?
        var recognitionToken: UUID?
        var timeParser = TimeParser()
        
        weak var canvasView: PKCanvasView?
        var toolPicker: PKToolPicker?
        weak var backgroundView: DotGridBackgroundView?
        
        // Timer display components
        var timerLabels: [UUID: TimerLabel] = [:]
        var highlightViews: [UUID: HighlightOverlayView] = [:]
        
        // Centralized heartbeat subscription (replaces per-label Timers)
        var heartbeatCancellable: AnyCancellable?
        
        // Track which timers already triggered haptic & audio feedback
        var hapticsTriggered: Set<UUID> = []
        
        // Audio player for alert sound
        private var audioPlayer: AVAudioPlayer?
        
        /// System sound ID for the tri-tone alert (avoids magic number).
        private let triToneSoundID: SystemSoundID = 1007
        
        /// Pre-prepared haptic generators for responsive feedback.
        private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
        private let heavyImpactGenerator = UIImpactFeedbackGenerator(style: .heavy)
        private let notificationGenerator = UINotificationFeedbackGenerator()
        
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
            
            // Configure audio session
            try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            
            // Pre-warm haptic engines so feedback is immediate when triggered.
            lightImpactGenerator.prepare()
            heavyImpactGenerator.prepare()
            notificationGenerator.prepare()
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        // MARK: - PKCanvasViewDelegate
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Debounced save
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
            // Use the canvas view's own trait collection scale instead of deprecated UIScreen.main.scale
            let scale = canvasView.traitCollection.displayScale > 0 ? canvasView.traitCollection.displayScale : 2.0
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
                
                // Subtle haptic to confirm recognition (uses pre-warmed generator)
                lightImpactGenerator.impactOccurred()
                lightImpactGenerator.prepare() // Re-arm for next use
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
            
            return colorCounts.values.max(by: { $0.1 < $1.1 })?.0 ?? .label
        }
        
        // MARK: - Timer & Highlight Views Management
        
        func updateTimerViews(in canvasView: PKCanvasView, with timers: [BoardTimer]) {
            let currentIDs = Set(timers.map { $0.id })
            
            // Remove views for deleted timers
            for id in timerLabels.keys where !currentIDs.contains(id) {
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
                    canvasView.addSubview(label)
                    timerLabels[timer.id] = label
                    
                    // Entrance animation — fade in + slight scale
                    label.alpha = 0
                    label.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
                        label.alpha = 1
                        label.transform = .identity
                    }
                }
                
                // Center the label directly over the handwriting to mask/replace it.
                // The frame must fully cover the original textRect bounding box.
                if timer.textRect != .zero {
                    let padding: CGFloat = 4
                    let labelWidth  = max(timer.textRect.width  + padding * 2, 80)
                    let labelHeight = max(timer.textRect.height + padding * 2, 30)
                    label.frame = CGRect(
                        x: timer.textRect.midX - labelWidth  / 2,
                        y: timer.textRect.midY - labelHeight / 2,
                        width:  labelWidth,
                        height: labelHeight
                    )
                } else {
                    // Fallback when textRect is unavailable — center on anchor point
                    let labelWidth: CGFloat = 100
                    let labelHeight: CGFloat = 30
                    label.frame = CGRect(
                        x: timer.anchorX - labelWidth  / 2,
                        y: timer.anchorY - labelHeight / 2,
                        width:  labelWidth,
                        height: labelHeight
                    )
                }
                
                // --- Highlight Overlay ---
                let isExpiredNow = timer.targetDate <= Date()
                
                if isExpiredNow && !timer.isDismissed && timer.textRect != .zero {
                    let highlight: HighlightOverlayView
                    if let existing = highlightViews[timer.id] {
                        highlight = existing
                        highlight.updatePenColor(penColor)
                    } else {
                        highlight = HighlightOverlayView(penColor: penColor)
                        canvasView.insertSubview(highlight, at: 0)
                        highlightViews[timer.id] = highlight
                    }
                    let padding: CGFloat = 8
                    highlight.frame = timer.textRect.insetBy(dx: -padding, dy: -padding)
                    highlight.startAnimating()
                } else {
                    if let existing = highlightViews[timer.id] {
                        existing.stopAnimating()
                        existing.removeFromSuperview()
                        highlightViews.removeValue(forKey: timer.id)
                    }
                }
            }
        }
        
        // MARK: - Heartbeat Tick (Centralized)
        
        /// Called once per second by the single shared heartbeat.
        /// Iterates all live timer labels and refreshes their countdown display.
        func tickAllLabels() {
            for label in timerLabels.values {
                label.updateDisplay()
            }
        }
        
        // MARK: - Timer Expired Callback
        
        private func handleTimerExpired(timerID: UUID) {
            guard !hapticsTriggered.contains(timerID) else { return }
            hapticsTriggered.insert(timerID)
            
            // Strong haptic pattern: warning + impact (uses pre-warmed generators)
            notificationGenerator.notificationOccurred(.warning)
            notificationGenerator.prepare() // Re-arm for next use
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.heavyImpactGenerator.impactOccurred()
                self?.heavyImpactGenerator.prepare()
            }
            
            // Play system alert sound
            AudioServicesPlaySystemSound(triToneSoundID)
            
            // Mark expired in model
            DispatchQueue.main.async {
                if let idx = self.parent.timers.firstIndex(where: { $0.id == timerID }) {
                    self.parent.timers[idx].isExpired = true
                }
            }
        }
        
        // MARK: - Timer Interaction (Canvas-level Tap)
        
        /// Hit-test the tap location against all timer label frames.
        /// Since labels have isUserInteractionEnabled = false, we handle
        /// interaction at the canvas level instead.
        @objc func handleCanvasTap(_ gesture: UITapGestureRecognizer) {
            guard let canvasView = canvasView else { return }
            let tapLocation = gesture.location(in: canvasView)
            
            for (timerID, label) in timerLabels {
                if label.frame.contains(tapLocation) {
                    guard let timer = parent.timers.first(where: { $0.id == timerID }) else { continue }
                    presentTimerActionSheet(for: timer)
                    return
                }
            }
        }
        
        // MARK: - UIGestureRecognizerDelegate
        
        /// Allow the canvas tap to coexist with PencilKit's own gesture
        /// recognizers so drawing and scrolling are never blocked.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            return true
        }
        
        private func presentTimerActionSheet(for timer: BoardTimer) {
            let isExpired = timer.targetDate <= Date()
            
            let alert = UIAlertController(
                title: timer.originalText,
                message: isExpired ? "Timer finished!" : "Timer is running",
                preferredStyle: .actionSheet
            )
            
            if isExpired {
                alert.addAction(UIAlertAction(title: "Dismiss Alert", style: .default) { [weak self] _ in
                    self?.dismissTimerAlert(timer.id)
                })
                
                if timer.isDuration {
                    alert.addAction(UIAlertAction(title: "Restart Timer", style: .default) { [weak self] _ in
                        self?.restartTimer(timer)
                    })
                }
                
                for minutes in [1, 5, 10, 15] {
                    alert.addAction(UIAlertAction(title: "+\(minutes) min", style: .default) { [weak self] _ in
                        self?.extendTimer(timer.id, byMinutes: minutes)
                    })
                }
            } else {
                for minutes in [5, 10, 15, 30] {
                    alert.addAction(UIAlertAction(title: "+\(minutes) min", style: .default) { [weak self] _ in
                        self?.extendTimer(timer.id, byMinutes: minutes)
                    })
                }
            }
            
            alert.addAction(UIAlertAction(title: "Edit Time...", style: .default) { [weak self] _ in
                self?.presentTimerEditAlert(for: timer)
            })
            
            alert.addAction(UIAlertAction(title: "Delete Timer", style: .destructive) { [weak self] _ in
                self?.deleteTimer(timer.id)
            })
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            
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
                message: "Enter a new time or duration\ne.g. \"15 min\", \"2:30 PM\", \"14:30\"",
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
                    self.presentValidationAlert(message: "Could not parse. Try \"15 min\", \"3pm\", or \"14:30\".")
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

// MARK: - Dot Grid Background (Freeform-inspired)

class DotGridBackgroundView: UIView {
    
    private let dotSpacing: CGFloat = 26
    private let dotRadius: CGFloat = 1.2
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            setNeedsDisplay()
        }
    }
    
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        
        // Background fill — warm white matching Freeform
        let bgColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
                : UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1.0)
        }
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(rect)
        
        // Dot color
        let dotColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.08)
                : UIColor(white: 0.0, alpha: 0.08)
        }
        ctx.setFillColor(dotColor.cgColor)
        
        let startX = floor(rect.minX / dotSpacing) * dotSpacing
        let startY = floor(rect.minY / dotSpacing) * dotSpacing
        
        var x = startX
        while x <= rect.maxX {
            var y = startY
            while y <= rect.maxY {
                let dotRect = CGRect(x: x - dotRadius, y: y - dotRadius,
                                     width: dotRadius * 2, height: dotRadius * 2)
                ctx.fillEllipse(in: dotRect)
                y += dotSpacing
            }
            x += dotSpacing
        }
    }
}

// MARK: - HighlightOverlayView
// Dramatic pulsing glow effect when a timer expires — covers the handwritten sentence.

class HighlightOverlayView: UIView {
    
    private var isAnimating = false
    private var penColor: UIColor
    private let glowLayer = CAGradientLayer()
    
    init(penColor: UIColor) {
        self.penColor = penColor
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        layer.cornerRadius = 8
        clipsToBounds = false
        alpha = 0
        
        setupGlow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updatePenColor(_ color: UIColor) {
        penColor = color
        setupGlow()
    }
    
    private func setupGlow() {
        glowLayer.removeFromSuperlayer()
        
        // Soft radial-style glow using a gradient layer
        glowLayer.colors = [
            penColor.withAlphaComponent(0.0).cgColor,
            penColor.withAlphaComponent(0.08).cgColor,
            penColor.withAlphaComponent(0.18).cgColor,
            penColor.withAlphaComponent(0.08).cgColor,
            penColor.withAlphaComponent(0.0).cgColor
        ]
        glowLayer.locations = [0, 0.15, 0.5, 0.85, 1.0]
        glowLayer.startPoint = CGPoint(x: 0, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1, y: 0.5)
        glowLayer.cornerRadius = 8
        layer.insertSublayer(glowLayer, at: 0)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // Expand glow beyond bounds
        let inset: CGFloat = -12
        glowLayer.frame = bounds.insetBy(dx: inset, dy: inset)
    }
    
    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        
        // Add a colored border that pulses
        layer.borderWidth = 2.5
        layer.borderColor = penColor.withAlphaComponent(0.5).cgColor
        
        // Background highlight
        backgroundColor = penColor.withAlphaComponent(0.06)
        
        // Dramatic pulse: opacity oscillation + subtle scale bounce
        layer.removeAllAnimations()
        alpha = 0
        
        // Opacity pulse
        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0.3
        opacityAnim.toValue = 1.0
        opacityAnim.duration = 0.8
        opacityAnim.autoreverses = true
        opacityAnim.repeatCount = .infinity
        opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(opacityAnim, forKey: "pulse")
        
        // Subtle scale bounce
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 1.02
        scaleAnim.duration = 0.8
        scaleAnim.autoreverses = true
        scaleAnim.repeatCount = .infinity
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(scaleAnim, forKey: "breathe")
        
        // Border color flash
        let borderAnim = CABasicAnimation(keyPath: "borderColor")
        borderAnim.fromValue = penColor.withAlphaComponent(0.3).cgColor
        borderAnim.toValue = penColor.withAlphaComponent(0.8).cgColor
        borderAnim.duration = 0.8
        borderAnim.autoreverses = true
        borderAnim.repeatCount = .infinity
        borderAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(borderAnim, forKey: "borderFlash")
        
        alpha = 1.0
    }
    
    func stopAnimating() {
        isAnimating = false
        layer.removeAllAnimations()
        alpha = 0
        layer.borderWidth = 0
        backgroundColor = .clear
    }
}

// MARK: - TimerLabel (Self-updating countdown badge)

class TimerLabel: UILabel {
    let timerID: UUID
    var targetDate: Date {
        didSet {
            expiredCallbackFired = false
            updateDisplay()
        }
    }
    
    var onExpired: ((UUID) -> Void)?
    
    private var isBlinking = false
    private var expiredCallbackFired = false
    private var penColor: UIColor
    
    /// Canvas background color used to mask the handwriting underneath.
    private static let canvasBackgroundColor: UIColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
            : UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1.0)
    }
    
    init(timerID: UUID, targetDate: Date, penColor: UIColor = .label) {
        self.timerID = timerID
        self.targetDate = targetDate
        self.penColor = penColor
        super.init(frame: .zero)
        // CRITICAL: Never block Pencil or Eraser tools.
        self.isUserInteractionEnabled = false
        setupAppearance()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updatePenColor(_ color: UIColor) {
        penColor = color
        // Refresh text color to match the new pen color (unless in expired/urgent state).
        let remaining = targetDate.timeIntervalSince(Date())
        if remaining > 300 {
            textColor = penColor
        }
    }
    
    private func setupAppearance() {
        // Handwriting-style font to blend with the canvas aesthetic
        font = UIFont(name: "Noteworthy-Bold", size: 20)
            ?? .systemFont(ofSize: 20, weight: .bold)
        
        // Match pen color so the countdown reads like the user's own writing
        textColor = penColor
        
        // Canvas-matching background masks the ink underneath
        backgroundColor = Self.canvasBackgroundColor
        
        layer.cornerRadius = 4
        layer.borderWidth = 0
        textAlignment = .center
        clipsToBounds = true
        
        // No shadow or border — the label should look like replaced handwriting
        layer.shadowOpacity = 0
        
        updateDisplay()
    }
    
    /// Refresh the countdown text and styling.
    /// Called every second by the Coordinator's centralized heartbeat — no per-label Timer needed.
    func updateDisplay() {
        let now = Date()
        let remaining = targetDate.timeIntervalSince(now)
        
        // Background always matches the canvas to mask the handwriting underneath.
        backgroundColor = Self.canvasBackgroundColor
        
        if remaining <= 0 {
            // Overtime display
            let overtime = abs(remaining)
            let prefix = "−"
            if overtime > 3600 {
                let h = Int(overtime) / 3600
                let m = (Int(overtime) % 3600) / 60
                text = " \(prefix)\(h)h \(String(format: "%02d", m))m "
            } else {
                let m = Int(overtime) / 60
                let s = Int(overtime) % 60
                text = " \(prefix)\(String(format: "%02d:%02d", m, s)) "
            }
            
            textColor = .systemRed
            startBlinking()
            
            if !expiredCallbackFired {
                expiredCallbackFired = true
                onExpired?(timerID)
            }
        } else {
            stopBlinking()
            alpha = 1.0
            
            if remaining > 3600 {
                let h = Int(remaining) / 3600
                let m = (Int(remaining) % 3600) / 60
                text = " \(String(format: "%dh %02dm", h, m)) "
            } else {
                let m = Int(remaining) / 60
                let s = Int(remaining) % 60
                text = " \(String(format: "%02d:%02d", m, s)) "
            }
            
            // Text color transitions based on urgency
            if remaining < 30 {
                textColor = .systemRed
            } else if remaining < 60 {
                textColor = .systemOrange
            } else if remaining < 300 {
                textColor = .systemYellow.blended(with: .systemOrange)
            } else {
                textColor = penColor
            }
        }
    }
    
    private func startBlinking() {
        guard !isBlinking else { return }
        isBlinking = true
        layer.removeAllAnimations()
        UIView.animate(withDuration: 0.5,
                       delay: 0,
                       options: [.autoreverse, .repeat, .allowUserInteraction, .curveEaseInOut],
                       animations: { [weak self] in
                           self?.alpha = 0.2
                       })
    }
    
    private func stopBlinking() {
        guard isBlinking else { return }
        isBlinking = false
        layer.removeAllAnimations()
        alpha = 1.0
    }
}

// MARK: - UIColor Blending Helper

extension UIColor {
    func blended(with other: UIColor, ratio: CGFloat = 0.5) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        
        let r = r1 * (1 - ratio) + r2 * ratio
        let g = g1 * (1 - ratio) + g2 * ratio
        let b = b1 * (1 - ratio) + b2 * ratio
        let a = a1 * (1 - ratio) + a2 * ratio
        
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}
