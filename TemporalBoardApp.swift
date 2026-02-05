import SwiftUI
import PencilKit
import UserNotifications

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
}

// MARK: - BoardViewModel

class BoardViewModel: ObservableObject {
    @Published var drawing: PKDrawing = PKDrawing() {
        didSet {
            scheduleSaveDrawing()
        }
    }
    @Published var timers: [BoardTimer] = [] {
        didSet {
            scheduleSaveTimers()
            scheduleNotifications()
        }
    }
    
    /// Number of active (non-expired) timers for the UI badge.
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
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        drawingURL = docs.appendingPathComponent("drawing.data")
        timersURL = docs.appendingPathComponent("timers.json")
        
        isLoading = true
        loadData()
        isLoading = false
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
    
    func saveData() {
        saveDrawing(immediately: true)
        saveTimers(immediately: true)
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
        let data = drawing.dataRepresentation()
        let workItem = DispatchWorkItem { [drawingURL] in
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
    
    func loadData() {
        if let data = try? Data(contentsOf: drawingURL),
           let savedDrawing = try? PKDrawing(data: data) {
            drawing = savedDrawing
        }
        
        if let data = try? Data(contentsOf: timersURL),
           let savedTimers = try? JSONDecoder().decode([BoardTimer].self, from: data) {
            timers = savedTimers
        }
    }
    
    // MARK: - Local Notifications
    
    private func scheduleNotifications() {
        let center = UNUserNotificationCenter.current()
        // Remove all pending (we reschedule on every change)
        center.removePendingNotificationRequests(withIdentifiers:
            timers.map { "timer-\($0.id.uuidString)" }
        )
        
        let now = Date()
        for timer in timers {
            guard timer.targetDate > now else { continue }
            
            let content = UNMutableNotificationContent()
            content.title = "Timer Finished"
            content.body = timer.originalText
            content.sound = .default
            content.categoryIdentifier = "TIMER_EXPIRED"
            
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
    
    var body: some View {
        ZStack {
            CanvasView(
                drawing: $viewModel.drawing,
                timers: $viewModel.timers,
                onAddTimers: viewModel.addTimers
            )
            .edgesIgnoringSafeArea(.all)
            
            // Top bar overlay
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // App title with active timer count
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .font(.caption)
                        Text("TemporalBoard")
                            .font(.caption.weight(.semibold))
                        
                        if viewModel.activeTimerCount > 0 {
                            Text("\(viewModel.activeTimerCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue))
                        }
                        
                        if viewModel.expiredTimerCount > 0 {
                            Text("\(viewModel.expiredTimerCount) done")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .cornerRadius(10)
                    
                    Spacer()
                    
                    // Action buttons
                    if viewModel.expiredTimerCount > 0 {
                        Button {
                            viewModel.dismissAllAlerts()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bell.slash")
                                Text("Silence")
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial)
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if !viewModel.timers.isEmpty {
                        Menu {
                            if viewModel.expiredTimerCount > 0 {
                                Button(role: .destructive) {
                                    withAnimation {
                                        viewModel.clearExpiredTimers()
                                    }
                                } label: {
                                    Label("Clear Finished Timers", systemImage: "trash")
                                }
                            }
                            
                            Button(role: .destructive) {
                                withAnimation {
                                    viewModel.timers.removeAll()
                                }
                            } label: {
                                Label("Clear All Timers", systemImage: "trash.fill")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.body)
                                .padding(6)
                                .background(.thinMaterial)
                                .cornerRadius(10)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                Spacer()
                
                // Bottom hint for new users
                if viewModel.timers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "pencil.tip.crop.circle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Write something with a time to get started")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Try: \"Meeting 15 min\" or \"Call at 14:30\"")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .padding(.bottom, 100)
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                viewModel.saveData()
            }
        }
    }
}
