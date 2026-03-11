import Foundation

struct PitchReading: Sendable {
    let frequency: Float
    let note: String
    let cents: Int       // -50...+50 offset from nearest note
    let timestamp: Date

    var isOnPitch: Bool { abs(cents) <= 15 }

    static let silent = PitchReading(frequency: 0, note: "--", cents: 0, timestamp: Date())
}
