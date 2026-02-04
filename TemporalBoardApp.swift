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
    @Published var drawing: PKDrawing = PKDrawing() {
        didSet {
            scheduleSaveDrawing()
        }
    }
    @Published var timers: [BoardTimer] = [] {
        didSet {
            scheduleSaveTimers()
        }
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
        // Only update if actually changed to avoid unnecessary redraws
        if drawing.dataRepresentation() != newDrawing.dataRepresentation() {
            drawing = newDrawing
        }
    }
    
    func saveData() {
        saveDrawing(immediately: true)
        saveTimers(immediately: true)
    }
    
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
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                viewModel.saveData()
            }
        }
    }
}
