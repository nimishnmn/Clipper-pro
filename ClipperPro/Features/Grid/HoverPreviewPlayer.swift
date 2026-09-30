import SwiftUI
import AVFoundation
import AVKit

/// Inline AVPlayer preview that plays a specific CMTimeRange of a video.
struct HoverPreviewPlayer: NSViewRepresentable {
    let asset: AVURLAsset
    let timeRange: CMTimeRange
    
    func makeNSView(context: Context) -> PreviewPlayerView {
        let view = PreviewPlayerView()
        view.setup(asset: asset, timeRange: timeRange)
        return view
    }
    
    func updateNSView(_ nsView: PreviewPlayerView, context: Context) {
        // No update needed for static setup
    }
    
    static func dismantleNSView(_ nsView: PreviewPlayerView, coordinator: ()) {
        nsView.cleanup()
    }
}

final class PreviewPlayerView: NSView {
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: NSObjectProtocol?
    
    private var targetTimeRange: CMTimeRange = .invalid
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    // Ignore all mouse clicks so SwiftUI onTapGesture on the parent clip card receives them
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
    
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }
    
    func setup(asset: AVURLAsset, timeRange: CMTimeRange) {
        cleanup()
        self.targetTimeRange = timeRange
        
        let item = AVPlayerItem(asset: asset)
        // Strictly bound hardware decoding to the clip end: zero frames overshoot into next scene
        let endTime = CMTimeRangeGetEnd(timeRange)
        item.forwardPlaybackEndTime = endTime
        
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .pause
        self.player = player
        
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        self.playerLayer = layer
        
        // Loop within the clip's exact time range
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, let player = self.player else { return }
            player.pause()
            player.seek(to: self.targetTimeRange.start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                if finished {
                    self?.player?.play()
                }
            }
        }
        
        // Cue to clip start with zero tolerance (exact frame) then play
        player.seek(to: timeRange.start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            if finished {
                self?.player?.play()
            }
        }
    }
    
    func cleanup() {
        player?.pause()
        if let obs = loopObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        playerLayer?.removeFromSuperlayer()
        player = nil
        playerLayer = nil
        loopObserver = nil
    }
}
