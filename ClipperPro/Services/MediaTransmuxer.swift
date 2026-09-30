import Foundation
import AVFoundation

/// Handles container remuxing for formats not natively supported by AVFoundation (like .mkv, .webm, .avi).
/// Uses lossless stream copy (`-c copy`) so no video re-encoding occurs, processing 1.5+ hour videos in 2–5 seconds.
/// Caches prepared streams in ~/Documents/Clipper Pro/Cache/ for instant subsequent opens.
actor MediaTransmuxer {
    
    static let shared = MediaTransmuxer()
    
    /// Finds the path to the ffmpeg executable.
    static var ffmpegPath: String? {
        // 1. Inside App bundle Resources
        if let bundlePath = Bundle.main.path(forResource: "ffmpeg", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }
        
        let execPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/ffmpeg").path
        if FileManager.default.isExecutableFile(atPath: execPath) {
            return execPath
        }
        
        // 2. Known local locations
        let fallbackPaths = [
            "/Users/nimishnaman/Documents/Clipper pro/ClipperPro/Resources/ffmpeg",
            "/Users/nimishnaman/Documents/yt dlp/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        
        for path in fallbackPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    /// Prepares a video URL for native AVFoundation decoding and Apple Silicon Media Engine processing.
    /// If the container is natively supported (.mp4, .mov, .m4v), returns the original URL.
    /// If it is .mkv or unsupported, remuxes it to an optimized MP4 container via stream copy.
    func prepareVideoURL(
        for url: URL,
        onProgress: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        // Check if AVFoundation can already read video tracks directly
        let asset = AVURLAsset(url: url)
        if let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty {
            return url
        }
        
        // If not natively readable or format is MKV/WEBM/AVI, remux to MP4
        guard let ffmpeg = Self.ffmpegPath else {
            throw TransmuxError.ffmpegNotFound
        }
        
        let cacheDir = ProjectStore.cacheDirectory
        let safeName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .prefix(50)
        let outputURL = cacheDir.appendingPathComponent("\(safeName).mp4")
        
        // Instant Cache Hit Check
        if FileManager.default.fileExists(atPath: outputURL.path) {
            let cachedAsset = AVURLAsset(url: outputURL)
            if let testTracks = try? await cachedAsset.loadTracks(withMediaType: .video), !testTracks.isEmpty {
                return outputURL
            }
        }
        
        onProgress("Remuxing container for Apple Silicon Media Engine...")
        
        // Attempt 1: Ultra-fast lossless stream copy (-c copy -tag:v hvc1)
        do {
            try await runFFmpeg(
                executable: ffmpeg,
                arguments: [
                    "-y",
                    "-i", url.path,
                    "-map", "0:v:0",
                    "-map", "0:a:0?",
                    "-c", "copy",
                    "-tag:v", "hvc1",
                    "-movflags", "+faststart",
                    outputURL.path
                ]
            )
            
            // Verify remuxed asset is readable
            let remuxedAsset = AVURLAsset(url: outputURL)
            let testTracks = try await remuxedAsset.loadTracks(withMediaType: .video)
            if !testTracks.isEmpty {
                return outputURL
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        // Attempt 2: Lossless video copy + AAC audio conversion
        onProgress("Optimizing audio track for QuickTime & AVFoundation...")
        do {
            try await runFFmpeg(
                executable: ffmpeg,
                arguments: [
                    "-y",
                    "-i", url.path,
                    "-map", "0:v:0",
                    "-map", "0:a:0?",
                    "-c:v", "copy",
                    "-c:a", "aac",
                    "-b:a", "256k",
                    "-tag:v", "hvc1",
                    "-movflags", "+faststart",
                    outputURL.path
                ]
            )
            
            let remuxedAsset = AVURLAsset(url: outputURL)
            let testTracks = try await remuxedAsset.loadTracks(withMediaType: .video)
            if !testTracks.isEmpty {
                return outputURL
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw TransmuxError.remuxFailed(error.localizedDescription)
        }
        
        return outputURL
    }
    
    private func runFFmpeg(executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            // Log level error ensures stderr is not flooded with thousands of frame status lines
            process.arguments = ["-loglevel", "error"] + arguments
            
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            
            // Drain stderr in real time so the pipe buffer never fills up and deadlocks
            final class StderrBuffer: @unchecked Sendable {
                private let lock = NSLock()
                private var data = Data()
                func append(_ chunk: Data) {
                    lock.lock()
                    defer { lock.unlock() }
                    data.append(chunk)
                }
                var message: String {
                    lock.lock()
                    defer { lock.unlock() }
                    return String(data: data, encoding: .utf8) ?? ""
                }
            }
            let buffer = StderrBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let available = handle.availableData
                if !available.isEmpty {
                    buffer.append(available)
                }
            }
            
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                buffer.append(remaining)
                
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let msg = buffer.message.isEmpty ? "FFmpeg exited with code \(proc.terminationStatus)" : buffer.message
                    continuation.resume(throwing: TransmuxError.remuxFailed(msg))
                }
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    enum TransmuxError: LocalizedError {
        case ffmpegNotFound
        case remuxFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "Media engine utility (ffmpeg) not found. Please install ffmpeg."
            case .remuxFailed(let msg):
                return "Failed to convert container format: \(msg)"
            }
        }
    }
}
