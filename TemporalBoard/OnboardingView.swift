import SwiftUI

// MARK: - OnboardingView (Enhanced with Interactive Demo)

struct OnboardingView: View {
    @Binding var hasSeenOnboarding: Bool
    @State private var currentPage = 0
    
    // Feature definitions
    private let features: [OnboardingFeature] = [
        OnboardingFeature(
            icon: "pencil.line",
            iconColor: .blue,
            title: "Write to Timer",
            subtitle: "Simply write \"15 min\" or \"3pm\" anywhere on the canvas to start a countdown."
        ),
        OnboardingFeature(
            icon: "sparkles",
            iconColor: .purple,
            title: "Smart Recognition",
            subtitle: "Detects durations, relative times, and dates in multiple languages."
        ),
        OnboardingFeature(
            icon: "infinity",
            iconColor: .orange,
            title: "Focus & Flow",
            subtitle: "An infinite dot-grid canvas designed for deep work and quick notes."
        )
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(index == currentPage ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.spring(response: 0.3), value: currentPage)
                }
            }
            .padding(.top, 20)
            
            TabView(selection: $currentPage) {
                // Page 1: Welcome
                welcomePage
                    .tag(0)
                
                // Page 2: Features
                featuresPage
                    .tag(1)
                
                // Page 3: Interactive Demo
                interactiveDemoPage
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.spring(response: 0.4), value: currentPage)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
    
    // MARK: - Welcome Page
    
    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(minHeight: 40, maxHeight: 80)
            
            // App Icon large
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                    .shadow(color: .blue.opacity(0.3), radius: 20, x: 0, y: 10)
                
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 50, weight: .thin))
                    .foregroundStyle(.white)
            }
            
            Spacer()
                .frame(minHeight: 32, maxHeight: 48)
            
            VStack(spacing: 8) {
                Text("Welcome to")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 17, weight: .medium))
                
                Text("TemporalBoard")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text("Your smart whiteboard with auto-timers")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            // Continue button
            Button {
                withAnimation(.spring(response: 0.4)) {
                    currentPage = 1
                }
            } label: {
                Text("Get Started")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(Color.accentColor))
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 50)
        }
    }
    
    // MARK: - Features Page
    
    private var featuresPage: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(minHeight: 20, maxHeight: 40)
            
            // Header
            VStack(spacing: 8) {
                Text("Powerful Features")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                
                Text("Everything you need to stay on time")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
                .frame(minHeight: 24, maxHeight: 40)
            
            // Feature List
            VStack(spacing: 24) {
                ForEach(features) { feature in
                    featureRow(feature)
                }
            }
            .padding(.horizontal, 32)
            
            Spacer()
            
            // Continue button
            Button {
                withAnimation(.spring(response: 0.4)) {
                    currentPage = 2
                }
            } label: {
                Text("Try It Yourself")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(Color.accentColor))
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 50)
        }
    }
    
    // MARK: - Interactive Demo Page
    
    private var interactiveDemoPage: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(minHeight: 20, maxHeight: 40)
            
            Text("Try it now!")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            
            Text("Tap the examples below to see how it works")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            
            Spacer()
                .frame(minHeight: 24, maxHeight: 32)
            
            // Interactive examples
            VStack(spacing: 16) {
                exampleCard(text: "15 min", description: "15 minute timer")
                exampleCard(text: "2h", description: "2 hour timer")
                exampleCard(text: "3pm", description: "Timer until 3 PM")
                exampleCard(text: "um 15", description: "German: at 3 PM")
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Finish button
            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    hasSeenOnboarding = true
                }
            } label: {
                Text("I'm Ready!")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(Color.accentColor))
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 50)
        }
    }
    
    // MARK: - Helper Views
    
    // MARK: - OnboardingFeature Model
    
    private struct OnboardingFeature: Identifiable {
        var id: String { title }
        let icon: String
        let iconColor: Color
        let title: String
        let subtitle: String
    }
    
    private func exampleCard(text: String, description: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            
            Spacer()
            
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            
            Image(systemName: "hand.tap")
                .foregroundStyle(Color.accentColor)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private func featureRow(_ feature: OnboardingFeature) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: feature.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(feature.iconColor.gradient)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text(feature.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(hasSeenOnboarding: .constant(false))
    }
}
#endif
