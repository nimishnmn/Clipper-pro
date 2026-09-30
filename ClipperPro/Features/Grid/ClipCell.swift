import SwiftUI
import AVFoundation

struct ClipCell: View {
    let clip: VideoClip
    let asset: AVURLAsset?
    let thumbnail: NSImage?
    let isSelected: Bool
    let isMergeSelected: Bool
    let cellIndex: Int
    let aspectRatio: CGFloat
    let isMergeModeActive: Bool
    
    @State private var isHovered = false
    @State private var showPlayer = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var lastClickTime: Date = .distantPast
    
    let onTap: (UUID, Bool) -> Void
    let onEdit: (VideoClip) -> Void
    let onFrameChange: (CGRect) -> Void
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Media Content (No rounded corners, perfectly locked in place)
                mediaContent
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                
                // Dark bottom gradient for text contrast
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
                
                // Top controls (Edit button on hover + Selection indicators)
                HStack {
                    // Trim / Edit button (appears on hover)
                    if isHovered {
                        Button {
                            onEdit(clip)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "scissors")
                                    .font(.caption2.weight(.bold))
                                Text("Trim")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Rectangle()
                                    .fill(Color.black.opacity(0.75))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Fine-tune in/out points for this clip")
                        .transition(.opacity)
                    }
                    
                    Spacer()
                    
                    // Merge selection indicator (Red badge with merge icon)
                    if isMergeSelected {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.system(size: 11, weight: .bold))
                            Text("Merge")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Rectangle()
                                .fill(Color.red)
                        )
                    } else if isSelected {
                        // Regular export selection (Blue checkmark)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white, .blue)
                            .padding(6)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                
                // Info label (Sharp layout, no shift)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.displayName)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(clip.durationString)
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            // Instant selection on click with zero delay (no conflicting count: 2 or long press)
            .onTapGesture {
                let now = Date()
                let isShift = NSEvent.modifierFlags.contains(.shift) || isMergeModeActive
                if !isShift && now.timeIntervalSince(lastClickTime) < 0.32 {
                    onEdit(clip)
                } else {
                    onTap(clip.id, isShift)
                }
                lastClickTime = now
            }
            .contextMenu {
                Button {
                    onEdit(clip)
                } label: {
                    Label("Trim Clip...", systemImage: "scissors")
                }
                Divider()
                Button {
                    onTap(clip.id, true)
                } label: {
                    Label(isMergeSelected ? "Remove from Merge Selection" : "Select for Merge (Red Outline)", systemImage: "arrow.triangle.merge")
                }
                Button {
                    onTap(clip.id, false)
                } label: {
                    Label(isSelected ? "Deselect Clip" : "Select for Export (Blue Outline)", systemImage: "checkmark.circle")
                }
            }
            // Crisp rectangular selection / hover borders without modifying layout box
            .overlay(
                Rectangle()
                    .strokeBorder(borderColor, lineWidth: borderWidth)
                    .allowsHitTesting(false)
            )
            .background(
                Rectangle()
                    .fill(selectionBackground)
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                isHovered = hovering
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(for: .milliseconds(220))
                        guard !Task.isCancelled else { return }
                        showPlayer = true
                    }
                } else {
                    showPlayer = false
                }
            }
            .onAppear {
                onFrameChange(geo.frame(in: .named("ClipGrid")))
            }
            .onChange(of: geo.frame(in: .named("ClipGrid"))) { _, newFrame in
                onFrameChange(newFrame)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
    }
    
    @ViewBuilder
    private var mediaContent: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color(.systemGray).opacity(0.2))
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
            }
            
            if showPlayer, let asset {
                HoverPreviewPlayer(asset: asset, timeRange: clip.timeRange)
            }
        }
        .allowsHitTesting(false)
    }
    
    private var borderColor: Color {
        if isMergeSelected {
            return Color.red
        } else if isSelected {
            return Color.blue
        } else if isHovered {
            return Color.white.opacity(0.6)
        } else {
            return Color.clear
        }
    }
    
    private var borderWidth: CGFloat {
        (isMergeSelected || isSelected) ? 3.0 : 1.5
    }
    
    private var selectionBackground: Color {
        if isMergeSelected {
            return Color.red.opacity(0.18)
        } else if isSelected {
            return Color.blue.opacity(0.12)
        } else {
            return Color.clear
        }
    }
}
