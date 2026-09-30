import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            if appState.showDropZone {
                ImportView()
            } else {
                MainWorkspaceView()
            }
        }
        .sheet(isPresented: $appState.showExportSettings) {
            ExportSettingsView()
                .environmentObject(appState)
        }
        .animation(.easeInOut(duration: 0.25), value: appState.showDropZone)
    }
}

struct MainWorkspaceView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar()
            Divider()
            
            ZStack {
                if appState.isPreparingMedia {
                    MediaPreparationProgressView()
                } else if appState.isDetecting {
                    SceneDetectionProgressView()
                } else if appState.clips.isEmpty {
                    NoClipsView()
                } else {
                    ClipGridView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct WorkspaceToolbar: View {
    @EnvironmentObject var appState: AppState
    @State private var showSensitivityPopover = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Back button
            Button {
                appState.resetToDropZone()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Back to drop zone")
            
            // Video title & format badges
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.sourceURL?.lastPathComponent ?? "")
                    .font(.headline)
                    .lineLimit(1)
                
                if let info = appState.sourceInfo {
                    HStack(spacing: 6) {
                        Text("\(info.resolutionString) · \(info.fpsString) · \(info.durationString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text("Apple Silicon HW Decoded")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.12)))
                    }
                }
            }
            
            Spacer()
            
            // Clip count
            if !appState.clips.isEmpty {
                Text("\(appState.clips.count) clip\(appState.clips.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            // New Sensitivity Control Button (Replaces the raw unlabelled slider)
            Button {
                showSensitivityPopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.blue)
                    Text("Sensitivity: \(appState.config.preset.rawValue) (\(appState.config.sensitivityPercent)%)")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .help("Adjust scene detection sensitivity and Apple Silicon speed")
            .popover(isPresented: $showSensitivityPopover) {
                SensitivityControlView()
                    .environmentObject(appState)
            }
            
            Divider().frame(height: 20)
            
            // Selection Controls
            if !appState.clips.isEmpty {
                Button {
                    if appState.selectedIDs.count == appState.clips.count {
                        appState.clearSelection()
                    } else {
                        appState.selectAll()
                    }
                } label: {
                    Text(appState.selectedIDs.count == appState.clips.count ? "Deselect All" : "Select All")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                // Merge Mode Toggle (for mouse-only merge selection)
                Toggle(isOn: $appState.isMergeModeActive) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.merge")
                        Text("Merge Mode")
                    }
                    .font(.subheadline)
                }
                .toggleStyle(.button)
                .tint(.red)
                .controlSize(.small)
                .help("Toggle merge mode: click clips to select them for merging in red outline")
                
                // Merge Action Button
                if appState.canMerge {
                    Button {
                        appState.mergeSelectedClips()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.merge")
                            Text("Merge (\(appState.mergeTargetCount))")
                                .fontWeight(.semibold)
                            Text("Space")
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.white.opacity(0.25))
                                )
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .help("Merge selected clips into one continuous clip (Shortcut: Space)")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            
            // Selection Counters
            if !appState.mergeSelectedIDs.isEmpty {
                Text("\(appState.mergeSelectedIDs.count) to merge")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
            }
            
            let selCount = appState.selectedIDs.count
            if selCount > 0 {
                Text("\(selCount) selected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            
            // Export Button
            Button {
                appState.showExportSettings = true
            } label: {
                Label(selCount > 0 ? "Export (\(selCount))" : "Export", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.selectedIDs.isEmpty || appState.isExporting)
            .help("Export selected clips as MP4")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct MediaPreparationProgressView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.2)
            
            VStack(spacing: 6) {
                Text("Preparing Media Container")
                    .font(.title3.weight(.semibold))
                Text(appState.preparationMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Lossless stream copy for Apple Silicon Media Engine")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoClipsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSensitivityPopover = false
    
    var body: some View {
        VStack(spacing: 16) {
            if let err = appState.detectionError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
                Text("Could Not Analyze Video")
                    .font(.title2.weight(.semibold))
                Text(err.localizedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: 56))
                    .foregroundStyle(.quaternary)
                Text("No scenes detected")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Current sensitivity may be too low for this footage.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            
            HStack(spacing: 12) {
                Button("Re-detect Scenes") {
                    Task { await appState.rerunDetection() }
                }
                .buttonStyle(.borderedProminent)
                
                Button("Change Sensitivity...") {
                    showSensitivityPopover = true
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showSensitivityPopover) {
                    SensitivityControlView()
                        .environmentObject(appState)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
