import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearanceMode") private var appearanceMode = 0
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("timerSound") private var timerSound = "default"
    @AppStorage("autoDismissTimers") private var autoDismissTimers = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = true
    
    var body: some View {
        NavigationStack {
            List {
                // MARK: - Appearance
                Section {
                    Picker("Mode", selection: $appearanceMode) {
                        Text("System").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                }
                
                // MARK: - Canvas
                Section("Canvas") {
                    Toggle("Show Grid", isOn: $showGrid)
                        .tint(.accentColor)
                }
                
                // MARK: - Notifications
                Section("Notifications") {
                    Toggle("Enable Notifications", isOn: $notificationsEnabled)
                        .tint(.accentColor)
                    
                    if notificationsEnabled {
                        Picker("Sound", selection: $timerSound) {
                            Text("Default").tag("default")
                            Text("Chime").tag("chime")
                            Text("Bell").tag("bell")
                            Text("Silent").tag("silent")
                        }
                    }
                }
                
                // MARK: - Timers
                Section("Timers") {
                    Toggle("Auto-Dismiss Finished", isOn: $autoDismissTimers)
                        .tint(.accentColor)
                }
                
                // MARK: - Data
                Section("Data") {
                    Button("Export Board") { }
                    
                    Button("Reset Onboarding") {
                        hasSeenOnboarding = false
                    }
                    .foregroundStyle(.orange)
                    
                    Button("Clear All Data") {
                        // Clear all data
                    }
                    .foregroundStyle(.red)
                }
                
                // MARK: - About
                Section("About") {
                    HStack { Text("Version"); Spacer(); Text("1.0.0").foregroundStyle(.secondary) }
                    Link("Source Code", destination: URL(string: "https://github.com/rep0mancer/temporalboard")!)
                    Link("Contact Support", destination: URL(string: "mailto:support@temporalboard.app")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
#endif
