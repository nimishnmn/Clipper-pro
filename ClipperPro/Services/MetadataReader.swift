import Foundation
import AVFoundation
import CoreGraphics

struct SourceVideoInfo: Sendable {
    let url: URL
    let naturalSize: CGSize
    let frameRate: Float
    let estimatedBitrate: Int   // bits/sec
    let duration: CMTime
    let durationSeconds: Double
    let codecName: String
    let hasAudio: Bool
    
    var resolutionString: String {
        "\(Int(naturalSize.width))×\(Int(naturalSize.height))"
    }
    
    var fpsString: String {
        String(format: "%.2f fps", frameRate)
    }
    
    var bitrateString: String {
        let mbps = Double(estimatedBitrate) / 1_000_000
        return String(format: "%.1f Mbps", mbps)
    }
    
    var durationString: String {
        let d = durationSeconds
        let h = Int(d) / 3600
        let m = (Int(d) % 3600) / 60
        let s = Int(d) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}

actor MetadataReader {
    
    static func read(from url: URL) async throws -> SourceVideoInfo {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        
        // Load required properties
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw MetadataError.noVideoTrack
        }
        
        async let naturalSize = videoTrack.load(.naturalSize)
        async let preferredTransform = videoTrack.load(.preferredTransform)
        async let frameRate = videoTrack.load(.nominalFrameRate)
        async let estimatedDataRate = videoTrack.load(.estimatedDataRate)
        async let duration = asset.load(.duration)
        async let formatDescriptions = videoTrack.load(.formatDescriptions)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        
        let size = try await naturalSize
        let transform = try await preferredTransform
        let fps = try await frameRate
        let dataRate = try await estimatedDataRate
        let dur = try await duration
        let fmts = try await formatDescriptions
        let audioTrackList = try await audioTracks
        
        // Apply preferred transform to get display size
        let displaySize = size.applying(transform).standardized
        let correctedSize: CGSize
        if displaySize.width < 0 || displaySize.height < 0 {
            correctedSize = CGSize(width: abs(displaySize.width), height: abs(displaySize.height))
        } else if displaySize.width == 0 || displaySize.height == 0 {
            correctedSize = size  // fallback
        } else {
            correctedSize = displaySize
        }
        
        // Extract codec name
        var codecName = "Unknown"
        if let fmt = fmts.first {
            let desc = fmt as CMFormatDescription
            let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
            let bytes = withUnsafeBytes(of: mediaSubType.bigEndian) { Data($0) }
            codecName = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
        }
        
        return SourceVideoInfo(
            url: url,
            naturalSize: correctedSize,
            frameRate: fps,
            estimatedBitrate: Int(dataRate),
            duration: dur,
            durationSeconds: dur.seconds,
            codecName: codecName,
            hasAudio: !audioTrackList.isEmpty
        )
    }
    
    enum MetadataError: LocalizedError {
        case noVideoTrack
        
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The file contains no video track."
            }
        }
    }
}

extension CGRect {
    var standardized: CGSize {
        CGSize(width: abs(width), height: abs(height))
    }
}

extension CGSize {
    func applying(_ transform: CGAffineTransform) -> CGRect {
        let rect = CGRect(origin: .zero, size: self)
        return rect.applying(transform)
    }
}
