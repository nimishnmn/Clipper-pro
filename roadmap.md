# Clipper Pro — macOS Scene-Detection & Export Tool
## Roadmap & Technical Blueprint

> **Target**: Native SwiftUI macOS app (macOS 13 Ventura+) with Apple Silicon / Metal acceleration.
> All video processing is done on-device using AVFoundation + VideoToolbox + Metal — no third-party binary dependencies.

---

## 1. Project Architecture Overview

```
ClipperPro/
├── App/
│   ├── ClipperProApp.swift          # @main entry point, AppDelegate bridge
│   └── AppState.swift               # ObservableObject global state
├── Features/
│   ├── Import/
│   │   ├── ImportView.swift         # Drop zone + file picker
│   │   └── ImportViewModel.swift    # File validation, format detection
│   ├── SceneDetection/
│   │   ├── SceneDetector.swift      # Core scene-change algorithm (Metal)
│   │   ├── SceneDetectorPipeline.swift  # AVAssetReader pipeline
│   │   └── SceneDetectionProgressView.swift
│   ├── Grid/
│   │   ├── ClipGridView.swift       # LazyVGrid of clip thumbnails
│   │   ├── ClipCell.swift           # Individual cell with hover preview
│   │   ├── HoverPreviewPlayer.swift # AVPlayer preview on hover
│   │   └── SelectionManager.swift   # Click-drag multi-select
│   ├── Export/
│   │   ├── ExportSettingsView.swift # Resolution, FPS, bitrate, format
│   │   ├── ExportEngine.swift       # AVAssetExportSession / VideoToolbox
│   │   └── ExportProgressView.swift
│   └── Player/
│       └── InlinePlayerView.swift   # NSViewRepresentable AVPlayerLayer
├── Models/
│   ├── VideoClip.swift              # Struct: id, timeRange, thumbnail, name
│   ├── ExportSettings.swift         # Struct: resolution, fps, bitrate, codec
│   └── DetectionConfig.swift        # Struct: threshold, min clip duration
├── Services/
│   ├── ThumbnailService.swift       # Parallel AVAssetImageGenerator
│   ├── MetadataReader.swift         # Source video resolution/fps/bitrate
│   └── BookmarkService.swift        # Security-scoped bookmark persistence
├── Metal/
│   ├── FrameDiff.metal              # GPU pixel-diff kernel
│   └── FrameDiffPipeline.swift      # MTLComputePipeline wrapper
└── Resources/
    ├── Assets.xcassets
    └── ClipperPro.entitlements      # Sandbox + file access entitlements
```

---

## 2. Phase Breakdown

### Phase 0 — Project Bootstrap & Tooling
**Estimated effort: 0.5 day**

- [ ] Create Xcode project (SwiftUI App, macOS 13+, Swift 5.9)
- [ ] Set bundle ID `com.clipper.pro`, enable App Sandbox
- [ ] Configure entitlements:
  - `com.apple.security.files.user-selected.read-write`
  - `com.apple.security.files.bookmarks.app-scope`
  - `com.apple.security.temporary-exception.files.absolute-path.read-write`
- [ ] Add `.gitignore`, configure Swift Package Manager (no CocoaPods)
- [ ] Set minimum deployment target: macOS 13.0
- [ ] Enable hardened runtime
- [ ] Configure Metal capabilities in build settings

---

### Phase 1 — Video Import & Metadata Extraction
**Estimated effort: 0.5 day**

#### 1.1 Drop Zone / File Picker
- Implement `ImportView.swift` with `NSOpenPanel` and drag-and-drop (`onDrop` with `NSItemProvider`)
- Accept UTTypes: `.mpeg4Movie`, `.quickTimeMovie`, `.movie`, `.video`, custom MKV UTType (`org.matroska.mkv`)
- Register MKV UTType in `Info.plist` so Finder recognizes it
- Store security-scoped bookmark via `BookmarkService.swift`

#### 1.2 Metadata Extraction (`MetadataReader.swift`)
- Use `AVURLAsset` to read:
  - Natural resolution (`AVAssetTrack.naturalSize`)
  - Nominal frame rate (`AVAssetTrack.nominalFrameRate`)
  - Estimated data rate / bit rate (`AVAssetTrack.estimatedDataRate`)
  - Duration, codec (format descriptions)
- Store as `SourceVideoInfo` struct → populate `ExportSettings` defaults

#### 1.3 Format Support
- **MP4 / MOV**: Native AVFoundation support
- **MKV**: AVFoundation can read MKV on macOS 12+ via system codec
  - Fallback: use `AVURLAsset` with `AVAssetTrackLoadValuesAsynchronously` to check decodability
  - Display warning if codec is unsupported (e.g., H.265 in MKV on older macOS)

---

### Phase 2 — Scene Detection Engine (Core, GPU-Accelerated)
**Estimated effort: 2 days**

This is the most performance-critical phase. The algorithm uses a **histogram difference** approach running on the GPU via Metal.

#### 2.1 Frame Extraction Pipeline (`SceneDetectorPipeline.swift`)
- Create `AVAssetReader` with `AVAssetReaderTrackOutput`
- Output settings: `kCVPixelFormatType_32BGRA` (optimal for Metal)
- Read frames at **reduced resolution** (e.g., 320×180) for fast diff — use `AVVideoScalingModeResizeAspect` via `AVAssetReaderVideoCompositionOutput` with a `AVMutableVideoComposition` that sets `renderSize`
- Use a **sliding window** of 2 frames: current and previous
- Push pixel buffers to the Metal pipeline via `CVMetalTextureCache`

#### 2.2 Metal GPU Kernel (`FrameDiff.metal`)
```metal
// Computes per-channel histogram difference between two BGRA textures
kernel void frameDiff(
    texture2d<float, access::read> prev [[texture(0)]],
    texture2d<float, access::read> curr [[texture(1)]],
    device atomic_uint* histogram [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float4 p = prev.read(gid);
    float4 c = curr.read(gid);
    float diff = abs(p.r - c.r) + abs(p.g - c.g) + abs(p.b - c.b);
    uint bin = min(uint(diff * 255.0), 255u);
    atomic_fetch_add_explicit(&histogram[bin], 1, memory_order_relaxed);
}
```
- Dispatch on `MTLComputeCommandEncoder` with threadgroup size 16×16
- Read histogram back → compute **Earth Mover's Distance** (or simpler: weighted mean diff)
- Scene cut if score > configurable threshold (default: 0.35)

#### 2.3 Detection Config (`DetectionConfig.swift`)
```swift
struct DetectionConfig {
    var threshold: Float = 0.35        // Scene change sensitivity
    var minClipDuration: Double = 1.0  // Minimum seconds per clip
    var frameSkip: Int = 1             // Sample every N frames (1 = every frame)
    var downsampleWidth: Int = 320     // Width for diff calculation
}
```

#### 2.4 Output
- Array of `CMTimeRange` cut points → `[VideoClip]`
- Each clip named `"1"`, `"2"`, ..., `"N"` sequentially
- Report progress via `AsyncStream<DetectionProgress>`

#### 2.5 Performance Targets
- **1080p 60fps 1-hour video**: < 90 seconds detection time on M1
- **4K 30fps 30-min video**: < 60 seconds on M2
- Use `autoreleasepool` per-frame to bound memory
- Double-buffer Metal command buffers for pipelining

---

### Phase 3 — Thumbnail Generation
**Estimated effort: 0.5 day**

#### 3.1 `ThumbnailService.swift`
- Use `AVAssetImageGenerator` with `maximumSize = CGSize(width: 400, height: 225)`
- Set `appliesPreferredTrackTransform = true` (correct rotation)
- Use `generateCGImageAsynchronously` (async, non-blocking)
- Generate thumbnails in **parallel** using Swift concurrency (`TaskGroup`)
  ```swift
  await withTaskGroup(of: (Int, CGImage?).self) { group in
      for (index, clip) in clips.enumerated() {
          group.addTask {
              let time = clip.timeRange.start + clip.timeRange.duration / 2
              let image = try? await generator.image(at: time)
              return (index, image?.image)
          }
      }
  }
  ```
- Cache thumbnails in memory (`NSCache<NSString, NSImage>`) keyed by clip ID
- Show placeholder gradient while thumbnail loads

---

### Phase 4 — Grid View UI
**Estimated effort: 1.5 days**

#### 4.1 `ClipGridView.swift`
- `LazyVGrid` with adaptive columns (`GridItem(.adaptive(minimum: 220, maximum: 320))`)
- Virtualized rendering — only visible cells are loaded (LazyVGrid handles this natively)
- Show: thumbnail image, clip number, duration badge, selection overlay

#### 4.2 `ClipCell.swift`
- **Hover Preview** (`onHover`):
  - After 300ms delay (debounce), replace thumbnail with a `HoverPreviewPlayer`
  - `HoverPreviewPlayer` uses `AVPlayer` with the source asset, seeks to clip start
  - Plays muted, loops within the clip's `CMTimeRange`
  - On hover exit: pause player, show static thumbnail
  - Players are pooled (max 3 simultaneous) to avoid resource exhaustion
- **Click**: toggle selection
- **Click-drag** multi-select:
  - Track `DragGesture` across cells
  - Use a `SelectionManager` that determines which cells the drag rectangle intersects
  - Show blue selection overlay on selected cells
  - Support `Command+A` to select all, `Escape` to deselect

#### 4.3 Selection Manager (`SelectionManager.swift`)
```swift
@Observable class SelectionManager {
    var selectedIDs: Set<UUID> = []
    var isDragging: Bool = false
    var dragRect: CGRect = .zero

    func handleDrag(in gridCoordinates: CGRect, cellFrames: [UUID: CGRect])
    func toggle(_ id: UUID)
    func selectAll(_ ids: [UUID])
    func clear()
}
```
- Coordinate space: convert drag gestures to grid's coordinate space using `GeometryReader` + `PreferenceKey`
- Cell frames reported via `anchorPreference` / `overlayPreferenceValue`

#### 4.4 Toolbar
- Left: file name, source resolution/fps indicator
- Center: "X clips detected" count
- Right: Export button (disabled if no selection), Settings gear
- Scene detection sensitivity slider (re-runs detection on change with debounce)

---

### Phase 5 — Export Engine
**Estimated effort: 1.5 days**

#### 5.1 `ExportSettingsView.swift`
Settings panel (sheet or sidebar):
- **Resolution**: Dropdown: Original, 4K (3840×2160), 1080p, 720p, 480p, Custom
- **Frame Rate**: Dropdown: Original, 60, 30, 24, Custom
- **Bitrate**: Slider (1–100 Mbps) + text field, default = source bitrate
- **Codec**: H.264 (mp4), H.265/HEVC (mp4) — both hardware-encoded via VideoToolbox
- **Output Format**: MP4 (enforced per spec)
- **Output Folder**: NSOpenPanel for directory picker

#### 5.2 `ExportEngine.swift`
Strategy based on target quality:

**Primary path — `AVAssetExportSession` (simple, HW-accelerated)**:
```swift
let session = AVAssetExportSession(asset: clippedAsset, presetName: preset)
session.outputFileType = .mp4
session.outputURL = outputURL
session.timeRange = clip.timeRange
await session.export()
```
- Use presets: `AVAssetExportPresetHighestQuality`, `AVAssetExportPreset1920x1080`, etc.

**Custom bitrate/codec path — `AVAssetWriter` + `AVAssetReader` + VideoToolbox**:
```swift
// Reader
let reader = try AVAssetReader(asset: asset)
let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: nil)

// Writer
let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,   // or .hevc
    AVVideoWidthKey: targetWidth,
    AVVideoHeightKey: targetHeight,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: targetBitrate,
        AVVideoExpectedSourceFrameRateKey: targetFPS,
        // Hardware encode flag:
        "EnableHardwareAcceleratedVideoEncoder": true
    ]
])
```
- Use `AVAssetWriterInputPixelBufferAdaptor` for raw pixel passthrough when no transcoding needed
- Audio track: copy-passthrough (no re-encode) via `AVAssetWriterInput` with `nil` output settings

#### 5.3 Parallel Export
- Export multiple clips concurrently using Swift concurrency
- Limit concurrency to `ProcessInfo.processInfo.activeProcessorCount / 2` tasks
- Show per-clip progress bars in `ExportProgressView`
- Allow cancel via `Task.cancel()`

#### 5.4 File Naming
- Output: `{clipNumber}.mp4` → `1.mp4`, `2.mp4`, ... `N.mp4`
- Overwrite confirmation if files exist

---

### Phase 6 — Apple Platform Optimizations
**Estimated effort: 0.5 day**

| Optimization | Implementation |
|---|---|
| **VideoToolbox HW decode** | Set `kVTDecompressionPropertyKey_RealTime: false` for max throughput |
| **VideoToolbox HW encode** | `EnableHardwareAcceleratedVideoEncoder: true` in writer settings |
| **Metal GPU scene diff** | `MTLCommandQueue` from shared `MTLDevice.default` |
| **CVMetalTextureCache** | Zero-copy CPU→GPU pixel buffer transfer |
| **Grand Central Dispatch** | QoS `.userInitiated` for detection, `.utility` for export |
| **Unified Memory** | Avoid CPU↔GPU copies on Apple Silicon via `MTLStorageMode.shared` |
| **Thermal throttle guard** | Monitor `ProcessInfo.thermalState`, reduce parallelism on `.critical` |
| **Memory pressure** | Subscribe to `NSNotification.Name.NSProcessInfoPowerStateDidChange`, flush thumbnail cache |
| **Instruments profiling** | Use Time Profiler + Metal System Trace to verify GPU utilization |

---

### Phase 7 — Polish, UX & Accessibility
**Estimated effort: 0.5 day**

- [ ] App icon (designed in SF Symbols / Sketch)
- [ ] Onboarding empty state with drop zone illustration
- [ ] Keyboard shortcuts:
  - `Cmd+O`: Open file
  - `Cmd+A`: Select all clips
  - `Cmd+Shift+E`: Export selected
  - `Escape`: Deselect all
  - `Space`: Toggle preview of focused clip
- [ ] Drag-select rubber-band visual (semi-transparent blue rect overlay)
- [ ] Clip count badge on export button
- [ ] Tooltips on all controls
- [ ] VoiceOver: label cells with "Clip N, duration X seconds"
- [ ] Dark mode support (automatic via SwiftUI)
- [ ] macOS menu bar items (File, Edit, Export menus)
- [ ] Crash recovery: auto-save detection results to temp JSON

---

### Phase 8 — Testing & QA
**Estimated effort: 1 day**

#### Unit Tests
- `SceneDetectorTests`: synthetic frame sequences with known cut points
- `ExportSettingsTests`: resolution/bitrate clamping logic
- `SelectionManagerTests`: drag-select rectangle intersection

#### Integration Tests
- End-to-end: import → detect → export for sample MP4 and MKV files
- Verify output file: resolution, FPS, bitrate within 5% of target

#### Performance Benchmarks (XCTest `measure`)
- Scene detection on 10-min 1080p clip: target < 15 seconds
- Thumbnail generation for 50 clips: target < 3 seconds
- Export 10×30-second clips at 1080p: target < 60 seconds

#### Manual QA Checklist
- [ ] Drop MKV file → correct metadata read
- [ ] Scene detection produces clips numbered 1–N
- [ ] Hover over clip → preview starts within 300ms
- [ ] Click-drag selects expected cells
- [ ] Export → verify in QuickTime Player
- [ ] Cancel mid-export → partial files cleaned up
- [ ] Test on both Intel Mac (Big Sur+) and Apple Silicon

---

## 3. Technology Stack

| Layer | Technology | Reason |
|---|---|---|
| Language | Swift 5.9 | Native performance, concurrency model |
| UI Framework | SwiftUI 4 (macOS 13+) | Declarative, grid layout, animations |
| Video I/O | AVFoundation | Native, HW-accelerated decode/encode |
| GPU Compute | Metal | Sub-millisecond frame diff on Apple GPU |
| HW Encode/Decode | VideoToolbox | H.264/HEVC hardware codec |
| Zero-copy textures | CVMetalTextureCache | Avoid CPU↔GPU memcpy |
| Concurrency | Swift async/await + TaskGroup | Structured concurrency, cancellation |
| Persistence | UserDefaults + NSFileManager | Settings, security bookmarks |
| Testing | XCTest + Swift Testing | Unit + integration |
| Build | Xcode 15 + SPM | No external package managers |

---

## 4. Data Flow Diagram

```
[User Drops File]
       │
       ▼
[MetadataReader] ──────────────────────► ExportSettings (defaults from source)
       │
       ▼
[AVAssetReader @ 320px wide]
       │  CVPixelBuffer stream
       ▼
[CVMetalTextureCache] ──► [Metal FrameDiff Kernel] ──► diff score per frame
                                                              │
                                                              ▼
                                                    [SceneDetector: threshold compare]
                                                              │
                                                              ▼
                                                    [CMTimeRange[] cut points]
                                                              │
                         ┌────────────────────────────────────┘
                         ▼
              [VideoClip[] model array]
                         │
           ┌─────────────┴──────────────┐
           ▼                            ▼
  [ThumbnailService]           [ClipGridView (LazyVGrid)]
  AVAssetImageGenerator               │
  parallel TaskGroup             [ClipCell × N]
           │                     hover → AVPlayer preview
           ▼                     click/drag → SelectionManager
     NSCache<thumbnails>
                                        │ user selects + clicks Export
                                        ▼
                              [ExportSettingsView]
                                        │
                                        ▼
                              [ExportEngine]
                         AVAssetWriter + VideoToolbox
                         parallel export (N clips)
                                        │
                                        ▼
                            [1.mp4, 2.mp4, ... N.mp4]
```

---

## 5. Milestones & Timeline

| Milestone | Phases | Target |
|---|---|---|
| **M0**: Xcode project running, blank window | Phase 0 | Day 1 |
| **M1**: Drop video, read metadata, show info | Phase 1 | Day 1 |
| **M2**: Scene detection working, clips listed | Phase 2 | Day 3 |
| **M3**: Thumbnail grid with hover preview | Phases 3+4 | Day 5 |
| **M4**: Export to MP4 with custom settings | Phase 5 | Day 7 |
| **M5**: All Apple optimizations applied | Phase 6 | Day 7.5 |
| **M6**: Polish + full QA pass | Phases 7+8 | Day 8.5 |

---

## 6. Key Design Decisions

### Why Metal for scene detection instead of Core Image / Vision?
- Core Image filters have overhead per-frame; Metal kernel is ~10× faster for raw pixel diff
- Vision framework's `VNDetectVideoSceneAnalysisRequest` is available but less controllable (black box threshold)
- Custom Metal kernel gives precise control over threshold and histogram shape

### Why AVAssetWriter over AVAssetExportSession for custom bitrate?
- `AVAssetExportSession` does not expose bitrate control (only preset names)
- `AVAssetWriter` + VideoToolbox allows exact `AVVideoAverageBitRateKey` specification
- Both use hardware encoders transparently

### Why not FFmpeg?
- FFmpeg is not App Store compatible (GPL/LGPL licensing)
- VideoToolbox + AVFoundation provide equivalent functionality with hardware acceleration
- Avoids sandboxing complications of spawning external processes

### MKV Support
- macOS 12+ includes a system MKV demuxer, so AVFoundation handles most MKV files
- Edge cases: VP9/AV1 codec in MKV → show codec warning, offer to convert via AVAssetExportSession

---

## 7. File Checklist (Implementation Order)

```
Priority 1 (Core pipeline):
  [ ] ClipperProApp.swift
  [ ] AppState.swift
  [ ] BookmarkService.swift
  [ ] MetadataReader.swift
  [ ] VideoClip.swift
  [ ] ExportSettings.swift
  [ ] DetectionConfig.swift
  [ ] FrameDiff.metal
  [ ] FrameDiffPipeline.swift
  [ ] SceneDetector.swift
  [ ] SceneDetectorPipeline.swift

Priority 2 (UI):
  [ ] ImportView.swift
  [ ] SceneDetectionProgressView.swift
  [ ] ThumbnailService.swift
  [ ] ClipGridView.swift
  [ ] ClipCell.swift
  [ ] HoverPreviewPlayer.swift
  [ ] SelectionManager.swift

Priority 3 (Export):
  [ ] ExportSettingsView.swift
  [ ] ExportEngine.swift
  [ ] ExportProgressView.swift

Priority 4 (Polish):
  [ ] InlinePlayerView.swift
  [ ] Keyboard shortcuts
  [ ] Accessibility labels
  [ ] App icon + onboarding
```
