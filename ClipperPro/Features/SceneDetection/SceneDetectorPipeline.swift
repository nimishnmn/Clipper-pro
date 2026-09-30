import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Progress update during scene detection with Apple Silicon throughput metrics.
struct DetectionProgress: Sendable {
    let processedFrames: Int
    let totalFrames: Int
    let scenesCut: Int
    var processingFPS: Double = 0
    var etaSeconds: Double = 0
    
    var fraction: Double {
        totalFrames > 0 ? min(Double(processedFrames) / Double(totalFrames), 1.0) : 0
    }
    
    var percentString: String {
        "\(Int(fraction * 100))%"
    }
    
    var speedString: String {
        if processingFPS > 0 {
            return "\(Int(processingFPS)) fps"
        }
        return ""
    }
}

/// Reads frames from an AVAsset at a downsampled resolution and emits CVPixelBuffers to Metal.
final class SceneDetectorPipeline: @unchecked Sendable {
    
    private let asset: AVURLAsset
    private let config: DetectionConfig
    
    init(asset: AVURLAsset, config: DetectionConfig) {
        self.asset = asset
        self.config = config
    }
    
    /// Returns cut-point times. Each time is the start of a new scene.
    func detectCutPoints(
        progressHandler: @Sendable @escaping (DetectionProgress) -> Void
    ) async throws -> [CMTime] {
        
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw DetectionError.noVideoTrack
        }
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform   = try await videoTrack.load(.preferredTransform)
        let fps         = try await videoTrack.load(.nominalFrameRate)
        let duration    = try await asset.load(.duration)
        
        // Compute downsampled dimensions preserving exact aspect ratio
        let displaySize = sizeApplyingTransform(naturalSize, transform)
        let displayW = max(abs(displaySize.width), 1)
        let displayH = max(abs(displaySize.height), 1)
        let aspect = displayW / displayH
        let targetW = config.downsampleWidth
        let targetH = max(Int((CGFloat(targetW) / aspect).rounded()), 16)
        let renderW = (targetW / 2) * 2
        let renderH = (targetH / 2) * 2
        
        // Asset reader with Apple Silicon hardware decoding directly to target resolution
        // Using AVAssetReaderTrackOutput guarantees native container presentation timestamps (PTS)
        // with ZERO drift and ZERO frame rate truncation.
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey  as String: renderW,
            kCVPixelBufferHeightKey as String: renderH,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        
        guard reader.canAdd(output) else { throw DetectionError.readerSetupFailed }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? DetectionError.readerStartFailed
        }
        
        // Set up Metal pipeline
        let metalPipeline = try FrameDiffPipeline()
        
        var cutPoints: [CMTime] = []
        var prevBuffer: CVPixelBuffer?
        var frameIndex = 0
        let totalFrames = Int(duration.seconds * Double(max(fps, 1)))
        var lastProgressReportTime = CACurrentMediaTime()
        let startTime = CACurrentMediaTime()
        
        // Read frames: every single frame is analyzed consecutively (0 skipped frames)
        // so that scene cuts are detected at the EXACT frame the scene changes.
        while reader.status == .reading {
            try Task.checkCancellation()
            
            var localSampleBuffer: CMSampleBuffer?
            autoreleasepool {
                localSampleBuffer = output.copyNextSampleBuffer()
            }
            
            guard let sampleBuffer = localSampleBuffer else { break }
            
            frameIndex += 1
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                if let prev = prevBuffer {
                    let score = (try? metalPipeline.score(prev: prev, curr: pixelBuffer)) ?? 0
                    
                    if score > config.threshold {
                        if let lastCut = cutPoints.last {
                            let gap = CMTimeSubtract(presentationTime, lastCut).seconds
                            if gap >= config.minClipDuration {
                                cutPoints.append(presentationTime)
                            }
                        } else {
                            cutPoints.append(presentationTime)
                        }
                    }
                } else {
                    // First frame of the video: always mark as first cut point
                    cutPoints.append(presentationTime)
                }
                prevBuffer = pixelBuffer
            }
            
            // Report progress every ~100ms
            let now = CACurrentMediaTime()
            if now - lastProgressReportTime >= 0.10 {
                lastProgressReportTime = now
                let elapsed = now - startTime
                let fpsRate = elapsed > 0 ? Double(frameIndex) / elapsed : 0
                let remainingFrames = max(0, totalFrames - frameIndex)
                let eta = fpsRate > 0 ? Double(remainingFrames) / fpsRate : 0
                
                let prog = DetectionProgress(
                    processedFrames: frameIndex,
                    totalFrames: max(totalFrames, frameIndex),
                    scenesCut: cutPoints.count,
                    processingFPS: fpsRate,
                    etaSeconds: eta
                )
                progressHandler(prog)
            }
        }
        
        if reader.status == .failed {
            throw reader.error ?? DetectionError.readerFailed
        }
        
        if cutPoints.isEmpty {
            cutPoints.append(.zero)
        }
        
        return cutPoints
    }
    
    enum DetectionError: LocalizedError {
        case noVideoTrack, readerSetupFailed, readerStartFailed, readerFailed
        
        var errorDescription: String? {
            switch self {
            case .noVideoTrack:      return "Video contains no readable video track."
            case .readerSetupFailed: return "Failed to initialize AVAssetReader hardware decoder."
            case .readerStartFailed: return "Failed to start video decoding."
            case .readerFailed:      return "Video decoding failed during scene analysis."
            }
        }
    }
}

// Fileprivate helper to avoid collision with MetadataReader.swift extension
private func sizeApplyingTransform(_ size: CGSize, _ t: CGAffineTransform) -> CGRect {
    CGRect(origin: .zero, size: size).applying(t)
}
