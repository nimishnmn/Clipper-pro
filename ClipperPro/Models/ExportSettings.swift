import Foundation
import AVFoundation

enum ExportResolution: String, CaseIterable, Identifiable {
    case original = "Original"
    case uhd4k = "4K (3840×2160)"
    case fhd1080 = "1080p (1920×1080)"
    case hd720 = "720p (1280×720)"
    case sd480 = "480p (854×480)"
    case custom = "Custom"
    var id: String { rawValue }
    
    func size(originalSize: CGSize) -> CGSize {
        switch self {
        case .original: return originalSize
        case .uhd4k: return CGSize(width: 3840, height: 2160)
        case .fhd1080: return CGSize(width: 1920, height: 1080)
        case .hd720: return CGSize(width: 1280, height: 720)
        case .sd480: return CGSize(width: 854, height: 480)
        case .custom: return originalSize
        }
    }
}

enum ExportFrameRate: String, CaseIterable, Identifiable {
    case original = "Original"
    case fps60 = "60 fps"
    case fps30 = "30 fps"
    case fps24 = "24 fps"
    case custom = "Custom"
    var id: String { rawValue }
    
    func fps(originalFPS: Float) -> Float {
        switch self {
        case .original: return originalFPS
        case .fps60: return 60
        case .fps30: return 30
        case .fps24: return 24
        case .custom: return originalFPS
        }
    }
}

enum ExportCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264 (AVC) - Maximum Compatibility"
    case hevc = "H.265 (HEVC) - Apple Silicon Optimized"
    var id: String { rawValue }
    
    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

enum ExportMergeMode: String, CaseIterable, Identifiable {
    case separateFiles = "Separate Clips (1.mp4, 2.mp4...)"
    case mergedVideo = "Merged Single Video File"
    var id: String { rawValue }
}

struct ExportSettings {
    // Source video info
    var sourceSize: CGSize = CGSize(width: 1920, height: 1080)
    var sourceFrameRate: Float = 30
    var sourceBitrate: Int = 8_000_000  // bits/sec
    
    // Export mode
    var mergeMode: ExportMergeMode = .separateFiles
    var createSubfolder: Bool = true
    var subfolderName: String = "Clipped Scenes"
    
    // Video settings
    var resolution: ExportResolution = .original
    var customWidth: Int = 1920
    var customHeight: Int = 1080
    
    var frameRate: ExportFrameRate = .original
    var customFPS: Float = 30
    
    var bitrate: Int = 8_000_000  // bits/sec
    var codec: ExportCodec = .hevc
    
    var outputFolderURL: URL?
    
    var targetSize: CGSize {
        switch resolution {
        case .custom:
            return CGSize(width: customWidth, height: customHeight)
        default:
            return resolution.size(originalSize: sourceSize)
        }
    }
    
    var targetFPS: Float {
        switch frameRate {
        case .custom: return customFPS
        default: return frameRate.fps(originalFPS: sourceFrameRate)
        }
    }
    
    var bitrateFormatted: String {
        let mbps = Double(bitrate) / 1_000_000
        return String(format: "%.1f Mbps", mbps)
    }
    
    /// Update defaults from source video metadata
    mutating func applySourceDefaults(size: CGSize, fps: Float, bitrate: Int) {
        self.sourceSize = size
        self.sourceFrameRate = fps
        self.sourceBitrate = max(bitrate, 2_000_000)
        self.bitrate = max(bitrate, 2_000_000)
        self.customWidth = Int(size.width)
        self.customHeight = Int(size.height)
        self.customFPS = fps
    }
}
