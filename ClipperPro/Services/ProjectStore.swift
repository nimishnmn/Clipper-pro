import Foundation
import CoreMedia

/// Serializable representation of a trimmed video clip for project files.
struct SavedClip: Codable, Identifiable, Sendable {
    let id: UUID
    let number: Int
    let startSeconds: Double
    let durationSeconds: Double
    // Exact native CoreMedia timebase fields to guarantee 0 drift across app restarts
    var startValue: Int64?
    var startTimescale: Int32?
    var durationValue: Int64?
    var durationTimescale: Int32?
    
    init(from clip: VideoClip) {
        self.id = clip.id
        self.number = clip.number
        self.startSeconds = clip.timeRange.start.seconds
        self.durationSeconds = clip.timeRange.duration.seconds
        self.startValue = clip.timeRange.start.value
        self.startTimescale = clip.timeRange.start.timescale
        self.durationValue = clip.timeRange.duration.value
        self.durationTimescale = clip.timeRange.duration.timescale
    }
    
    func toVideoClip() -> VideoClip {
        let start: CMTime
        if let sv = startValue, let st = startTimescale, st > 0 {
            start = CMTime(value: sv, timescale: st)
        } else {
            start = CMTime(seconds: startSeconds, preferredTimescale: 60000)
        }
        
        let duration: CMTime
        if let dv = durationValue, let dt = durationTimescale, dt > 0 {
            duration = CMTime(value: dv, timescale: dt)
        } else {
            duration = CMTime(seconds: durationSeconds, preferredTimescale: 60000)
        }
        
        return VideoClip(id: id, number: number, timeRange: CMTimeRange(start: start, duration: duration))
    }
}

/// Project document saving state, clips, video path, and detection parameters.
struct ClipperProject: Codable, Identifiable, Sendable {
    var id: UUID
    var projectName: String
    var sourceVideoPath: String
    var workingVideoPath: String?
    var lastModified: Date
    var clips: [SavedClip]
    var sensitivityPercent: Int
    var speedMode: String
    var minClipDuration: Double
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: lastModified)
    }
}

/// Manages project persistence in ~/Documents/Clipper Pro/Projects/
actor ProjectStore {
    static let shared = ProjectStore()
    
    static var projectsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Clipper Pro/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    static var cacheDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Clipper Pro/Cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    func saveProject(
        name: String,
        sourceURL: URL,
        workingURL: URL?,
        clips: [VideoClip],
        config: DetectionConfig
    ) throws {
        let savedClips = clips.map { SavedClip(from: $0) }
        let project = ClipperProject(
            id: UUID(),
            projectName: name,
            sourceVideoPath: sourceURL.path,
            workingVideoPath: workingURL?.path,
            lastModified: Date(),
            clips: savedClips,
            sensitivityPercent: config.sensitivityPercent,
            speedMode: config.speedMode.rawValue,
            minClipDuration: config.minClipDuration
        )
        
        let safeName = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = Self.projectsDirectory.appendingPathComponent("\(safeName).clipperproj")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        try data.write(to: fileURL, options: .atomic)
    }
    
    func listRecentProjects() -> [ClipperProject] {
        let dir = Self.projectsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else {
            return []
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        var projects: [ClipperProject] = []
        for file in files where file.pathExtension == "clipperproj" {
            if let data = try? Data(contentsOf: file),
               let project = try? decoder.decode(ClipperProject.self, from: data) {
                projects.append(project)
            }
        }
        
        return projects.sorted { $0.lastModified > $1.lastModified }
    }
    
    func deleteProject(_ project: ClipperProject) {
        let safeName = project.projectName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = Self.projectsDirectory.appendingPathComponent("\(safeName).clipperproj")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
