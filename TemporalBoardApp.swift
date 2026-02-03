import SwiftUI
import PencilKit

@main
struct TemporalBoardApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

enum ExpiredTimerBehavior: String, CaseIterable, Identifiable {
    case stay
    case fade
    
    var id: String { rawValue }
    
    var label: String {
        switch self {
        case .stay:
            return "Stay"
        case .fade:
            return "Fade"
        }
    }
}

class BoardViewModel: ObservableObject {
    @Published var canvasView = PKCanvasView()
    @Published var timers: [BoardTimer] = []
    
    private var timer: Timer?
    private let drawingURL: URL
    private let timersURL: URL
    
    init() {
        // Pfade für Speicher
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        drawingURL = docs.appendingPathComponent("drawing.data")
        timersURL = docs.appendingPathComponent("timers.json")
        
        loadData()
        startClock()
    }
    
    func startClock() {
        // Jede Sekunde UI aktualisieren
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.objectWillChange.send() // Trigger UI Update
        }
    }
    
    func updateTimers(_ newTimers: [BoardTimer]) {
        self.timers = newTimers
        saveTimers()
    }
    
    func saveData() {
        saveDrawing()
        saveTimers()
    }
    
    func saveDrawing() {
        let data = canvasView.drawing.dataRepresentation()
        try? data.write(to: drawingURL)
    }
    
    func saveTimers() {
        if let encoded = try? JSONEncoder().encode(timers) {
            try? encoded.write(to: timersURL)
        }
    }
    
    func loadData() {
        // Drawing laden
        if let data = try? Data(contentsOf: drawingURL),
           let drawing = try? PKDrawing(data: data) {
            canvasView.drawing = drawing
        }
        
        // Timer laden
        if let data = try? Data(contentsOf: timersURL),
           let savedTimers = try? JSONDecoder().decode([BoardTimer].self, from: data) {
            timers = savedTimers
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = BoardViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSettingsPresented = false
    
    @AppStorage("selectedInkColor") private var selectedInkColor = "#000000"
    @AppStorage("selectedInkWidth") private var selectedInkWidth: Double = 10
    @AppStorage("recognitionEnabled") private var recognitionEnabled = true
    @AppStorage("recognitionDebounce") private var recognitionDebounce: Double = 1.5
    @AppStorage("defaultTimeOfDay") private var defaultTimeOfDay = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @AppStorage("expiredTimerBehavior") private var expiredTimerBehavior = ExpiredTimerBehavior.fade.rawValue
    
    private let palette: [String] = [
        "#000000",
        "#1F2A44",
        "#2563EB",
        "#0F766E",
        "#F97316",
        "#DC2626",
        "#7C3AED"
    ]
    
    var body: some View {
        ZStack {
            CanvasView(
                canvasView: $viewModel.canvasView,
                timers: $viewModel.timers,
                onUpdateTimers: viewModel.updateTimers,
                onSaveDrawing: viewModel.saveDrawing,
                toolColor: UIColor(hex: selectedInkColor) ?? .black,
                toolWidth: CGFloat(selectedInkWidth),
                recognitionEnabled: recognitionEnabled,
                recognitionDebounce: recognitionDebounce,
                defaultTime: Calendar.current.dateComponents([.hour, .minute], from: defaultTimeOfDay),
                expiredBehavior: ExpiredTimerBehavior(rawValue: expiredTimerBehavior) ?? .fade
            )
            .edgesIgnoringSafeArea(.all)
            
            // Minimales Overlay mit Werkzeugen und Settings
            VStack {
                HStack {
                    HStack(spacing: 8) {
                        ForEach(palette, id: \.self) { hex in
                            Button {
                                selectedInkColor = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? .black)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle()
                                            .stroke(selectedInkColor == hex ? Color.white : Color.clear, lineWidth: 2)
                                    )
                                    .shadow(radius: 1)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Slider(value: $selectedInkWidth, in: 4...20, step: 1)
                            .frame(width: 120)
                        
                        Button {
                            isSettingsPresented = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(6)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(.thinMaterial)
                    .cornerRadius(12)
                    .padding()
                    Spacer()
                }
                Spacer()
            }
        }
        // Wichtig: Wenn die App in den Hintergrund geht, speichern
        .onChange(of: viewModel.timers.count) { _ in viewModel.saveData() }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                viewModel.saveData()
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(
                recognitionEnabled: $recognitionEnabled,
                recognitionDebounce: $recognitionDebounce,
                defaultTimeOfDay: $defaultTimeOfDay,
                expiredTimerBehavior: $expiredTimerBehavior
            )
        }
    }
}

struct SettingsView: View {
    @Binding var recognitionEnabled: Bool
    @Binding var recognitionDebounce: Double
    @Binding var defaultTimeOfDay: Date
    @Binding var expiredTimerBehavior: String
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Recognition")) {
                    Toggle("Recognition enabled", isOn: $recognitionEnabled)
                    Stepper(value: $recognitionDebounce, in: 0.5...3.0, step: 0.5) {
                        Text("Debounce: \(recognitionDebounce, specifier: "%.1f")s")
                    }
                }
                
                Section(header: Text("Defaults")) {
                    DatePicker("Date-only time", selection: $defaultTimeOfDay, displayedComponents: .hourAndMinute)
                }
                
                Section(header: Text("Expired timers")) {
                    Picker("Behavior", selection: $expiredTimerBehavior) {
                        ForEach(ExpiredTimerBehavior.allCases) { behavior in
                            Text(behavior.label).tag(behavior.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
