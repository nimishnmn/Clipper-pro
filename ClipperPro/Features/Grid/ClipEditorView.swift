import SwiftUI
import AVFoundation
import AVKit

/// Mini editor window to fine-tune in/out points, trim, and preview a clip directly from the source video.
struct ClipEditorView: View {
    let clip: VideoClip
    let videoURL: URL
    let totalDuration: CMTime
    let frameRate: Float
    let onSave: (CMTimeRange) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var startSeconds: Double
    @State private var endSeconds: Double
    @State private var currentTime: Double
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    
    var frameDuration: Double {
        1.0 / Double(max(frameRate, 1.0))
    }
    
    init(
        clip: VideoClip,
        videoURL: URL,
        totalDuration: CMTime,
        frameRate: Float = 30.0,
        onSave: @escaping (CMTimeRange) -> Void
    ) {
        self.clip = clip
        self.videoURL = videoURL
        self.totalDuration = totalDuration
        self.frameRate = frameRate
        self.onSave = onSave
        
        let start = clip.timeRange.start.seconds
        let end = CMTimeRangeGetEnd(clip.timeRange).seconds
        _startSeconds = State(initialValue: max(0, start))
        _endSeconds = State(initialValue: min(totalDuration.seconds, end))
        _currentTime = State(initialValue: max(0, start))
    }
    
    var trimmedDuration: Double {
        max(0, endSeconds - startSeconds)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trim & Refine — Clip \(clip.number)")
                        .font(.title3.weight(.bold))
                    Text("Adjust in/out cut points with frame precision")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Divider()
            
            // Video Player
            ZStack {
                Color.black
                if let player = player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 340)
            
            // Controls & Timeline
            VStack(spacing: 16) {
                // Play / Pause and scrub display
                HStack(spacing: 16) {
                    Button {
                        togglePlay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    
                    Text(formatTime(currentTime))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    
                    Spacer()
                    
                    Button("Play Selection") {
                        playSelection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Text("Duration: " + String(format: "%.2fs", trimmedDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                
                // Scrubber Bar
                VStack(spacing: 6) {
                    Slider(
                        value: $currentTime,
                        in: max(0, startSeconds - 10)...min(totalDuration.seconds, endSeconds + 10),
                        onEditingChanged: { editing in
                            if !editing {
                                seek(to: currentTime)
                            }
                        }
                    )
                    .accentColor(.blue)
                    .padding(.horizontal, 20)
                }
                
                // Precision In / Out Setters
                HStack(spacing: 20) {
                    // In-point box
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Start (In-Point)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 4) {
                            Button("-1F") {
                                startSeconds = max(0, startSeconds - frameDuration)
                                seek(to: startSeconds)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Previous frame")
                            
                            Button("-0.1s") {
                                startSeconds = max(0, startSeconds - 0.1)
                                seek(to: startSeconds)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            
                            Text(formatTime(startSeconds))
                                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                                .frame(minWidth: 74)
                            
                            Button("+0.1s") {
                                if startSeconds + 0.1 < endSeconds {
                                    startSeconds += 0.1
                                    seek(to: startSeconds)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            
                            Button("+1F") {
                                if startSeconds + frameDuration < endSeconds {
                                    startSeconds += frameDuration
                                    seek(to: startSeconds)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Next frame")
                            
                            Button("Set to Now") {
                                if currentTime < endSeconds {
                                    startSeconds = currentTime
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    
                    Divider().frame(height: 40)
                    
                    // Out-point box
                    VStack(alignment: .leading, spacing: 6) {
                        Text("End (Out-Point)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 4) {
                            Button("-1F") {
                                if endSeconds - frameDuration > startSeconds {
                                    endSeconds -= frameDuration
                                    seek(to: endSeconds)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Previous frame")
                            
                            Button("-0.1s") {
                                if endSeconds - 0.1 > startSeconds {
                                    endSeconds -= 0.1
                                    seek(to: endSeconds)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            
                            Text(formatTime(endSeconds))
                                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                                .frame(minWidth: 74)
                            
                            Button("+0.1s") {
                                endSeconds = min(totalDuration.seconds, endSeconds + 0.1)
                                seek(to: endSeconds)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            
                            Button("+1F") {
                                if endSeconds + frameDuration <= totalDuration.seconds {
                                    endSeconds += frameDuration
                                    seek(to: endSeconds)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Next frame")
                            
                            Button("Set to Now") {
                                if currentTime > startSeconds {
                                    endSeconds = currentTime
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(.horizontal, 20)
                
                Divider()
                
                // Footer Save / Cancel
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    
                    Spacer()
                    
                    Button("Save Trimmed Clip") {
                        saveChanges()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 640)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            teardownPlayer()
        }
    }
    
    private func setupPlayer() {
        let item = AVPlayerItem(url: videoURL)
        let timescale = totalDuration.timescale > 0 ? totalDuration.timescale : 60000
        let end = CMTime(seconds: endSeconds, preferredTimescale: timescale)
        item.forwardPlaybackEndTime = end
        
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        self.player = p
        
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            self.isPlaying = false
        }
        
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            self.currentTime = time.seconds
            if self.isPlaying && time.seconds >= self.endSeconds {
                self.player?.pause()
                self.isPlaying = false
            }
        }
        
        seek(to: startSeconds)
    }
    
    private func teardownPlayer() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        player?.pause()
        player = nil
    }
    
    private func seek(to seconds: Double) {
        let timescale = totalDuration.timescale > 0 ? totalDuration.timescale : 60000
        let target = CMTime(seconds: seconds, preferredTimescale: timescale)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            let timescale = totalDuration.timescale > 0 ? totalDuration.timescale : 60000
            let end = CMTime(seconds: endSeconds, preferredTimescale: timescale)
            p.currentItem?.forwardPlaybackEndTime = end
            p.actionAtItemEnd = .pause
            if currentTime >= endSeconds || currentTime < startSeconds {
                seek(to: startSeconds)
            }
            p.play()
            isPlaying = true
        }
    }
    
    private func playSelection() {
        guard let p = player, let item = p.currentItem else { return }
        let timescale = totalDuration.timescale > 0 ? totalDuration.timescale : 60000
        let end = CMTime(seconds: endSeconds, preferredTimescale: timescale)
        item.forwardPlaybackEndTime = end
        p.actionAtItemEnd = .pause
        
        let start = CMTime(seconds: startSeconds, preferredTimescale: timescale)
        p.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak p] finished in
            if finished {
                p?.play()
                self.isPlaying = true
            }
        }
    }
    
    private func saveChanges() {
        let timescale = totalDuration.timescale > 0 ? totalDuration.timescale : 60000
        let start = CMTime(seconds: startSeconds, preferredTimescale: timescale)
        let duration = CMTime(seconds: trimmedDuration, preferredTimescale: timescale)
        let newRange = CMTimeRange(start: start, duration: duration)
        onSave(newRange)
        dismiss()
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 10)
        return String(format: "%02d:%02d.%01d", mins, secs, ms)
    }
}
