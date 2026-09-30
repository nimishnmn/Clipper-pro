# Clipper Pro 🎬

A native macOS application designed for high-performance, GPU-accelerated video scene detection, precision trimming, and batch export. Optimized for Apple Silicon using Metal, AVFoundation, and VideoToolbox.

## Features

- **Apple Silicon Hardware Acceleration**: Direct Metal shader compute pipeline analyzing video frames at up to 1500–2500 FPS.
- **Frame-Accurate Scene Detection**: Zero-frame-drift detection using native PTS timing and hardware video track reading.
- **Dynamic Aspect Ratio Grid**: Interactive grid adapting to cinematic aspect ratios (16:9, 2.35:1, vertical 9:16) with instantaneous hover previews.
- **Precision Mini Trim Inspector**: Scrub and fine-tune in/out points with micro-stepping controls down to individual frames (-1F / +1F).
- **Interactive Multi-Clip Merging**: Select multiple scenes (using Shift+click or Merge Mode) and press Space to combine them into a single continuous scene.
- **Flexible Export**: Export individual clips as MP4 or merge them sequentially into a single video, with custom resolutions, frame rates, and bitrates.
- **Project Persistence**: Auto-saves sessions and recent projects locally.
