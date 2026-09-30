import Foundation
import CoreMedia
import CoreGraphics
import AppKit

/// Represents a single detected scene clip from a source video.
struct VideoClip: Identifiable, Sendable {
    let id: UUID
    /// 1-based sequential number (display name)
    var number: Int
    var timeRange: CMTimeRange
    var thumbnail: NSImage?
    
    var displayName: String { String(number) }
    
    var durationSeconds: Double {
        timeRange.duration.seconds
    }
    
    var durationString: String {
        let d = durationSeconds
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        let frac = Int((d - Double(Int(d))) * 10)
        if mins > 0 {
            return String(format: "%d:%02d.%d", mins, secs, frac)
        } else {
            return String(format: "%d.%ds", secs, frac)
        }
    }
    
    init(id: UUID = UUID(), number: Int, timeRange: CMTimeRange) {
        self.id = id
        self.number = number
        self.timeRange = timeRange
        self.thumbnail = nil
    }
}
