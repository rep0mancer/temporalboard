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

// MARK: - BoardViewModel (MVVM-compliant: Data only, no UIKit views)

class BoardViewModel: ObservableObject {
    // Data only - no UIKit views
    @Published var drawing: PKDrawing = PKDrawing()
    @Published var timers: [BoardTimer] = []
    
    private let drawingURL: URL
    private let timersURL: URL
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        drawingURL = docs.appendingPathComponent("drawing.data")
        timersURL = docs.appendingPathComponent("timers.json")
        
        loadData()
    }
    
    func updateTimers(_ newTimers: [BoardTimer]) {
        self.timers = newTimers
        saveTimers()
    }
    
    func addTimers(_ newTimers: [BoardTimer]) {
        timers.append(contentsOf: newTimers)
        saveTimers()
    }
    
    func updateDrawing(_ newDrawing: PKDrawing) {
        // Only update if actually changed to avoid unnecessary redraws
        if drawing.dataRepresentation() != newDrawing.dataRepresentation() {
            drawing = newDrawing
            saveDrawing()
        }
    }
    
    func saveData() {
        saveDrawing()
        saveTimers()
    }
    
    func saveDrawing() {
        let data = drawing.dataRepresentation()
        try? data.write(to: drawingURL)
    }
    
    func saveTimers() {
        if let encoded = try? JSONEncoder().encode(timers) {
            try? encoded.write(to: timersURL)
        }
    }
    
    func loadData() {
        // Load drawing
        if let data = try? Data(contentsOf: drawingURL),
           let savedDrawing = try? PKDrawing(data: data) {
            drawing = savedDrawing
        }
        
        // Load timers
        if let data = try? Data(contentsOf: timersURL),
           let savedTimers = try? JSONDecoder().decode([BoardTimer].self, from: data) {
            timers = savedTimers
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
            
            // Debug / Info Overlay
            VStack {
                HStack {
                    Text("TemporalBoard Beta")
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
        .onChange(of: viewModel.timers.count) { _ in viewModel.saveData() }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                viewModel.saveData()
            }
        }
    }
}
