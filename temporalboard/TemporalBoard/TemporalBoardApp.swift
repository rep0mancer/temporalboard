import SwiftUI
import PencilKit
import UserNotifications
import Combine

@main
struct TemporalBoardApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - AppDelegate (Notification Permission)

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermission()
        
        // Register for silent push notifications used by CloudKit
        // subscriptions to deliver remote-change alerts.
        application.registerForRemoteNotifications()
        
        return true
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    
    // Show notifications even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    // MARK: - CloudKit Remote Notifications
    
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // CloudKit subscription delivers silent pushes when the board
        // record changes on another device.
        CloudKitManager.shared.handleRemoteNotification()
        completionHandler(.newData)
    }
}

// MARK: - BoardViewModel

class BoardViewModel: ObservableObject {
    @Published var drawing: PKDrawing = PKDrawing() {
        didSet {
            drawingVersion = UUID()
            scheduleSaveDrawing()
        }
    }
    /// Lightweight version token that changes every time `drawing` is set.
    /// Used by CanvasView.updateUIView to detect changes that don't alter
    /// stroke count or bounds (e.g. a CloudKit-synced stroke move).
    @Published var drawingVersion = UUID()
    @Published var timers: [BoardTimer] = [] {
        didSet {
            scheduleSaveTimers()
            scheduleNotifications()
        }
    }
    
    // MARK: - Centralized Heartbeat
    // A single Combine publisher that ticks once per second on the main RunLoop.
    // All timer labels subscribe to this instead of running individual Timers.
    let heartbeat: AnyPublisher<Date, Never> = Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()
        .eraseToAnyPublisher()
    
    /// Number of active (non-expired) timers.
    var activeTimerCount: Int {
        let now = Date()
        return timers.filter { $0.targetDate > now }.count
    }
    
    /// Number of expired (and not dismissed) timers.
    var expiredTimerCount: Int {
        let now = Date()
        return timers.filter { $0.targetDate <= now && !$0.isDismissed }.count
    }
    
    private let drawingURL: URL
    private let timersURL: URL
    private let ioQueue = DispatchQueue(label: "BoardViewModel.io", qos: .utility)
    private var drawingSaveWorkItem: DispatchWorkItem?
    private var timersSaveWorkItem: DispatchWorkItem?
    private var isLoading = false
    
    // MARK: - CloudKit Sync State
    
    private var cloudSaveWorkItem: DispatchWorkItem?
    /// Prevents cloud push when applying data received from iCloud.
    private var suppressCloudPush = false
    /// Timestamp of the last local user-initiated modification.
    /// Persisted in UserDefaults so it survives app relaunches.
    private static let lastLocalChangeDateKey = "tb_lastLocalChangeDate"
    private var lastLocalChangeDate: Date {
        get { UserDefaults.standard.object(forKey: Self.lastLocalChangeDateKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastLocalChangeDateKey) }
    }
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        drawingURL = docs.appendingPathComponent("drawing.data")
        timersURL = docs.appendingPathComponent("timers.json")
        // Data loading is deferred to loadDataAsync() to avoid blocking the main thread.
        
        // CloudKit disabled for local-only testing.
    }
    
    func updateTimers(_ newTimers: [BoardTimer]) {
        self.timers = newTimers
    }
    
    func addTimers(_ newTimers: [BoardTimer]) {
        timers.append(contentsOf: newTimers)
    }
    
    func updateDrawing(_ newDrawing: PKDrawing) {
        if drawing.dataRepresentation() != newDrawing.dataRepresentation() {
            drawing = newDrawing
        }
    }
    
    func clearExpiredTimers() {
        timers.removeAll { $0.targetDate <= Date() }
    }
    
    func dismissAllAlerts() {
        for i in timers.indices {
            if timers[i].targetDate <= Date() {
                timers[i].isDismissed = true
            }
        }
    }
    
    func clearAll() {
        timers.removeAll()
        drawing = PKDrawing()
    }
    
    func saveData() {
        // Wrap the save in a background task so iOS keeps the process alive
        // long enough for the IO to finish when the app is suspended.
        let application = UIApplication.shared
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        
        bgTaskID = application.beginBackgroundTask(withName: "SaveBoardData") {
            // Expiration handler — the OS is about to kill us, end the task.
            application.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
        
        // Cancel any pending debounced saves — we're performing a definitive flush now.
        drawingSaveWorkItem?.cancel()
        timersSaveWorkItem?.cancel()
        cloudSaveWorkItem?.cancel()
        
        guard !isLoading else {
            application.endBackgroundTask(bgTaskID)
            return
        }
        
        // Snapshot current state on the main thread before dispatching IO.
        let drawingSnapshot = drawing
        let timersSnapshot = timers
        let drawingURL = self.drawingURL
        let timersURL = self.timersURL
        
        // Use a DispatchGroup to track completion of both writes.
        // endBackgroundTask fires only after all IO finishes — no assumptions
        // about queue type or internal scheduling of saveDrawing/saveTimers.
        let group = DispatchGroup()
        
        group.enter()
        ioQueue.async {
            let drawingData = drawingSnapshot.dataRepresentation()
            try? drawingData.write(to: drawingURL, options: .atomic)
            group.leave()
        }
        
        group.enter()
        ioQueue.async {
            if let encoded = try? JSONEncoder().encode(timersSnapshot) {
                try? encoded.write(to: timersURL, options: .atomic)
            }
            group.leave()
        }
        
        group.notify(queue: .global(qos: .utility)) {
            application.endBackgroundTask(bgTaskID)
        }
    }
    
    // MARK: - Persistence
    
    private func scheduleSaveDrawing() {
        saveDrawing(immediately: false)
    }
    
    private func scheduleSaveTimers() {
        saveTimers(immediately: false)
    }
    
    private func saveDrawing(immediately: Bool) {
        guard !isLoading else { return }
        drawingSaveWorkItem?.cancel()
        let drawingSnapshot = drawing
        let workItem = DispatchWorkItem { [drawingURL] in
            let data = drawingSnapshot.dataRepresentation()
            try? data.write(to: drawingURL, options: .atomic)
        }
        drawingSaveWorkItem = workItem
        if immediately {
            ioQueue.async(execute: workItem)
        } else {
            ioQueue.asyncAfter(deadline: .now() + 0.4, execute: workItem)
        }
    }
    
    private func saveTimers(immediately: Bool) {
        guard !isLoading else { return }
        timersSaveWorkItem?.cancel()
        let timersSnapshot = timers
        let workItem = DispatchWorkItem { [timersURL] in
            if let encoded = try? JSONEncoder().encode(timersSnapshot) {
                try? encoded.write(to: timersURL, options: .atomic)
            }
        }
        timersSaveWorkItem = workItem
        if immediately {
            ioQueue.async(execute: workItem)
        } else {
            ioQueue.asyncAfter(deadline: .now() + 0.4, execute: workItem)
        }
    }
    
    /// Load persisted data off the main thread and apply it to the UI when ready.
    /// Call this from a `.task` or `.onAppear` modifier — never from `init()`.
    func loadDataAsync() {
        isLoading = true
        let drawingURL = self.drawingURL
        let timersURL  = self.timersURL
        
        ioQueue.async { [weak self] in
            let loadedDrawing: PKDrawing? = {
                guard let data = try? Data(contentsOf: drawingURL),
                      let drawing = try? PKDrawing(data: data) else { return nil }
                return drawing
            }()
            
            let loadedTimers: [BoardTimer]? = {
                guard let data = try? Data(contentsOf: timersURL),
                      let timers = try? JSONDecoder().decode([BoardTimer].self, from: data) else { return nil }
                return timers
            }()
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // isLoading is still true, so didSet save guards are active.
                if let drawing = loadedDrawing {
                    self.drawing = drawing
                }
                if let timers = loadedTimers {
                    self.timers = self.normalizeTimers(from: timers)
                }
                self.isLoading = false
            }
        }
    }
    
    /// Normalizes transient expiration state at load/apply time so UI-created
    /// labels do not emit launch-time feedback for already-expired timers.
    /// Keeps `isDismissed` and all other fields unchanged.
    private func normalizeTimers(from timers: [BoardTimer]) -> [BoardTimer] {
        let now = Date()
        return timers.map { timer in
            var normalized = timer
            normalized.isExpired = normalized.targetDate <= now
            return normalized
        }
    }
    
    // MARK: - CloudKit Sync
    
    /// Debounced cloud save — waits 3 seconds after the last change before
    /// pushing, so rapid edits are batched into a single upload.
    private func scheduleCloudSave() {
        // Cloud sync intentionally disabled for local-only testing.
        return
    }
    
    /// Snapshot the current board state and upload it to iCloud.
    private func pushToCloud() {
        // Cloud sync intentionally disabled for local-only testing.
        return
    }
    
    /// Fetch the latest board from iCloud.  Applies the cloud data only
    /// when it is newer than the last local modification.
    func pullFromCloud() {
        // Cloud sync intentionally disabled for local-only testing.
        return
    }
    
    // MARK: - Local Notifications
    
    private func scheduleNotifications() {
        let center = UNUserNotificationCenter.current()
        
        // Remove ALL pending notification requests first, then re-schedule only
        // the currently active timers. This ensures that notifications for deleted
        // or cleared timers are always cleaned up (the previous approach only
        // removed IDs still in the timers array, leaving stale requests behind).
        center.removeAllPendingNotificationRequests()
        
        let now = Date()
        for timer in timers {
            guard timer.targetDate > now else { continue }
            
            let content = UNMutableNotificationContent()
            content.title = "Timer Finished"
            content.body = timer.originalText
            content.sound = .default
            content.categoryIdentifier = "TIMER_EXPIRED"
            content.interruptionLevel = .timeSensitive
            
            let interval = timer.targetDate.timeIntervalSince(now)
            guard interval > 0 else { continue }
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: "timer-\(timer.id.uuidString)",
                content: content,
                trigger: trigger
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var viewModel = BoardViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHint = true
    
    /// Persisted flag — `false` until the user has seen the welcome sheet.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    
    var body: some View {
        ZStack {
            // Full-bleed canvas
            CanvasView(
                drawing: $viewModel.drawing,
                timers: $viewModel.timers,
                onAddTimers: viewModel.addTimers,
                heartbeat: viewModel.heartbeat,
                drawingVersion: viewModel.drawingVersion
            )
            .edgesIgnoringSafeArea(.all)
            
            // Floating top bar — Freeform-style minimal overlay
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                
                Spacer()
                
                // Persistent onboarding hint for empty boards (always available,
                // independent of the first-launch welcome sheet).
                if viewModel.timers.isEmpty && showHint {
                    onboardingHint
                        .padding(.bottom, 120)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { !hasSeenOnboarding },
            set: { newValue in
                if !newValue { hasSeenOnboarding = true }
            }
        )) {
            OnboardingView(hasSeenOnboarding: $hasSeenOnboarding)
                .interactiveDismissDisabled()
        }
        .task {
            viewModel.loadDataAsync()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                viewModel.saveData()
            }
        }
        .onChange(of: viewModel.timers.count) { _ in
            if !viewModel.timers.isEmpty {
                withAnimation(.easeOut(duration: 0.4)) {
                    showHint = false
                }
            }
        }
    }
    
    // MARK: - Top Bar
    
    private var topBar: some View {
        HStack(spacing: 8) {
            // App identity pill
            HStack(spacing: 5) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                
                Text("TemporalBoard")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                
                if viewModel.activeTimerCount > 0 {
                    Text("\(viewModel.activeTimerCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                }
                
                if viewModel.expiredTimerCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 8))
                        Text("\(viewModel.expiredTimerCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            
            Spacer()
            
            // Silence button when timers are ringing
            if viewModel.expiredTimerCount > 0 {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        viewModel.dismissAllAlerts()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11))
                        Text("Silence")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
            
            // Overflow menu
            if !viewModel.timers.isEmpty {
                Menu {
                    if viewModel.expiredTimerCount > 0 {
                        Button(role: .destructive) {
                            withAnimation(.spring(response: 0.3)) {
                                viewModel.clearExpiredTimers()
                            }
                        } label: {
                            Label("Clear Finished", systemImage: "checkmark.circle")
                        }
                    }
                    
                    Button(role: .destructive) {
                        withAnimation(.spring(response: 0.3)) {
                            viewModel.timers.removeAll()
                        }
                    } label: {
                        Label("Clear All Timers", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .animation(.spring(response: 0.35), value: viewModel.activeTimerCount)
        .animation(.spring(response: 0.35), value: viewModel.expiredTimerCount)
    }
    
    // MARK: - Onboarding Hint
    
    private var onboardingHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "pencil.tip.crop.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            
            Text("Write anything with a time")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 4) {
                Text("\"Meeting in 15 min\"")
                Text("\"Call mom at 3pm\"")
                Text("\"Lunch 12:30\"")
            }
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
