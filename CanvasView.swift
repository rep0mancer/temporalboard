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
        
        // Dirty-rect tracking: stroke count at last recognition pass.
        // Used to determine which strokes are "new" so we only rasterize
        // the changed region instead of the entire canvas.
        var lastRecognizedStrokeCount: Int = 0
        
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
            let allStrokes = drawing.strokes
            let currentStrokeCount = allStrokes.count
            
            // Nothing to recognize
            if allStrokes.isEmpty {
                lastRecognizedStrokeCount = 0
                return
            }
            
            let token = UUID()
            recognitionToken = token
            let scale = canvasView.traitCollection.displayScale > 0 ? canvasView.traitCollection.displayScale : 2.0
            let languages = recognitionLanguages()
            
            // --- Dirty-rect computation ---
            // Only rasterize the region that changed instead of the entire canvas
            // contentSize, which can be enormous on large boards.
            let scanRect: CGRect
            let isFullScan: Bool
            
            if currentStrokeCount > lastRecognizedStrokeCount && lastRecognizedStrokeCount > 0 {
                // New strokes were added — compute bounding box of only the new ones
                let newStrokes = allStrokes[lastRecognizedStrokeCount...]
                var unionRect = CGRect.null
                for stroke in newStrokes {
                    unionRect = unionRect.union(stroke.renderBounds)
                }
                // Pad by 50 points so nearby context (e.g. a partly-visible word)
                // is included in the rasterized image.
                scanRect = unionRect.insetBy(dx: -50, dy: -50)
                isFullScan = false
            } else {
                // First recognition, strokes erased / modified, or count unchanged —
                // fall back to a full-bounds scan so zombie detection still works.
                scanRect = drawing.bounds
                isFullScan = true
            }
            
            if scanRect.isEmpty || scanRect.isNull {
                lastRecognizedStrokeCount = currentStrokeCount
                return
            }
            
            // Snapshot the count *before* dispatching so the next call can compare.
            lastRecognizedStrokeCount = currentStrokeCount
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                
                // Rasterize only the dirty rect (or full bounds on a full scan).
                let image = drawing.image(from: scanRect, scale: scale)
                guard let cgImage = image.cgImage else { return }
                
                let request = VNRecognizeTextRequest { [weak self] request, error in
                    guard let self = self,
                          let observations = request.results as? [VNRecognizedTextObservation],
                          self.recognitionToken == token else { return }
                    
                    DispatchQueue.main.async {
                        self.processObservations(
                            observations,
                            in: scanRect,
                            strokes: allStrokes,
                            isFullScan: isFullScan
                        )
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
        
        /// - Parameters:
        ///   - observations: Vision text observations from the scanned region.
        ///   - scanRect: The canvas-coordinate rect that was rasterized.
        ///   - strokes: A snapshot of all strokes at the time of recognition.
        ///   - isFullScan: `true` when the entire drawing bounds were scanned
        ///     (erase / first scan). `false` for a partial dirty-rect scan.
        func processObservations(_ observations: [VNRecognizedTextObservation],
                                 in scanRect: CGRect,
                                 strokes: [PKStroke],
                                 isFullScan: Bool = true) {
            // ---------------------------------------------------------------
            // Phase 1: Map ALL recognized text to canvas coordinates.
            // We need every observation (not just time-parseable ones) so
            // the zombie-detection pass can verify which timers still have
            // underlying ink.
            // ---------------------------------------------------------------
            struct RecognizedText {
                let text: String
                let normalizedText: String
                let centerX: CGFloat
                let centerY: CGFloat
                let textRect: CGRect
            }
            
            var recognizedTexts: [RecognizedText] = []
            var newTimers: [BoardTimer] = []
            
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                
                // Convert Vision coordinates (0,0 bottom-left) -> content coordinates
                let boundingBox = observation.boundingBox
                let w = scanRect.width
                let h = scanRect.height
                let x = scanRect.origin.x + (boundingBox.origin.x * w)
                let y = scanRect.origin.y + ((1 - boundingBox.origin.y - boundingBox.height) * h)
                let rectWidth = boundingBox.width * w
                let rectHeight = boundingBox.height * h
                
                let textRect = CGRect(x: x, y: y, width: rectWidth, height: rectHeight)
                let centerX = x + rectWidth / 2
                let centerY = y + rectHeight / 2
                let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                
                recognizedTexts.append(RecognizedText(
                    text: text,
                    normalizedText: normalizedText,
                    centerX: centerX,
                    centerY: centerY,
                    textRect: textRect
                ))
                
                // Only create timers from parseable time expressions
                guard let parseResult = timeParser.parseDetailed(text: text) else { continue }
                
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
                        penColorHex: penColor.hexString,
                        label: parseResult.label
                    )
                    newTimers.append(newTimer)
                }
            }
            
            // ---------------------------------------------------------------
            // Phase 1.5: Migration — detect lasso-moved timers.
            // When the user moves ink with the PencilKit lasso tool, the
            // recognized text reappears at a new location.  Without this
            // phase, Phase 2 would delete the "missing" timer and Phase 3
            // would create a fresh one — destroying the countdown state.
            // Instead, we detect the move and update the timer's
            // coordinates in-place so the countdown is preserved.
            //
            // Only performed during a full scan (same guard as Phase 2).
            // ---------------------------------------------------------------
            var migratedTimerIDs: Set<UUID> = []
            
            if isFullScan {
                let scanArea = scanRect
                
                // Track which recognized-text indices have been claimed by a
                // migration so each observation is consumed at most once.
                var claimedRecognizedIndices: Set<Int> = []
                
                for (timerIdx, timer) in parent.timers.enumerated() {
                    let anchor = CGPoint(x: timer.anchorX, y: timer.anchorY)
                    guard scanArea.contains(anchor) else { continue }
                    
                    let timerText = timer.originalText
                        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    
                    // Is the timer still at its original location?
                    let stillPresent = recognizedTexts.contains { recognized in
                        let dx = timer.anchorX - recognized.centerX
                        let dy = timer.anchorY - recognized.centerY
                        let closeEnough = (dx * dx + dy * dy) < 2500
                        let textMatch = timerText == recognized.normalizedText
                            || timerText.contains(recognized.normalizedText)
                            || recognized.normalizedText.contains(timerText)
                        return closeEnough && textMatch
                    }
                    
                    // Timer is still where we expect — nothing to migrate.
                    if stillPresent { continue }
                    
                    // Timer text is no longer at its anchor.  Search the
                    // recognized texts for an exact match at a *different*
                    // location (≥ 50 pt away) — this indicates a lasso move.
                    var bestMatchIdx: Int?
                    var bestDistanceSq: CGFloat = .greatestFiniteMagnitude
                    
                    for (idx, recognized) in recognizedTexts.enumerated() {
                        guard !claimedRecognizedIndices.contains(idx) else { continue }
                        
                        // Require an exact normalized-text match.
                        guard timerText == recognized.normalizedText else { continue }
                        
                        // Must be away from the original anchor (the nearby
                        // case was already handled by the stillPresent check).
                        let dx = timer.anchorX - recognized.centerX
                        let dy = timer.anchorY - recognized.centerY
                        let distSq = dx * dx + dy * dy
                        guard distSq >= 2500 else { continue }
                        
                        // If multiple identical texts exist, pick the closest.
                        if distSq < bestDistanceSq {
                            bestDistanceSq = distSq
                            bestMatchIdx = idx
                        }
                    }
                    
                    if let matchIdx = bestMatchIdx {
                        let matched = recognizedTexts[matchIdx]
                        
                        // Migrate: update coordinates in-place, preserving
                        // the countdown, expiration state, and all metadata.
                        parent.timers[timerIdx].anchorX = matched.centerX
                        parent.timers[timerIdx].anchorY = matched.centerY
                        parent.timers[timerIdx].textRect = matched.textRect
                        
                        claimedRecognizedIndices.insert(matchIdx)
                        migratedTimerIDs.insert(timer.id)
                    }
                }
                
                // Remove from newTimers any entries that overlap with a
                // migrated timer's new position — the existing timer already
                // covers that location and we must not create a duplicate.
                if !migratedTimerIDs.isEmpty {
                    newTimers.removeAll { candidate in
                        parent.timers.contains { existing in
                            guard migratedTimerIDs.contains(existing.id) else { return false }
                            let dx = existing.anchorX - candidate.anchorX
                            let dy = existing.anchorY - candidate.anchorY
                            return (dx * dx + dy * dy) < 2500
                        }
                    }
                }
            }
            
            // ---------------------------------------------------------------
            // Phase 2: Deletion Sync — purge "zombie" timers.
            // Only performed during a full scan (e.g. after erasing strokes
            // or the very first recognition pass). During a partial dirty-rect
            // scan we intentionally skip this: timers outside the dirty rect
            // would never appear in the observations and would be falsely
            // classified as zombies.
            //
            // Timers that were migrated in Phase 1.5 are excluded — their
            // anchors have already been updated to the new location.
            // ---------------------------------------------------------------
            if isFullScan {
                let scanArea = scanRect
                var zombieIDs: Set<UUID> = []
                
                for timer in parent.timers {
                    // Skip timers that were just migrated.
                    guard !migratedTimerIDs.contains(timer.id) else { continue }
                    
                    let anchor = CGPoint(x: timer.anchorX, y: timer.anchorY)
                    
                    // Only consider timers whose anchor is inside the scanned region.
                    guard scanArea.contains(anchor) else { continue }
                    
                    let timerText = timer.originalText
                        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    
                    // Check if any observation still matches this timer by both
                    // proximity (~50 px radius) AND text content.
                    let stillPresent = recognizedTexts.contains { recognized in
                        let dx = timer.anchorX - recognized.centerX
                        let dy = timer.anchorY - recognized.centerY
                        let closeEnough = (dx * dx + dy * dy) < 2500
                        let textMatch = timerText == recognized.normalizedText
                            || timerText.contains(recognized.normalizedText)
                            || recognized.normalizedText.contains(timerText)
                        return closeEnough && textMatch
                    }
                    
                    if !stillPresent {
                        zombieIDs.insert(timer.id)
                    }
                }
                
                if !zombieIDs.isEmpty {
                    // Clean up calendar events for zombie timers before removal.
                    for timer in parent.timers where zombieIDs.contains(timer.id) {
                        if let eventID = timer.calendarEventID {
                            CalendarManager.shared.deleteEvent(identifier: eventID)
                        }
                    }
                    parent.timers.removeAll { zombieIDs.contains($0.id) }
                }
            }
            
            // ---------------------------------------------------------------
            // Phase 3: Add newly discovered timers.
            // ---------------------------------------------------------------
            if !newTimers.isEmpty {
                parent.onAddTimers(newTimers)
                
                // Subtle haptic to confirm recognition (uses pre-warmed generator)
                lightImpactGenerator.impactOccurred()
                lightImpactGenerator.prepare() // Re-arm for next use
                
                // Phase 3.5: Calendar integration — asynchronously create
                // iOS Calendar events for qualifying timers (long-term or
                // keyword-important).  Runs off the main thread; the
                // returned eventIdentifier is written back on main.
                scheduleCalendarEvents(for: newTimers)
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
        
        // MARK: - Calendar Integration
        
        /// Asynchronously creates iOS Calendar events for newly recognized
        /// timers that meet the "long-term or important" criteria.  Does NOT
        /// block the main thread or the recognition loop.
        private func scheduleCalendarEvents(for timers: [BoardTimer]) {
            let calendarManager = CalendarManager.shared
            
            for timer in timers {
                guard calendarManager.shouldCreateCalendarEvent(
                    targetDate: timer.targetDate,
                    label: timer.label
                ) else { continue }
                
                let timerID = timer.id
                let title = timer.label ?? timer.originalText
                let date = timer.targetDate
                
                Task { [weak self] in
                    guard let eventID = await calendarManager.addEvent(
                        title: title,
                        date: date
                    ) else { return }
                    
                    // Write the event identifier back to the model on main.
                    await MainActor.run {
                        guard let self = self else { return }
                        if let idx = self.parent.timers.firstIndex(where: { $0.id == timerID }) {
                            self.parent.timers[idx].calendarEventID = eventID
                        }
                    }
                }
            }
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
                    label.contextLabelText = timer.label
                } else {
                    label = TimerLabel(
                        timerID: timer.id,
                        targetDate: timer.targetDate,
                        penColor: penColor,
                        contextLabel: timer.label
                    )
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
                // When a contextual label is present, add extra height.
                let hasContextLabel = timer.label != nil
                if timer.textRect != .zero {
                    let padding: CGFloat = 4
                    let extraHeight: CGFloat = hasContextLabel ? 18 : 0
                    let labelWidth  = max(timer.textRect.width  + padding * 2, 80)
                    let labelHeight = max(timer.textRect.height + padding * 2 + extraHeight,
                                          hasContextLabel ? 46 : 30)
                    label.frame = CGRect(
                        x: timer.textRect.midX - labelWidth  / 2,
                        y: timer.textRect.midY - labelHeight / 2,
                        width:  labelWidth,
                        height: labelHeight
                    )
                } else {
                    // Fallback when textRect is unavailable — center on anchor point
                    let labelWidth: CGFloat = 100
                    let labelHeight: CGFloat = hasContextLabel ? 46 : 30
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
                title: timer.label ?? timer.originalText,
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
                // Re-extract the contextual label from the edited text.
                if let parseResult = self.timeParser.parseDetailed(text: newText) {
                    updatedTimers[index].label = parseResult.label
                } else {
                    updatedTimers[index].label = nil
                }
                self.hapticsTriggered.remove(timerID)
                self.parent.timers = updatedTimers
            }
        }
        
        private func deleteTimer(_ timerID: UUID) {
            DispatchQueue.main.async {
                // Clean up the associated calendar event before removing the timer.
                if let timer = self.parent.timers.first(where: { $0.id == timerID }),
                   let eventID = timer.calendarEventID {
                    CalendarManager.shared.deleteEvent(identifier: eventID)
                }
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
