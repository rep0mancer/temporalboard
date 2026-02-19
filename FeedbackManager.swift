import UIKit
import AudioToolbox

final class FeedbackManager {
    private let triToneSoundID: SystemSoundID = 1007
    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let heavyImpactGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    init() {
        lightImpactGenerator.prepare()
        heavyImpactGenerator.prepare()
        notificationGenerator.prepare()
    }

    func recognitionSucceeded() {
        lightImpactGenerator.impactOccurred()
        lightImpactGenerator.prepare()
    }

    func timerExpired() {
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.heavyImpactGenerator.impactOccurred()
            self?.heavyImpactGenerator.prepare()
        }

        AudioServicesPlaySystemSound(triToneSoundID)
    }
}
