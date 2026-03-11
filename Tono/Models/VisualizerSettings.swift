import Foundation

struct VisualizerSettings: Codable, Equatable {
    enum Placement: String, Codable, CaseIterable {
        case globalBackground
        case lyricsPane
    }

    enum Style: String, Codable, CaseIterable {
        case neon
        case appleMovie
    }

    var isEnabled: Bool = false
    var intensity: Double = 0.35
    var placement: Placement = .lyricsPane
    var style: Style = .appleMovie
    /// Additional darkening overlay for text readability over motion-heavy backgrounds.
    var readabilityScrim: Double = 0.42

    init(
        isEnabled: Bool = false,
        intensity: Double = 0.35,
        placement: Placement = .lyricsPane,
        style: Style = .appleMovie,
        readabilityScrim: Double = 0.42
    ) {
        self.isEnabled = isEnabled
        self.intensity = intensity
        self.placement = placement
        self.style = style
        self.readabilityScrim = readabilityScrim
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case intensity
        case placement
        case style
        case readabilityScrim
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 0.35
        if let rawPlacement = try c.decodeIfPresent(String.self, forKey: .placement),
           let decodedPlacement = Placement(rawValue: rawPlacement) {
            placement = decodedPlacement
        } else {
            placement = .lyricsPane
        }
        if let rawStyle = try c.decodeIfPresent(String.self, forKey: .style),
           let decodedStyle = Style(rawValue: rawStyle) {
            style = decodedStyle
        } else {
            style = .appleMovie
        }
        readabilityScrim = try c.decodeIfPresent(Double.self, forKey: .readabilityScrim) ?? 0.42
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(placement.rawValue, forKey: .placement)
        try c.encode(style.rawValue, forKey: .style)
        try c.encode(readabilityScrim, forKey: .readabilityScrim)
    }
}
