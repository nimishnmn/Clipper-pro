import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

struct ExportProgress: Sendable {
    let clipIndex: Int
    let clipTotal: Int
    let clipName: String
    let clipFraction: Double
    
    var overallFraction: Double {
        guard clipTotal > 0 else { return 0 }
        let base = Double(clipIndex) / Double(clipTotal)
        let step = clipFraction / Double(clipTotal)
        return min(base + step, 1.0)
    }
    
    var statusText: String {
        if clipTotal == 1 {
            return "Exporting \(clipName)..."
        }
        return "Exporting \(clipName) (\(clipIndex + 1) of \(clipTotal))"
    }
}

enum ExportError: LocalizedError {
    case noOutputFolder
    case writerSetupFailed(String)
    case readerSetupFailed(String)
    case encodingFailed(String)
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .noOutputFolder:         return "No output folder selected."
        case .writerSetupFailed(let s): return "Export writer setup failed: \(s)"
        case .readerSetupFailed(let s): return "Export reader setup failed: \(s)"
        case .encodingFailed(let s):    return "Export encoding failed: \(s)"
        case .cancelled:                return "Export was cancelled."
        }
    }
}

actor ExportEngine {
    
    /// Export a set of clips from the source asset to the output folder.
    func exportClips(
        _ clips: [VideoClip],
        from asset: AVURLAsset,
        settings: ExportSettings,
        progress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws {
        guard let baseFolder = settings.outputFolderURL else {
            throw ExportError.noOutputFolder
        }
        
        let destinationFolder: URL
        if settings.createSubfolder {
            let videoName = asset.url.deletingPathExtension().lastPathComponent
            let subfolder = baseFolder.appendingPathComponent(videoName, isDirectory: true)
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
            destinationFolder = subfolder
        } else {
            try FileManager.default.createDirectory(at: baseFolder, withIntermediateDirectories: true)
            destinationFolder = baseFolder
        }
        
        let sortedClips = clips.sorted { $0.number < $1.number }
        
        // Mode 1: Merge all selected clips into a single continuous video
        if settings.mergeMode == .mergedVideo {
            try await exportMergedClips(
                sortedClips,
                from: asset,
                to: destinationFolder,
                settings: settings,
                progress: progress
            )
            return
        }
        
        // Mode 2: Export as separate files
        let total = sortedClips.count
        let maxConcurrency = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            var activeCount = 0
            
            for (index, clip) in sortedClips.enumerated() {
                try Task.checkCancellation()
                
                let outputURL = destinationFolder.appendingPathComponent("\(clip.displayName).mp4")
                
                group.addTask {
                    try await self.exportSingleClip(
                        clip: clip,
                        from: asset,
                        to: outputURL,
                        settings: settings,
                        index: index,
                        total: total,
                        progress: progress
                    )
                }
                
                activeCount += 1
                if activeCount >= maxConcurrency {
                    try await group.next()
                    activeCount -= 1
                }
            }
            
            while activeCount > 0 {
                try await group.next()
                activeCount -= 1
            }
        }
    }
    
    /// Merges all selected clips into a single continuous video file.
    private func exportMergedClips(
        _ clips: [VideoClip],
        from asset: AVURLAsset,
        to folder: URL,
        settings: ExportSettings,
        progress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws {
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.writerSetupFailed("Failed to create composition video track.")
        }
        let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        
        let assetVideoTracks = try await asset.loadTracks(withMediaType: .video)
        let assetAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let srcVideo = assetVideoTracks.first else {
            throw ExportError.readerSetupFailed("No video track found.")
        }
        let srcAudio = assetAudioTracks.first
        
        var insertTime = CMTime.zero
        for clip in clips {
            try compVideoTrack.insertTimeRange(clip.timeRange, of: srcVideo, at: insertTime)
            if let srcAudio, let compAudioTrack {
                try? compAudioTrack.insertTimeRange(clip.timeRange, of: srcAudio, at: insertTime)
            }
            insertTime = CMTimeAdd(insertTime, clip.timeRange.duration)
        }
        
        let outputURL = folder.appendingPathComponent("Merged_Scenes.mp4")
        
        // Export the merged composition
        try await exportFromAsset(
            sourceAsset: composition,
            timeRange: CMTimeRange(start: .zero, duration: insertTime),
            to: outputURL,
            settings: settings,
            clipIndex: 0,
            clipTotal: 1,
            clipName: "Merged Video",
            progress: progress
        )
    }
    
    private func exportSingleClip(
        clip: VideoClip,
        from asset: AVAsset,
        to outputURL: URL,
        settings: ExportSettings,
        index: Int,
        total: Int,
        progress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws {
        try await exportFromAsset(
            sourceAsset: asset,
            timeRange: clip.timeRange,
            to: outputURL,
            settings: settings,
            clipIndex: index,
            clipTotal: total,
            clipName: clip.displayName,
            progress: progress
        )
    }
    
    private func exportFromAsset(
        sourceAsset: AVAsset,
        timeRange: CMTimeRange,
        to outputURL: URL,
        settings: ExportSettings,
        clipIndex: Int,
        clipTotal: Int,
        clipName: String,
        progress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        
        // Always use hardware-accelerated AVAssetWriter for 100% frame-exact cuts (no keyframe snapping)
        try await exportWithAssetWriter(
            from: sourceAsset,
            timeRange: timeRange,
            to: outputURL,
            settings: settings,
            index: clipIndex,
            total: clipTotal,
            name: clipName,
            progress: progress
        )
    }
    
    private func exportWithAssetWriter(
        from asset: AVAsset,
        timeRange: CMTimeRange,
        to outputURL: URL,
        settings: ExportSettings,
        index: Int,
        total: Int,
        name: String,
        progress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ExportError.readerSetupFailed("No video track")
        }
        
        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.readerSetupFailed("Cannot add video output")
        }
        reader.add(videoOutput)
        
        var audioOutput: AVAssetReaderTrackOutput?
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let audioTrack = audioTracks.first {
            let audioOutputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM
            ]
            let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioOutputSettings)
            aOut.alwaysCopiesSampleData = false
            if reader.canAdd(aOut) {
                reader.add(aOut)
                audioOutput = aOut
            }
        }
        
        guard reader.startReading() else {
            throw reader.error ?? ExportError.readerSetupFailed("Reader start failed")
        }
        
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        let targetSize = settings.targetSize
        var compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrate,
            AVVideoExpectedSourceFrameRateKey: settings.targetFPS
        ]
        if settings.codec == .hevc {
            compressionProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        } else {
            compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        
        let videoWriterSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec.avCodecType,
            AVVideoWidthKey: Int(targetSize.width),
            AVVideoHeightKey: Int(targetSize.height),
            AVVideoCompressionPropertiesKey: compressionProps
        ]
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoWriterSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.writerSetupFailed("Cannot add video input")
        }
        writer.add(videoInput)
        
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let audioWriterSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 192_000
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioWriterSettings)
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
            }
        }
        
        guard writer.startWriting() else {
            throw writer.error ?? ExportError.writerSetupFailed("Writer start failed")
        }
        writer.startSession(atSourceTime: timeRange.start)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.clipper.export.\(name)")
            let durationSeconds = timeRange.duration.seconds
            
            var videoFinished = false
            var audioFinished = (audioInput == nil)
            
            func checkFinished() {
                guard videoFinished && audioFinished else { return }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: writer.error ?? ExportError.encodingFailed("Writer finished with status \(writer.status.rawValue)"))
                    }
                }
            }
            
            let endTime = CMTimeRangeGetEnd(timeRange)
            
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
                        guard sampleTime >= timeRange.start else { continue }
                        guard sampleTime < endTime else {
                            videoFinished = true
                            checkFinished()
                            break
                        }
                        let elapsed = CMTimeSubtract(sampleTime, timeRange.start).seconds
                        let fraction = durationSeconds > 0 ? min(max(elapsed / durationSeconds, 0), 1.0) : 0
                        progress(ExportProgress(
                            clipIndex: index,
                            clipTotal: total,
                            clipName: name,
                            clipFraction: fraction
                        ))
                        videoInput.append(sample)
                    } else {
                        videoFinished = true
                        checkFinished()
                        break
                    }
                }
            }
            
            if let audioInput, let audioOutput {
                audioInput.requestMediaDataWhenReady(on: queue) {
                    while audioInput.isReadyForMoreMediaData {
                        if let sample = audioOutput.copyNextSampleBuffer() {
                            let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
                            guard sampleTime >= timeRange.start else { continue }
                            guard sampleTime < endTime else {
                                audioFinished = true
                                checkFinished()
                                break
                            }
                            audioInput.append(sample)
                        } else {
                            audioFinished = true
                            checkFinished()
                            break
                        }
                    }
                }
            }
        }
    }
}
