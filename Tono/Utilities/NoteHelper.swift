import Foundation

enum NoteHelper {

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Returns (noteName, centsOffset) from a frequency in Hz.
    /// centsOffset is in the range -50...+50.
    static func noteAndCents(frequency: Float) -> (note: String, cents: Int) {
        guard frequency > 0 else { return ("--", 0) }
        let exactMidi = 69.0 + 12.0 * log2(Double(frequency) / 440.0)
        let nearestMidi = Int(exactMidi.rounded())
        guard nearestMidi >= 0 else { return ("--", 0) }

        let cents = Int(((exactMidi - Double(nearestMidi)) * 100).rounded())
        let octave = (nearestMidi / 12) - 1
        let noteName = noteNames[nearestMidi % 12]
        return ("\(noteName)\(octave)", cents)
    }

    static func frequencyToNoteName(frequency: Float) -> String {
        noteAndCents(frequency: frequency).note
    }
}
