import Foundation
import AVFoundation
import CoreMedia

/// High-level scene detector: takes a URL, returns [VideoClip].
@MainActor
final class SceneDetector: ObservableObject {
    
    @Published var isDetecting = false
    @Published var progress: DetectionProgress?
    @Published var detectedClips: [VideoClip] = []
    @Published var error: Error?
    
    private var detectionTask: Task<Void, Never>?
    
    func detect(
        url: URL,
        config: DetectionConfig = .default
    ) async {
        detectionTask?.cancel()
        isDetecting = true
        error = nil
        detectedClips = []
        progress = nil
        
        detectionTask = Task {
            do {
                let asset = AVURLAsset(url: url)
                let pipeline = SceneDetectorPipeline(asset: asset, config: config)
                
                let cutPoints = try await pipeline.detectCutPoints { [weak self] prog in
                    Task { @MainActor [weak self] in
                        self?.progress = prog
                    }
                }
                
                // Convert cut points to clips
                let duration = try await asset.load(.duration)
                var clips: [VideoClip] = []
                
                for (index, cutTime) in cutPoints.enumerated() {
                    let endTime: CMTime
                    if index + 1 < cutPoints.count {
                        endTime = cutPoints[index + 1]
                    } else {
                        endTime = duration
                    }
                    let range = CMTimeRange(start: cutTime, end: endTime)
                    let clip = VideoClip(number: index + 1, timeRange: range)
                    clips.append(clip)
                }
                
                if !Task.isCancelled {
                    self.detectedClips = clips
                    self.isDetecting = false
                }
            } catch is CancellationError {
                self.isDetecting = false
            } catch {
                self.error = error
                self.isDetecting = false
            }
        }
        
        await detectionTask?.value
    }
    
    func cancel() {
        detectionTask?.cancel()
        isDetecting = false
    }
}
