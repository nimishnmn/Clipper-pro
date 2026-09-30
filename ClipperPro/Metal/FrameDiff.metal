#include <metal_stdlib>
using namespace metal;

// Computes the per-pixel absolute difference between two BGRA textures.
// Accumulates a 256-bucket luminance-diff histogram in the output buffer.
// threadgroup_size should be 16x16.
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
    
    // Weighted luminance difference (BT.601 coefficients)
    float prevLuma = 0.299f * prev.r + 0.587f * prev.g + 0.114f * prev.b;
    float currLuma = 0.299f * curr.r + 0.587f * curr.g + 0.114f * curr.b;
    
    // Per-channel absolute difference for color sensitivity
    float rDiff = abs(prev.r - curr.r);
    float gDiff = abs(prev.g - curr.g);
    float bDiff = abs(prev.b - curr.b);
    float lumaDiff = abs(prevLuma - currLuma);
    
    // Combined score: weighted mix of luma + color
    float combinedDiff = 0.5f * lumaDiff + (rDiff + gDiff + bDiff) / 6.0f;
    
    uint bin = min(uint(combinedDiff * 255.0f), 255u);
    atomic_fetch_add_explicit(&diffHistogram[bin], 1u, memory_order_relaxed);
}

// Compute a simple mean diff score from the histogram buffer.
// Output is written to result[0] as a normalized float (0.0–1.0).
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
