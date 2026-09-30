import SwiftUI

struct SensitivityControlView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack {
                Label("Scene Detection Settings", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Divider()
            
            // Sensitivity Presets
            VStack(alignment: .leading, spacing: 8) {
                Text("Sensitivity Level")
                    .font(.subheadline.weight(.semibold))
                
                Picker("Preset", selection: Binding(
                    get: { appState.config.preset },
                    set: { newPreset in
                        appState.config.applyPreset(newPreset)
                    }
                )) {
                    ForEach(SensitivityPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                
                Text(appState.config.preset.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Fine-Tuning Slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Fine Sensitivity")
                        .font(.subheadline)
                    Spacer()
                    Text("\(appState.config.sensitivityPercent)%")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.blue)
                }
                
                Slider(
                    value: Binding(
                        get: { Double(appState.config.sensitivityPercent) },
                        set: { appState.setSensitivityPercent($0) }
                    ),
                    in: 10...90,
                    step: 1
                )
                
                HStack {
                    Text("Fewer Cuts")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("More Cuts")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
            
            // Apple Silicon Media Engine Speed Mode
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hardware Speed Mode")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "cpu")
                        .foregroundStyle(.secondary)
                }
                
                Picker("Speed Mode", selection: $appState.config.speedMode) {
                    ForEach(DetectionSpeedMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                
                Text(speedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Minimum Clip Duration
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Min Clip Duration")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f sec", appState.config.minClipDuration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                
                Slider(
                    value: $appState.config.minClipDuration,
                    in: 0.10...5.0,
                    step: 0.05
                )
            }
            
            Divider()
            
            // Action Button
            Button {
                dismiss()
                Task {
                    await appState.rerunDetection()
                }
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "wand.and.sparkles")
                    Text("Apply & Re-detect Scenes")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 320)
    }
    
    private var speedDescription: String {
        switch appState.config.speedMode {
        case .turbo:
            return "Analyzes every frame at 240p on Apple Silicon GPU (~2500 fps). Exact frame cuts."
        case .balanced:
            return "Analyzes every frame at 320p on Apple Silicon GPU (~1500 fps). Recommended."
        case .accurate:
            return "Analyzes every frame at 480p on Apple Silicon GPU (~800 fps). High-detail cuts."
        }
    }
}
