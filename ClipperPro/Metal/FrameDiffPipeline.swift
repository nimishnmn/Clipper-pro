import Foundation
import Metal
import CoreVideo
import CoreImage

/// Wraps the Metal compute pipeline for GPU-accelerated frame difference scoring.
final class FrameDiffPipeline {
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let diffPipeline: MTLComputePipelineState
    private let scorePipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    
    // Persistent buffers reused across frames
    private let histogramBuffer: MTLBuffer
    private let resultBuffer: MTLBuffer
    
    static let histogramSize = 256 * MemoryLayout<UInt32>.stride
    
    init() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw PipelineError.noMetalDevice
        }
        self.device = dev
        
        guard let queue = dev.makeCommandQueue() else {
            throw PipelineError.commandQueueFailed
        }
        self.commandQueue = queue
        
        // Load shaders: compile from source at runtime for maximum portability and zero build toolchain dependencies
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void frameDiff(
            texture2d<float, access::read> prevFrame [[texture(0)]],
            texture2d<float, access::read> currFrame [[texture(1)]],
            device atomic_uint* diffHistogram [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            const uint width  = prevFrame.get_width();
            const uint height = prevFrame.get_height();
            if (gid.x >= width || gid.y >= height) return;
            
            float4 prev = prevFrame.read(gid);
            float4 curr = currFrame.read(gid);
            
            float prevLuma = 0.299f * prev.r + 0.587f * prev.g + 0.114f * prev.b;
            float currLuma = 0.299f * curr.r + 0.587f * curr.g + 0.114f * curr.b;
            
            float rDiff = abs(prev.r - curr.r);
            float gDiff = abs(prev.g - curr.g);
            float bDiff = abs(prev.b - curr.b);
            float lumaDiff = abs(prevLuma - currLuma);
            
            float combinedDiff = 0.5f * lumaDiff + (rDiff + gDiff + bDiff) / 6.0f;
            uint bin = min(uint(combinedDiff * 255.0f), 255u);
            atomic_fetch_add_explicit(&diffHistogram[bin], 1u, memory_order_relaxed);
        }

        kernel void histogramToScore(
            device const uint* histogram [[buffer(0)]],
            device float*      result    [[buffer(1)]],
            uint               gid       [[thread_position_in_grid]]
        ) {
            if (gid != 0) return;
            uint totalPixels = 0;
            float weightedSum = 0.0f;
            for (uint i = 0; i < 256; i++) {
                uint count = histogram[i];
                totalPixels += count;
                weightedSum += float(i) * float(count);
            }
            if (totalPixels == 0) {
                result[0] = 0.0f;
            } else {
                result[0] = (weightedSum / float(totalPixels)) / 255.0f;
            }
        }
        """

        let library: MTLLibrary
        if let compiledLib = try? dev.makeLibrary(source: shaderSource, options: nil) {
            library = compiledLib
        } else if let defaultLib = dev.makeDefaultLibrary() {
            library = defaultLib
        } else {
            throw PipelineError.noDefaultLibrary
        }
        
        guard let diffFn = library.makeFunction(name: "frameDiff"),
              let scoreFn = library.makeFunction(name: "histogramToScore") else {
            throw PipelineError.functionNotFound
        }
        
        self.diffPipeline  = try dev.makeComputePipelineState(function: diffFn)
        self.scorePipeline = try dev.makeComputePipelineState(function: scoreFn)
        
        // Create CVMetalTextureCache for zero-copy pixel buffer → texture
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        guard let tc = cache else { throw PipelineError.textureCacheFailed }
        self.textureCache = tc
        
        // Histogram: 256 x UInt32
        guard let histBuf = dev.makeBuffer(
            length: FrameDiffPipeline.histogramSize,
            options: .storageModeShared   // Shared memory — optimal on Apple Silicon
        ) else { throw PipelineError.bufferFailed }
        self.histogramBuffer = histBuf
        
        guard let resBuf = dev.makeBuffer(
            length: MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else { throw PipelineError.bufferFailed }
        self.resultBuffer = resBuf
    }
    
    /// Compare two pixel buffers and return a normalized diff score (0.0–1.0).
    /// Score above threshold indicates a scene cut.
    func score(prev: CVPixelBuffer, curr: CVPixelBuffer) throws -> Float {
        guard let prevTex = makeTexture(from: prev),
              let currTex = makeTexture(from: curr) else {
            throw PipelineError.textureFailed
        }
        
        guard let cmdBuf = commandQueue.makeCommandBuffer() else {
            throw PipelineError.commandBufferFailed
        }
        
        let width  = CVPixelBufferGetWidth(prev)
        let height = CVPixelBufferGetHeight(prev)
        
        // --- Pass 1: frameDiff kernel — fills histogram ---
        memset(histogramBuffer.contents(), 0, FrameDiffPipeline.histogramSize)
        
        guard let enc1 = cmdBuf.makeComputeCommandEncoder() else {
            throw PipelineError.encoderFailed
        }
        enc1.setComputePipelineState(diffPipeline)
        enc1.setTexture(prevTex, index: 0)
        enc1.setTexture(currTex, index: 1)
        enc1.setBuffer(histogramBuffer, offset: 0, index: 0)
        
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(
            width:  (width  + 15) / 16,
            height: (height + 15) / 16,
            depth:  1
        )
        enc1.dispatchThreadgroups(gridSize, threadsPerThreadgroup: tgSize)
        enc1.endEncoding()
        
        // --- Pass 2: histogramToScore kernel ---
        guard let enc2 = cmdBuf.makeComputeCommandEncoder() else {
            throw PipelineError.encoderFailed
        }
        enc2.setComputePipelineState(scorePipeline)
        enc2.setBuffer(histogramBuffer, offset: 0, index: 0)
        enc2.setBuffer(resultBuffer,    offset: 0, index: 1)
        enc2.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                  threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc2.endEncoding()
        
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        
        let score = resultBuffer.contents().load(as: Float.self)
        return score
    }
    
    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width, height,
            0,
            &cvTexture
        )
        guard result == kCVReturnSuccess, let tex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(tex)
    }
    
    enum PipelineError: LocalizedError {
        case noMetalDevice, commandQueueFailed, noDefaultLibrary
        case functionNotFound, textureCacheFailed, bufferFailed
        case textureFailed, commandBufferFailed, encoderFailed
        
        var errorDescription: String? {
            switch self {
            case .noMetalDevice:       return "No Metal device available."
            case .commandQueueFailed:  return "Failed to create Metal command queue."
            case .noDefaultLibrary:    return "Metal default library not found. Ensure Metal shaders are compiled."
            case .functionNotFound:    return "Required Metal function not found in library."
            case .textureCacheFailed:  return "CVMetalTextureCache creation failed."
            case .bufferFailed:        return "Failed to allocate Metal buffer."
            case .textureFailed:       return "Failed to create Metal texture from pixel buffer."
            case .commandBufferFailed: return "Failed to create Metal command buffer."
            case .encoderFailed:       return "Failed to create Metal compute encoder."
            }
        }
    }
}
