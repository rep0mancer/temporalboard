import SwiftUI
import UIKit
import PencilKit

// MARK: - CanvasView (UIViewRepresentable)

struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var timers: [BoardTimer]
    let onAddTimers: ([BoardTimer]) -> Void
    /// Version token from the ViewModel — changes whenever `drawing` is set.
    var drawingVersion: UUID

    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.tool = PKInkingTool(.pen, color: .label, width: 3)
        canvasView.drawingPolicy = .anyInput
        canvasView.delegate = context.coordinator
        canvasView.isOpaque = true

        let bgView = DotGridBackgroundView()
        bgView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.insertSubview(bgView, at: 0)
        canvasView.backgroundColor = .clear

        canvasView.alwaysBounceVertical = true
        canvasView.alwaysBounceHorizontal = true
        canvasView.minimumZoomScale = 0.25
        canvasView.maximumZoomScale = 4.0
        canvasView.contentSize = CGSize(width: 5000, height: 5000)
        canvasView.drawing = drawing

        let toolPicker = PKToolPicker()
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()

        context.coordinator.canvasView = canvasView
        context.coordinator.toolPicker = toolPicker

        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastDrawingVersion != drawingVersion {
            context.coordinator.lastDrawingVersion = drawingVersion
            uiView.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CanvasView
        var recognitionWorkItem: DispatchWorkItem?
        var saveWorkItem: DispatchWorkItem?
        var recognitionToken: UUID?

        weak var canvasView: PKCanvasView?
        var toolPicker: PKToolPicker?

        var hapticsTriggered: Set<UUID> = []
        var lastRecognizedStrokeCount: Int = 0
        var lastDrawingVersion: UUID = UUID()

        private let feedbackManager = FeedbackManager()
        private let textRecognitionService = TextRecognitionService()

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

        deinit { NotificationCenter.default.removeObserver(self) }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            saveWorkItem?.cancel()
            let saveItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { self.parent.drawing = canvasView.drawing }
            }
            saveWorkItem = saveItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: saveItem)

            recognitionWorkItem?.cancel()
            let recognitionItem = DispatchWorkItem { [weak self] in
                self?.performRecognition(on: canvasView)
            }
            recognitionWorkItem = recognitionItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: recognitionItem)
        }

        @objc private func handleAppWillResignActive() { flushPendingDrawingUpdate() }
        @objc private func handleAppDidEnterBackground() { flushPendingDrawingUpdate() }

        private func flushPendingDrawingUpdate() {
            saveWorkItem?.cancel()
            guard let canvasView else { return }
            if Thread.isMainThread {
                parent.drawing = canvasView.drawing
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let canvasView = self.canvasView else { return }
                    self.parent.drawing = canvasView.drawing
                }
            }
        }

        private func performRecognition(on canvasView: PKCanvasView) {
            let token = UUID()
            recognitionToken = token
            let scale = canvasView.traitCollection.displayScale > 0 ? canvasView.traitCollection.displayScale : 2.0

            textRecognitionService.recognize(
                drawing: canvasView.drawing,
                existingTimers: parent.timers,
                lastRecognizedStrokeCount: lastRecognizedStrokeCount,
                displayScale: scale
            ) { [weak self] result in
                guard let self, self.recognitionToken == token else { return }
                DispatchQueue.main.async {
                    self.lastRecognizedStrokeCount = result.updatedStrokeCount

                    if !result.migratedTimers.isEmpty {
                        var updatedTimers = self.parent.timers
                        for migration in result.migratedTimers {
                            guard let idx = updatedTimers.firstIndex(where: { $0.id == migration.timerID }) else { continue }
                            updatedTimers[idx].anchorX = migration.anchorX
                            updatedTimers[idx].anchorY = migration.anchorY
                            updatedTimers[idx].textRect = migration.textRect
                        }
                        self.parent.timers = updatedTimers
                    }

                    let migratedIDs = Set(result.migratedTimers.map { $0.timerID })
                    let zombieIDs = result.zombieIDs.subtracting(migratedIDs)
                    if !zombieIDs.isEmpty {
                        let eventIDsToDelete = self.parent.timers
                            .filter { zombieIDs.contains($0.id) }
                            .compactMap { $0.calendarEventID }
                        self.parent.timers.removeAll { zombieIDs.contains($0.id) }
                        if !eventIDsToDelete.isEmpty {
                            Task.detached(priority: .utility) {
                                for eventID in eventIDsToDelete {
                                    CalendarManager.shared.deleteEvent(identifier: eventID)
                                }
                            }
                        }
                    }

                    if !result.newTimers.isEmpty {
                        self.parent.onAddTimers(result.newTimers)
                        self.feedbackManager.recognitionSucceeded()
                        self.scheduleCalendarEvents(for: result.newTimers)
                    }
                }
            }
        }

        private func scheduleCalendarEvents(for timers: [BoardTimer]) {
            let calendarManager = CalendarManager.shared
            for timer in timers {
                guard calendarManager.shouldCreateCalendarEvent(targetDate: timer.targetDate, label: timer.label) else { continue }
                let timerID = timer.id
                let title = timer.label ?? timer.originalText
                let date = timer.targetDate
                Task { [weak self] in
                    guard let eventID = await calendarManager.addEvent(title: title, date: date) else { return }
                    await MainActor.run {
                        guard let self,
                              let idx = self.parent.timers.firstIndex(where: { $0.id == timerID }) else { return }
                        self.parent.timers[idx].calendarEventID = eventID
                    }
                }
            }
        }
    }
}

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
// A UIView containing an optional contextual label above and the main countdown
// below. When no label is set, the countdown is centred and sized identically
// to the previous single-UILabel implementation.

class TimerLabel: UIView {
    let timerID: UUID
    var targetDate: Date {
        didSet {
            expiredCallbackFired = false
            updateDisplay()
        }
    }
    
    /// Contextual label extracted from the handwritten text (e.g. "Call Mom").
    /// Displayed as small text above the countdown when non-nil.
    var contextLabelText: String? {
        didSet {
            contextLabelView.text = contextLabelText
            contextLabelView.isHidden = (contextLabelText == nil)
            setNeedsLayout()
        }
    }
    
    var onExpired: ((UUID) -> Void)?
    
    // Sub-views
    private let contextLabelView = UILabel()
    private let countdownLabel = UILabel()
    
    private var isBlinking = false
    private var expiredCallbackFired = false
    private var penColor: UIColor
    
    /// Canvas background color used to mask the handwriting underneath.
    private static let canvasBackgroundColor: UIColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
            : UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1.0)
    }
    
    init(timerID: UUID, targetDate: Date, penColor: UIColor = .label, contextLabel: String? = nil) {
        self.timerID = timerID
        self.targetDate = targetDate
        self.penColor = penColor
        self.contextLabelText = contextLabel
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
            countdownLabel.textColor = penColor
        }
        contextLabelView.textColor = penColor.withAlphaComponent(0.55)
    }
    
    private func setupAppearance() {
        // Canvas-matching background masks the ink underneath
        backgroundColor = Self.canvasBackgroundColor
        layer.cornerRadius = 4
        layer.borderWidth = 0
        clipsToBounds = true
        layer.shadowOpacity = 0
        
        // --- Context label (small, above countdown) ---
        contextLabelView.font = UIFont(name: "Noteworthy", size: 11)
            ?? .systemFont(ofSize: 11, weight: .medium)
        contextLabelView.textColor = penColor.withAlphaComponent(0.55)
        contextLabelView.textAlignment = .center
        contextLabelView.text = contextLabelText
        contextLabelView.isHidden = (contextLabelText == nil)
        addSubview(contextLabelView)
        
        // --- Countdown label (main) ---
        countdownLabel.font = UIFont(name: "Noteworthy-Bold", size: 20)
            ?? .systemFont(ofSize: 20, weight: .bold)
        countdownLabel.textColor = penColor
        countdownLabel.textAlignment = .center
        addSubview(countdownLabel)
        
        updateDisplay()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        if contextLabelText != nil && !contextLabelView.isHidden {
            let contextHeight: CGFloat = 15
            let gap: CGFloat = 1
            let countdownHeight = bounds.height - contextHeight - gap
            
            contextLabelView.frame = CGRect(
                x: 0, y: 2,
                width: bounds.width,
                height: contextHeight
            )
            countdownLabel.frame = CGRect(
                x: 0, y: contextHeight + gap,
                width: bounds.width,
                height: countdownHeight
            )
            // Slightly smaller font when the context label is present.
            countdownLabel.font = UIFont(name: "Noteworthy-Bold", size: 17)
                ?? .systemFont(ofSize: 17, weight: .bold)
        } else {
            contextLabelView.frame = .zero
            countdownLabel.frame = bounds
            countdownLabel.font = UIFont(name: "Noteworthy-Bold", size: 20)
                ?? .systemFont(ofSize: 20, weight: .bold)
        }
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
                countdownLabel.text = " \(prefix)\(h)h \(String(format: "%02d", m))m "
            } else {
                let m = Int(overtime) / 60
                let s = Int(overtime) % 60
                countdownLabel.text = " \(prefix)\(String(format: "%02d:%02d", m, s)) "
            }
            
            countdownLabel.textColor = .systemRed
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
                countdownLabel.text = " \(String(format: "%dh %02dm", h, m)) "
            } else {
                let m = Int(remaining) / 60
                let s = Int(remaining) % 60
                countdownLabel.text = " \(String(format: "%02d:%02d", m, s)) "
            }
            
            // Text color transitions based on urgency
            if remaining < 30 {
                countdownLabel.textColor = .systemRed
            } else if remaining < 60 {
                countdownLabel.textColor = .systemOrange
            } else if remaining < 300 {
                countdownLabel.textColor = .systemYellow.blended(with: .systemOrange)
            } else {
                countdownLabel.textColor = penColor
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
