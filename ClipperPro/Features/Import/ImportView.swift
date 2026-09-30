import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDraggingOver = false
    @State private var recentProjects: [ClipperProject] = []
    
    private let acceptedTypes: [UTType] = [
        .mpeg4Movie, .quickTimeMovie, .movie, .video,
        UTType(filenameExtension: "mkv") ?? .video,
        UTType(filenameExtension: "webm") ?? .video,
        UTType(filenameExtension: "avi") ?? .video,
        UTType(filenameExtension: "m4v") ?? .video
    ]
    
    var body: some View {
        ZStack {
            // Background
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 28) {
                    // App icon area
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.blue.opacity(0.8), .purple.opacity(0.8)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 90, height: 90)
                                .shadow(color: .blue.opacity(0.4), radius: 20, y: 8)
                            
                            Image(systemName: "scissors")
                                .font(.system(size: 40, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        
                        Text("Clipper Pro")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        
                        Text("GPU-accelerated scene detection & export")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)
                    
                    // Drop zone
                    DropZone(isDraggingOver: isDraggingOver) {
                        openFilePicker()
                    }
                    .onDrop(
                        of: acceptedTypes.map(\.identifier).map(UTType.init).compactMap { $0 },
                        isTargeted: $isDraggingOver
                    ) { providers in
                        handleDrop(providers: providers)
                    }
                    
                    // Supported formats note
                    Text("Supports MP4 · MKV · MOV · WebM · AVI")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    // Recent Projects Section
                    if !recentProjects.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Recent Projects", systemImage: "clock.arrow.circlepath")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            
                            VStack(spacing: 8) {
                                ForEach(recentProjects) { proj in
                                    RecentProjectRow(project: proj) {
                                        Task {
                                            await appState.loadRecentProject(proj)
                                        }
                                    } onDelete: {
                                        Task {
                                            await ProjectStore.shared.deleteProject(proj)
                                            recentProjects = await ProjectStore.shared.listRecentProjects()
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: 520)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .task {
            recentProjects = await ProjectStore.shared.listRecentProjects()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a video file to analyze"
        panel.prompt = "Open Video"
        panel.allowedContentTypes = acceptedTypes
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            await appState.loadVideo(url: url)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    await appState.loadVideo(url: url)
                }
            }
            return true
        }
        return false
    }
}

struct DropZone: View {
    let isDraggingOver: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 16) {
                Image(systemName: isDraggingOver ? "arrow.down.circle.fill" : "arrow.down.doc")
                    .font(.system(size: 36))
                    .foregroundStyle(isDraggingOver ? .blue : .secondary)
                    .scaleEffect(isDraggingOver ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3), value: isDraggingOver)
                
                VStack(spacing: 4) {
                    Text(isDraggingOver ? "Release to Open" : "Drop a Video Here")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isDraggingOver ? .blue : .primary)
                    
                    Text("or click to browse files")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 480)
            .frame(height: 200)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isDraggingOver ? Color.blue : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 2, dash: isDraggingOver ? [] : [8, 6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(isDraggingOver ? Color.blue.opacity(0.08) : Color.clear)
                    )
                    .animation(.easeInOut(duration: 0.2), value: isDraggingOver)
            }
        }
        .buttonStyle(.plain)
    }
}

struct RecentProjectRow: View {
    let project: ClipperProject
    let onSelect: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.12))
                )
            
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(project.projectName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text("\(project.clips.count) clips")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(.secondary)
                }
                
                HStack(spacing: 8) {
                    Text(project.formattedDate)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    
                    Text((project.sourceVideoPath as NSString).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .help("Delete project")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.secondary.opacity(0.1) : Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            onSelect()
        }
    }
}
