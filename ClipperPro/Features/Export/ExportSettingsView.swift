import SwiftUI
import AVFoundation

struct ExportSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var isExporting = false
    @State private var exportError: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export Settings")
                        .font(.title2.weight(.bold))
                    let count = appState.selectedIDs.count
                    Text("\(count) clip\(count == 1 ? "" : "s") selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.quaternary, .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Settings form
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $appState.exportSettings.resolution) {
                        ForEach(ExportResolution.allCases) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    
                    if appState.exportSettings.resolution == .custom {
                        HStack {
                            TextField("Width", value: $appState.exportSettings.customWidth, format: .number)
                                .frame(width: 80)
                            Text("×")
                            TextField("Height", value: $appState.exportSettings.customHeight, format: .number)
                                .frame(width: 80)
                        }
                    }
                    
                    Picker("Frame Rate", selection: $appState.exportSettings.frameRate) {
                        ForEach(ExportFrameRate.allCases) { fps in
                            Text(fps.rawValue).tag(fps)
                        }
                    }
                    
                    if appState.exportSettings.frameRate == .custom {
                        HStack {
                            TextField("FPS", value: $appState.exportSettings.customFPS, format: .number)
                                .frame(width: 80)
                            Text("fps")
                        }
                    }
                    
                    Picker("Codec", selection: $appState.exportSettings.codec) {
                        ForEach(ExportCodec.allCases) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
                }
                
                Section("Quality") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            Text(appState.exportSettings.bitrateFormatted)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(appState.exportSettings.bitrate) / 1_000_000 },
                                set: { appState.exportSettings.bitrate = Int($0 * 1_000_000) }
                            ),
                            in: 0.5...100,
                            step: 0.5
                        )
                        HStack {
                            Text("0.5 Mbps")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("100 Mbps")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                
                Section("Output Mode & Destination") {
                    Picker("File Arrangement", selection: $appState.exportSettings.mergeMode) {
                        ForEach(ExportMergeMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    
                    Toggle("Save clips into a dedicated subfolder", isOn: $appState.exportSettings.createSubfolder)
                        .font(.subheadline)
                    
                    HStack {
                        if let folder = appState.exportSettings.outputFolderURL {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(folder.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Button("Change") { chooseOutputFolder() }
                                .buttonStyle(.bordered)
                        } else {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text("No folder selected")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose Folder") { chooseOutputFolder() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    
                    if appState.exportSettings.mergeMode == .separateFiles {
                        Text("Exports each clip separately as 1.mp4, 2.mp4, ..., N.mp4")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Seamlessly merges all selected clips in sequence into one continuous Merged_Scenes.mp4")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            
            if let err = exportError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            
            Divider()
            
            // Footer buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button {
                    Task { await startExport() }
                } label: {
                    if isExporting {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.exportSettings.outputFolderURL == nil || isExporting)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
    
    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose where to save exported clips"
        panel.prompt = "Select Folder"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.exportSettings.outputFolderURL = url
    }
    
    private func startExport() async {
        guard let playableURL = appState.workingURL ?? appState.sourceURL else { return }
        guard !appState.selectedIDs.isEmpty else { return }
        
        isExporting = true
        exportError = nil
        
        let selectedClips = appState.clips.filter {
            appState.selectedIDs.contains($0.id)
        }.sorted { $0.number < $1.number }
        
        let asset = AVURLAsset(url: playableURL)
        let engine = ExportEngine()
        let settings = appState.exportSettings
        
        do {
            try await engine.exportClips(
                selectedClips,
                from: asset,
                settings: settings
            ) { prog in
                Task { @MainActor in
                    appState.exportProgress = prog
                }
            }
            isExporting = false
            dismiss()
            // Open output folder in Finder
            if let folder = settings.outputFolderURL {
                NSWorkspace.shared.open(folder)
            }
        } catch {
            isExporting = false
            exportError = error.localizedDescription
        }
    }
}
