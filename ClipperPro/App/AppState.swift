import Foundation
import AVFoundation
import SwiftUI

/// Central application state shared across all views.
@MainActor
final class AppState: ObservableObject {
    
    // MARK: - Source Video
    /// Display URL shown to user (original filename e.g. Kaijuu.mkv)
    @Published var sourceURL: URL?
    /// Working decodable URL (remuxed MP4 if input was MKV/unsupported container)
    @Published var workingURL: URL?
    @Published var sourceInfo: SourceVideoInfo?
    
    // MARK: - Transmuxing / Preparation State
    @Published var isPreparingMedia = false
    @Published var preparationMessage = ""
    
    // MARK: - Detection
    @Published var config = DetectionConfig.default
    @Published var clips: [VideoClip] = []
    @Published var isDetecting = false
    @Published var detectionProgress: DetectionProgress?
    @Published var detectionError: Error?
    
    // MARK: - Selection State (Single source of truth)
    @Published var selectedIDs: Set<UUID> = []
    /// Clips marked for merge (outlined in red)
    @Published var mergeSelectedIDs: Set<UUID> = []
    /// Pure mouse mode toggle for selecting clips to merge
    @Published var isMergeModeActive: Bool = false
    
    // MARK: - Thumbnails
    var thumbnailService: ThumbnailService?
    @Published var thumbnails: [UUID: NSImage] = [:]
    
    // MARK: - Export
    @Published var exportSettings = ExportSettings()
    @Published var isExporting = false
    @Published var exportProgress: ExportProgress?
    @Published var showExportSettings = false
    
    // MARK: - Dynamic Video Aspect Ratio
    var videoAspectRatio: CGFloat {
        guard let info = sourceInfo, info.naturalSize.height > 0 else {
            return 16.0 / 9.0
        }
        return info.naturalSize.width / info.naturalSize.height
    }
    
    // MARK: - UI State & Editing
    @Published var showDropZone = true
    @Published var editingClip: VideoClip?
    
    let selectionManager = SelectionManager()
    private var detectionTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    
    init() {
        selectionManager.onSelectionChanged = { [weak self] newIDs in
            self?.selectedIDs = newIDs
        }
    }
    
    // MARK: - Selection Helpers
    
    func isSelected(_ id: UUID) -> Bool {
        selectedIDs.contains(id)
    }
    
    func isMergeSelected(_ id: UUID) -> Bool {
        mergeSelectedIDs.contains(id)
    }
    
    func toggleSelection(for id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        selectionManager.selectedIDs = selectedIDs
    }
    
    func toggleMergeSelection(for id: UUID) {
        if mergeSelectedIDs.contains(id) {
            mergeSelectedIDs.remove(id)
        } else {
            mergeSelectedIDs.insert(id)
        }
    }
    
    func selectAll() {
        selectedIDs = Set(clips.map(\.id))
        selectionManager.selectedIDs = selectedIDs
    }
    
    func clearSelection() {
        selectedIDs.removeAll()
        mergeSelectedIDs.removeAll()
        selectionManager.selectedIDs = selectedIDs
    }
    
    func clearMergeSelection() {
        mergeSelectedIDs.removeAll()
    }
    
    var canMerge: Bool {
        mergeSelectedIDs.count >= 2 || (mergeSelectedIDs.isEmpty && selectedIDs.count >= 2)
    }
    
    var mergeTargetCount: Int {
        !mergeSelectedIDs.isEmpty ? mergeSelectedIDs.count : selectedIDs.count
    }
    
    // MARK: - Clip Merging
    
    func mergeSelectedClips() {
        let targetIDs = !mergeSelectedIDs.isEmpty ? mergeSelectedIDs : selectedIDs
        guard targetIDs.count >= 2 else { return }
        
        let clipsToMerge = clips.filter { targetIDs.contains($0.id) }
        guard clipsToMerge.count >= 2 else { return }
        
        // Sort chronologically by start time
        let sortedClips = clipsToMerge.sorted { $0.timeRange.start < $1.timeRange.start }
        guard let earliest = sortedClips.first, let latest = sortedClips.last else { return }
        
        let mergedStart = earliest.timeRange.start
        let mergedEnd = latest.timeRange.end
        guard mergedEnd > mergedStart else { return }
        let mergedRange = CMTimeRange(start: mergedStart, end: mergedEnd)
        
        // Find position of the earliest clip in the array
        guard let insertIdx = clips.firstIndex(where: { $0.id == earliest.id }) else { return }
        
        // Filter out all clips that are inside [mergedStart, mergedEnd] or part of targetIDs
        var remainingClips = clips.filter { clip in
            if targetIDs.contains(clip.id) { return false }
            if clip.timeRange.start >= mergedStart && clip.timeRange.end <= mergedEnd {
                return false
            }
            return true
        }
        
        // Create new merged clip
        let mergedClip = VideoClip(
            number: earliest.number,
            timeRange: mergedRange
        )
        
        let safeInsertIdx = min(insertIdx, remainingClips.count)
        remainingClips.insert(mergedClip, at: safeInsertIdx)
        
        // Renumber all clips sequentially 1...N
        for i in 0..<remainingClips.count {
            remainingClips[i].number = i + 1
        }
        
        self.clips = remainingClips
        
        // Reuse thumbnail from earliest clip immediately
        if let thumb = thumbnails[earliest.id] {
            thumbnails[mergedClip.id] = thumb
        }
        
        // Clean up obsolete thumbnails
        for oldClip in sortedClips {
            if oldClip.id != mergedClip.id {
                thumbnails.removeValue(forKey: oldClip.id)
            }
        }
        
        // Update selection state: clear merge selection, select the merged clip
        mergeSelectedIDs.removeAll()
        selectedIDs.subtract(targetIDs)
        selectedIDs.insert(mergedClip.id)
        selectionManager.selectedIDs = selectedIDs
        
        // Asynchronously regenerate high-fidelity thumbnail for the merged clip
        if let service = thumbnailService {
            Task {
                if let newThumb = await service.generateSingle(clip: mergedClip) {
                    thumbnails[mergedClip.id] = newThumb
                }
            }
        }
        
        // Persist to project
        saveCurrentProject()
    }
    
    // MARK: - Video Loading & Media Engine Transmuxing
    
    func loadVideo(url: URL) async {
        BookmarkService.save(url: url)
        sourceURL = url
        showDropZone = false
        clips = []
        thumbnails = [:]
        clearSelection()
        detectionError = nil
        
        isPreparingMedia = true
        preparationMessage = "Checking video container..."
        
        var effectiveURL = url
        do {
            // Check if container needs remuxing for Apple Silicon Media Engine
            effectiveURL = try await MediaTransmuxer.shared.prepareVideoURL(for: url) { [weak self] msg in
                Task { @MainActor [weak self] in
                    self?.preparationMessage = msg
                }
            }
            workingURL = effectiveURL
        } catch {
            isPreparingMedia = false
            detectionError = error
            return
        }
        
        isPreparingMedia = false
        
        // Read metadata from playable stream
        do {
            let info = try await MetadataReader.read(from: effectiveURL)
            sourceInfo = info
            exportSettings.applySourceDefaults(
                size: info.naturalSize,
                fps: info.frameRate,
                bitrate: info.estimatedBitrate
            )
        } catch {
            detectionError = error
            return
        }
        
        await runDetection(url: effectiveURL)
    }
    
    // MARK: - Scene Detection
    
    func runDetection(url: URL) async {
        detectionTask?.cancel()
        isDetecting = true
        detectionProgress = nil
        clips = []
        thumbnails = [:]
        clearSelection()
        detectionError = nil
        
        let currentConfig = config
        let pipeline = SceneDetectorPipeline(asset: AVURLAsset(url: url), config: currentConfig)
        
        detectionTask = Task {
            do {
                let cutPoints = try await pipeline.detectCutPoints { [weak self] prog in
                    Task { @MainActor [weak self] in
                        self?.detectionProgress = prog
                    }
                }
                
                guard !Task.isCancelled else { return }
                
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                var generatedClips: [VideoClip] = []
                
                for (index, cutTime) in cutPoints.enumerated() {
                    let endTime = (index + 1 < cutPoints.count) ? cutPoints[index + 1] : duration
                    let range = CMTimeRange(start: cutTime, end: endTime)
                    let clip = VideoClip(number: index + 1, timeRange: range)
                    generatedClips.append(clip)
                }
                
                self.clips = generatedClips
                self.isDetecting = false
                self.saveCurrentProject()
                
                if !generatedClips.isEmpty {
                    await self.generateThumbnails(url: url, clips: generatedClips)
                }
            } catch is CancellationError {
                self.isDetecting = false
            } catch {
                self.detectionError = error
                self.isDetecting = false
            }
        }
    }
    
    func cancelDetection() {
        detectionTask?.cancel()
        isDetecting = false
    }
    
    func rerunDetection() async {
        guard let url = workingURL ?? sourceURL else { return }
        await runDetection(url: url)
    }
    
    // MARK: - Clip Editing & Trimming
    
    func updateClip(id: UUID, newRange: CMTimeRange) {
        guard let idx = clips.firstIndex(where: { $0.id == id }) else { return }
        var updatedClip = clips[idx]
        updatedClip.timeRange = newRange
        clips[idx] = updatedClip
        
        // Re-generate thumbnail for this adjusted clip
        if let service = thumbnailService {
            Task {
                if let newThumb = await service.generateSingle(clip: updatedClip) {
                    thumbnails[id] = newThumb
                }
            }
        }
        
        // Persist trimmed clip to project
        saveCurrentProject()
    }
    
    // MARK: - Project Persistence & Recents
    
    func saveCurrentProject() {
        guard let srcURL = sourceURL, !clips.isEmpty else { return }
        let projectName = srcURL.deletingPathExtension().lastPathComponent
        let working = workingURL
        let currentClips = clips
        let currentConfig = config
        Task.detached(priority: .utility) {
            try? await ProjectStore.shared.saveProject(
                name: projectName,
                sourceURL: srcURL,
                workingURL: working,
                clips: currentClips,
                config: currentConfig
            )
        }
    }
    
    func loadRecentProject(_ project: ClipperProject) async {
        let sourceURL = URL(fileURLWithPath: project.sourceVideoPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            detectionError = NSError(
                domain: "ClipperPro",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Source video file not found at: \(project.sourceVideoPath)"]
            )
            return
        }
        
        BookmarkService.save(url: sourceURL)
        self.sourceURL = sourceURL
        self.showDropZone = false
        self.clips = []
        self.thumbnails = [:]
        self.clearSelection()
        self.detectionError = nil
        
        let working: URL
        if let wPath = project.workingVideoPath, FileManager.default.fileExists(atPath: wPath) {
            working = URL(fileURLWithPath: wPath)
        } else {
            isPreparingMedia = true
            preparationMessage = "Preparing video..."
            do {
                working = try await MediaTransmuxer.shared.prepareVideoURL(for: sourceURL) { [weak self] msg in
                    Task { @MainActor [weak self] in
                        self?.preparationMessage = msg
                    }
                }
            } catch {
                isPreparingMedia = false
                detectionError = error
                return
            }
            isPreparingMedia = false
        }
        
        self.workingURL = working
        
        do {
            let info = try await MetadataReader.read(from: working)
            self.sourceInfo = info
            self.exportSettings.applySourceDefaults(
                size: info.naturalSize,
                fps: info.frameRate,
                bitrate: info.estimatedBitrate
            )
        } catch {
            detectionError = error
            return
        }
        
        // Restore config
        self.config.setSensitivityPercent(Double(project.sensitivityPercent))
        if let mode = DetectionSpeedMode(rawValue: project.speedMode) {
            self.config.speedMode = mode
        }
        self.config.minClipDuration = project.minClipDuration
        
        // Restore clips
        let restoredClips = project.clips.map { $0.toVideoClip() }
        self.clips = restoredClips
        
        // Generate thumbnails
        if !restoredClips.isEmpty {
            await generateThumbnails(url: working, clips: restoredClips)
        }
    }
    
    // MARK: - Sensitivity Configuration
    
    func setSensitivityPreset(_ preset: SensitivityPreset) {
        config.applyPreset(preset)
        Task { await rerunDetection() }
    }
    
    func setSensitivityPercent(_ percent: Double) {
        config.setSensitivityPercent(percent)
    }
    
    func setSpeedMode(_ mode: DetectionSpeedMode) {
        config.speedMode = mode
    }
    
    // MARK: - Thumbnails
    
    private func generateThumbnails(url: URL, clips: [VideoClip]) async {
        let asset = AVURLAsset(url: url)
        let service = ThumbnailService(asset: asset)
        thumbnailService = service
        
        await service.generateAll(clips: clips) { [weak self] id, image in
            Task { @MainActor [weak self] in
                self?.thumbnails[id] = image
            }
        }
    }
    
    // MARK: - Reset
    
    func resetToDropZone() {
        sourceURL = nil
        workingURL = nil
        sourceInfo = nil
        clips = []
        thumbnails = [:]
        clearSelection()
        detectionProgress = nil
        detectionError = nil
        showDropZone = true
        isPreparingMedia = false
        detectionTask?.cancel()
        thumbnailTask?.cancel()
    }
}
