import SwiftUI

struct SceneDetectionProgressView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 24) {
            // Animated progress ring
            ZStack {
                Circle()
                    .stroke(.blue.opacity(0.15), lineWidth: 6)
                    .frame(width: 88, height: 88)
                
                Circle()
                    .trim(from: 0, to: CGFloat(appState.detectionProgress?.fraction ?? 0))
                    .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 88, height: 88)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: appState.detectionProgress?.fraction)
                
                VStack(spacing: 2) {
                    Image(systemName: "cpu")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                    if let prog = appState.detectionProgress {
                        Text(prog.percentString)
                            .font(.system(size: 14, weight: .bold).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }
            }
            
            VStack(spacing: 8) {
                Text("Detecting Scene Changes")
                    .font(.title2.weight(.semibold))
                
                if let prog = appState.detectionProgress {
                    HStack(spacing: 8) {
                        Text("\(prog.scenesCut) scene\(prog.scenesCut == 1 ? "" : "s") identified")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        if !prog.speedString.isEmpty {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(prog.speedString)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                    
                    ProgressView(value: prog.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 320)
                        .tint(.blue)
                    
                    HStack {
                        Text("Apple Silicon Media Engine")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if prog.etaSeconds > 0 {
                            Text("~" + String(format: "%.0fs remaining", prog.etaSeconds))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 320)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Starting hardware decoder pipeline...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Button("Cancel") {
                appState.cancelDetection()
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
