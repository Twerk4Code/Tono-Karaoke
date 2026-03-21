import Foundation
import SwiftUI

@Observable
@MainActor
final class PitchViewModel {

    private let appState: AppState
    private var enableRequestToken = UUID()

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
        guard !isEnabled else { return }
        isEnabled = true
        let token = UUID()
        enableRequestToken = token

        appState.audioEngine.setupMicrophone { @MainActor [weak self] in
            guard let self else { return }
            guard self.isEnabled, self.enableRequestToken == token else { return }
            guard let trackingNode = self.appState.audioEngine.pitchTrackingNode else {
                self.isEnabled = false
                self.appState.currentError = "Pitch tracking is unavailable. Select an input device and allow microphone access."
                return
            }
            let started = self.appState.pitchTracker.start(inputNode: trackingNode)
            if !started {
                self.isEnabled = false
                self.appState.currentError = "Pitch tracking could not start on the current microphone route."
            }
        }
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        // Invalidate any pending setup callback from a prior enable() call.
        enableRequestToken = UUID()
        appState.pitchTracker.stopTracking()
    }
}
