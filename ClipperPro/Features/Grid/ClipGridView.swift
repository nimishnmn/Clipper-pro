import SwiftUI
import AVFoundation

struct ClipGridView: View {
    @EnvironmentObject var appState: AppState
    
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 14)]
    
    var body: some View {
        let playableURL = appState.workingURL ?? appState.sourceURL
        let asset: AVURLAsset? = playableURL.map { AVURLAsset(url: $0) }
        
        ZStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(appState.clips) { clip in
                        ClipCell(
                            clip: clip,
                            asset: asset,
                            thumbnail: appState.thumbnails[clip.id],
                            isSelected: appState.isSelected(clip.id),
                            isMergeSelected: appState.isMergeSelected(clip.id),
                            cellIndex: clip.number - 1,
                            aspectRatio: appState.videoAspectRatio,
                            isMergeModeActive: appState.isMergeModeActive,
                            onTap: { id, isShift in
                                if isShift {
                                    appState.toggleMergeSelection(for: id)
                                } else {
                                    appState.toggleSelection(for: id)
                                }
                            },
                            onEdit: { clipToEdit in
                                appState.editingClip = clipToEdit
                            },
                            onFrameChange: { frame in
                                appState.selectionManager.registerCellFrame(frame, for: clip.id)
                            }
                        )
                    }
                }
                .padding(18)
                .padding(.bottom, appState.canMerge ? 70 : 0)
            }
            .coordinateSpace(name: "ClipGrid")
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .named("ClipGrid"))
                    .onChanged { value in
                        if !appState.selectionManager.isDragging {
                            appState.selectionManager.dragBegan(at: value.startLocation)
                        }
                        appState.selectionManager.dragChanged(to: value.location)
                    }
                    .onEnded { _ in
                        appState.selectionManager.dragEnded()
                    }
            )
            
            // Rubber-band drag rectangle overlay
            if appState.selectionManager.isDragging {
                RubberBandOverlay(rect: appState.selectionManager.dragRect)
            }
            
            // Floating Merge Control Bar for Mouse Users
            if appState.canMerge {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.red)
                        
                        Text("\(appState.mergeTargetCount) clips selected to merge")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        
                        Button {
                            appState.mergeSelectedClips()
                        } label: {
                            HStack(spacing: 6) {
                                Text("Merge Clips")
                                    .fontWeight(.bold)
                                Text("Space")
                                    .font(.system(size: 10, weight: .heavy))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color.white.opacity(0.25))
                                    )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.regular)
                        
                        Button {
                            appState.clearMergeSelection()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(5)
                                .background(Circle().fill(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help("Clear merge selection")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.88))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.red.opacity(0.7), lineWidth: 1.5)
                            )
                            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                    )
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.canMerge)
            }
            
            // Hidden Space key shortcut button guaranteeing keyboard capture
            Button("") {
                if appState.canMerge {
                    appState.mergeSelectedClips()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .sheet(item: $appState.editingClip) { clip in
            if let playableURL = appState.workingURL ?? appState.sourceURL,
               let info = appState.sourceInfo {
                ClipEditorView(
                    clip: clip,
                    videoURL: playableURL,
                    totalDuration: info.duration,
                    frameRate: info.frameRate,
                    onSave: { newRange in
                        appState.updateClip(id: clip.id, newRange: newRange)
                    }
                )
            }
        }
        .onKeyPress(.space) {
            if appState.canMerge {
                appState.mergeSelectedClips()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            if !appState.mergeSelectedIDs.isEmpty {
                appState.clearMergeSelection()
                return .handled
            } else if !appState.selectedIDs.isEmpty {
                appState.clearSelection()
                return .handled
            }
            return .ignored
        }
    }
}

struct RubberBandOverlay: View {
    let rect: CGRect
    
    var body: some View {
        GeometryReader { _ in
            Rectangle()
                .fill(Color.blue.opacity(0.12))
                .overlay(
                    Rectangle()
                        .strokeBorder(Color.blue.opacity(0.65), lineWidth: 1.5)
                )
                .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                .offset(x: rect.minX, y: rect.minY)
        }
        .allowsHitTesting(false)
    }
}
