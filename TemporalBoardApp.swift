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
        saveData()
    }
    
    func saveData() {
        // 1. Drawing speichern
        let data = canvasView.drawing.dataRepresentation()
        try? data.write(to: drawingURL)
        
        // 2. Timer speichern
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
    
    var body: some View {
        ZStack {
            CanvasView(
                canvasView: $viewModel.canvasView,
                timers: $viewModel.timers,
                onUpdateTimers: viewModel.updateTimers
            )
            .edgesIgnoringSafeArea(.all)
            
            // Debug / Info Overlay (Optional, da v0 minimal sein soll, lassen wir es fast leer)
            VStack {
                HStack {
                    Text("TemporalBoard v0")
                        .font(.caption)
                        .padding(8)
                        .background(.thinMaterial)
                        .cornerRadius(8)
                        .padding()
                    Spacer()
                }
                Spacer()
            }
        }
        // Wichtig: Wenn die App in den Hintergrund geht, speichern
        .onChange(of: viewModel.timers.count) { _ in viewModel.saveData() }
    }
}
