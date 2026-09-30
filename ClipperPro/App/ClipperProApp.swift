import SwiftUI

@main
struct ClipperProApp: App {
    
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(appState: appState)
        }
    }
}

struct AppCommands: Commands {
    let appState: AppState
    
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Video...") {
                openFile()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        CommandMenu("Edit") {
            Button("Select All") {
                Task { @MainActor in
                    appState.selectAll()
                }
            }
            .keyboardShortcut("a", modifiers: .command)
            
            Button("Deselect All") {
                Task { @MainActor in
                    appState.clearSelection()
                }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandMenu("Export") {
            Button("Export Selected...") {
                Task { @MainActor in
                    appState.showExportSettings = true
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(appState.selectedIDs.isEmpty)
        }
    }
    
    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .mpeg4Movie, .quickTimeMovie, .movie, .video,
            .init(filenameExtension: "mkv")!,
            .init(filenameExtension: "webm")!,
            .init(filenameExtension: "avi")!
        ]
        panel.message = "Choose a video file to analyze"
        panel.prompt = "Open Video"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            await appState.loadVideo(url: url)
        }
    }
}
