import SwiftUI

// MARK: - OnboardingView (Apple-style Welcome Sheet)

/// A first-launch welcome screen modelled after Apple's built-in app welcome
/// sheets (Pages, Numbers, Keynote).  Presented once via `@AppStorage` and
/// dismissed by tapping "Continue".
struct OnboardingView: View {
    @Binding var hasSeenOnboarding: Bool
    
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
            Spacer()
                .frame(minHeight: 20, maxHeight: 56)
            
            // --- Header ---
            headerSection
            
            Spacer()
                .frame(minHeight: 24, maxHeight: 40)
            
            // --- Feature List ---
            VStack(spacing: 28) {
                ForEach(features) { feature in
                    featureRow(feature)
                }
            }
            .padding(.horizontal, 32)
            
            Spacer()
            
            // --- Continue Button ---
            continueButton
                .padding(.horizontal, 48)
                .padding(.bottom, 50)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            
            VStack(spacing: 0) {
                Text("Welcome to")
                    .foregroundStyle(.primary)
                Text("TemporalBoard")
                    .foregroundStyle(.tint)
            }
            .font(.system(size: 34, weight: .bold, design: .rounded))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
    
    // MARK: - Feature Row
    
    private func featureRow(_ feature: OnboardingFeature) -> some View {
        HStack(alignment: .top, spacing: 18) {
            // Large colored SF Symbol in a squircle
            Image(systemName: feature.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(feature.iconColor.gradient)
                )
            
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text(feature.subtitle)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    // MARK: - Continue Button
    
    private var continueButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) {
                hasSeenOnboarding = true
            }
        } label: {
            Text("Continue")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - OnboardingFeature Model

private struct OnboardingFeature: Identifiable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
}

// MARK: - Preview

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(hasSeenOnboarding: .constant(false))
    }
}
#endif
