import Foundation
import SwiftUI

@Observable
@MainActor
final class PitchViewModel {

    private let appState: AppState

    var isEnabled = false
    var currentReading: PitchReading { appState.pitchTracker.currentReading }
    var isTracking: Bool { appState.pitchTracker.isTracking }

    init(appState: AppState) {
        self.appState = appState
    }

    func toggle() {
        if isEnabled {
            disable()
        } else {
            enable()
        }
    }

    private func enable() {
        isEnabled = true
        appState.audioEngine.setupMicrophone { @MainActor [weak self] in
            guard let self else { return }
            guard let mic = self.appState.audioEngine.mic else {
                print("[PitchViewModel] Microphone not available after setup.")
                self.isEnabled = false
                return
            }
            self.appState.pitchTracker.start(microphone: mic)
        }
    }

    func disable() {
        // CRITICAL: always stop tap before disabling — prevents CoreAudio deadlock
        appState.pitchTracker.stopTracking()
        isEnabled = false
    }
}
