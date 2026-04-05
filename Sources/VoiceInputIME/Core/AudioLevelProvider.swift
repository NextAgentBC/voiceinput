import Foundation
import Combine

/// Processes raw audio RMS levels into smooth envelope values for waveform visualization.
final class AudioLevelProvider: ObservableObject {
    @Published var smoothedLevel: Float = 0

    // Envelope follower parameters
    private let attackRate: Float = 0.4    // How fast the level rises
    private let releaseRate: Float = 0.15  // How fast the level falls

    private var currentLevel: Float = 0

    func update(rawLevel: Float) {
        let target = rawLevel

        if target > currentLevel {
            // Attack: level is rising
            currentLevel += (target - currentLevel) * attackRate
        } else {
            // Release: level is falling
            currentLevel += (target - currentLevel) * releaseRate
        }

        // Clamp
        currentLevel = max(0, min(1, currentLevel))
        smoothedLevel = currentLevel
    }

    func reset() {
        currentLevel = 0
        smoothedLevel = 0
    }
}
