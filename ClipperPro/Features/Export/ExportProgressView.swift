import SwiftUI

struct ExportProgressView: View {
    let progress: ExportProgress
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Exporting Clips")
                    .font(.title2.weight(.semibold))
                Text(progress.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 6) {
                ProgressView(value: progress.overallFraction)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .frame(maxWidth: 320)
                
                HStack {
                    Text("\(progress.clipIndex + 1) of \(progress.clipTotal) clips")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress.overallFraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 320)
            }
            
            Button("Cancel Export") { onCancel() }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
        }
        .padding(32)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 20)
    }
}
