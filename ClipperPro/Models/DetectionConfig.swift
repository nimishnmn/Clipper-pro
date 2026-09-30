import Foundation

enum DetectionSpeedMode: String, CaseIterable, Identifiable, Sendable {
    case turbo = "Turbo (240p ~2500 fps)"
    case balanced = "Balanced (320p ~1500 fps)"
    case accurate = "Precision (480p ~800 fps)"
    var id: String { rawValue }
    
    var downsampleWidth: Int {
        switch self {
        case .turbo: return 240
        case .balanced: return 320
        case .accurate: return 480
        }
    }
}

enum SensitivityPreset: String, CaseIterable, Identifiable, Sendable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    var id: String { rawValue }
    
    var threshold: Float {
        switch self {
        case .low: return 0.28     // Major scene changes, high contrast cuts
        case .medium: return 0.20  // Standard video, movie, anime & dialog cuts
        case .high: return 0.15    // Fast-paced cuts, subtle lighting/angle shifts
        }
    }
    
    var description: String {
        switch self {
        case .low: return "Fewer clips (only major scene changes)"
        case .medium: return "Standard (recommended for movies, anime & YouTube)"
        case .high: return "More clips (captures subtle camera shifts & quick cuts)"
        }
    }
}

struct DetectionConfig: Sendable {
    /// Scene change sensitivity threshold (0.05–0.50). Lower = more sensitive (more cuts).
    var threshold: Float = 0.20
    /// Minimum clip duration in seconds. Clips shorter than this are not cut.
    var minClipDuration: Double = 0.20
    /// Detection speed profile optimizing Apple Silicon Media Engine decoding throughput.
    var speedMode: DetectionSpeedMode = .balanced
    /// Downsample width before GPU diff computation.
    var downsampleWidth: Int { speedMode.downsampleWidth }
    /// Active sensitivity preset
    var preset: SensitivityPreset = .medium
    
    static let `default` = DetectionConfig()
    
    var sensitivityPercent: Int {
        // Map threshold 0.32 -> 10% sensitivity, 0.20 -> 50% sensitivity, 0.12 -> 90% sensitivity
        let normalized = (0.35 - Double(threshold)) / (0.35 - 0.10)
        let clamped = min(max(normalized * 100, 10), 95)
        return Int(clamped.rounded())
    }
    
    mutating func applyPreset(_ preset: SensitivityPreset) {
        self.preset = preset
        self.threshold = preset.threshold
    }
    
    mutating func setSensitivityPercent(_ percent: Double) {
        // Map 10% -> 0.32, 50% -> 0.20, 90% -> 0.12
        let fraction = percent / 100.0
        self.threshold = Float(0.35 - fraction * (0.35 - 0.10))
    }
}
