import Foundation
import AVFoundation
import AppKit

actor ThumbnailService {
    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator
    private var cache: [UUID: NSImage] = [:]
    
    init(asset: AVURLAsset) {
        self.asset = asset
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        self.generator = gen
    }
    
    func thumbnail(for clip: VideoClip) -> NSImage? {
        return cache[clip.id]
    }
    
    /// Generate or re-generate thumbnail for a single clip at its exact first frame (In-Point).
    func generateSingle(clip: VideoClip) async -> NSImage? {
        let inTime = clip.timeRange.start
        do {
            let result = try await generator.image(at: inTime)
            let image = NSImage(cgImage: result.image, size: .zero)
            store(image: image, for: clip.id)
            return image
        } catch {
            return nil
        }
    }
    
    /// Generate thumbnails for all clips concurrently and call back on each completion.
    /// Each thumbnail captures the exact first frame of the cut.
    func generateAll(
        clips: [VideoClip],
        progress: @Sendable @escaping (UUID, NSImage) -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for clip in clips {
                group.addTask { [weak self] in
                    guard let self else { return }
                    let inTime = clip.timeRange.start
                    do {
                        let result = try await self.generator.image(at: inTime)
                        let image = NSImage(cgImage: result.image, size: .zero)
                        await self.store(image: image, for: clip.id)
                        progress(clip.id, image)
                    } catch {
                        // Thumbnail generation failed — placeholder used
                    }
                }
            }
        }
    }
    
    private func store(image: NSImage, for id: UUID) {
        cache[id] = image
    }
    
    func clearCache() {
        cache.removeAll()
    }
}
