import Foundation

struct PlaybackVisualizerFeatures: Equatable, Sendable {
    var overallEnergy: Float = 0
    var bassEnergy: Float = 0
    var midEnergy: Float = 0
    var trebleEnergy: Float = 0
    var beatImpulse: Float = 0
    var spectralFlux: Float = 0
    var stereoWidth: Float = 0
    var isSilent: Bool = true

    static let zero = PlaybackVisualizerFeatures()
}
