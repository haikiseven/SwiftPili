#include <metal_stdlib>
using namespace metal;

namespace {
constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

// Analysis uses a small RGB proxy. NV12 color reconstruction here only informs
// matching and cut detection. The final kernels sample native code values and
// preserve the input range, matrix and pixel layout.
float3 analysisColor(texture2d<float> source, texture2d<float> chroma, float4 parameters, float2 uv) {
    float4 sample = source.sample(linearClamp, uv);
    if (parameters.z == 0.0f) { return sample.rgb; }
    float y = sample.r;
    float2 cbcr = chroma.sample(linearClamp, uv - parameters.xy).rg - (128.0f / 255.0f);
    if (parameters.z == 2.0f) {
        y = (y - 16.0f / 255.0f) * (255.0f / 219.0f);
        cbcr *= (255.0f / 224.0f);
    }
    return saturate(float3(y + 1.5748f * cbcr.y,
                           y - 0.1873f * cbcr.x - 0.4681f * cbcr.y,
                           y + 1.8556f * cbcr.x));
}

bool inside(float2 uv) {
    return all(uv >= 0.0f) && all(uv <= 1.0f);
}

bool displacement(texture2d<float> flow, float2 uv, float2 extent, float signY, thread float2 &delta) {
    float2 pixels = flow.sample(linearClamp, uv).rg;
    // Inspect the IEEE exponent explicitly so fast math cannot erase the NaN/Inf check.
    if (any((as_type<uint2>(pixels) & 0x7f800000u) == 0x7f800000u)) { return false; }
    if (any(abs(pixels) > extent * 0.30f)) { return false; }
    // Convert each axis independently. The normalized vector applies at any
    // output size including to the luma coordinates of subsampled chroma.
    delta = pixels * float2(1.0f, signY) / extent;
    return true;
}

bool pairedDisplacement(texture2d<float> flow, texture2d<float> reverse,
                        float2 uv, float2 extent, float signY, thread float2 &delta) {
    if (!inside(uv) || !displacement(flow, uv, extent, signY, delta)) { return false; }
    float2 destination = uv + delta;
    float2 back;
    if (!inside(destination) || !displacement(reverse, destination, extent, signY, back)) { return false; }
    float motion = length(delta * extent);
    return length((delta + back) * extent) <= 1.5f + motion * 0.12f;
}

float colorResidual(float3 a, float3 b) {
    float3 residual = abs(a - b);
    return max(residual.r, max(residual.g, residual.b));
}

float2 validateDirection(texture2d<float> source, texture2d<float> target,
                         texture2d<float> flow, texture2d<float> reverse,
                         float2 uv, float2 extent, float signY) {
    float3 reference = source.sample(linearClamp, uv).rgb;
    float2 delta;
    if (!pairedDisplacement(flow, reverse, uv, extent, signY, delta)) {
        return float2(colorResidual(reference, target.sample(linearClamp, uv).rgb), 0.0f);
    }
    float residual = colorResidual(reference, target.sample(linearClamp, uv + delta).rgb);
    return float2(residual, residual < 0.16f ? 1.0f : 0.0f);
}

float2 validatePair(texture2d<float> previous, texture2d<float> current,
                    texture2d<float> forward, texture2d<float> backward,
                    float2 uv, float2 extent, float signY) {
    return 0.5f * (validateDirection(previous, current, forward, backward, uv, extent, signY) +
                   validateDirection(current, previous, backward, forward, uv, extent, signY));
}

// Invert target = endpoint + fraction * endpointFlow(endpoint). A short fixed-point
// solve samples vectors at the endpoint rather than at the interpolated coordinate.
bool inverseWarp(texture2d<float> flow, texture2d<float> reverse, float2 target,
                 float2 extent, float signY, float fraction, thread float2 &endpoint) {
    endpoint = target;
    for (unsigned iteration = 0; iteration < 2; ++iteration) {
        float2 delta;
        if (!inside(endpoint) || !displacement(flow, endpoint, extent, signY, delta)) { return false; }
        endpoint = target - fraction * delta;
    }
    float2 delta;
    return pairedDisplacement(flow, reverse, endpoint, extent, signY, delta) &&
           length((endpoint + fraction * delta - target) * extent) <= 1.5f;
}
}

kernel void visionInterpolationPrepare(texture2d<float> source [[texture(0)]],
                                       texture2d<float> chroma [[texture(1)]],
                                       texture2d<float, access::write> analysis [[texture(2)]],
                                       constant float4 &parameters [[buffer(0)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    float2 step = 1.0f / float2(analysis.get_width(), analysis.get_height());
    float2 uv = (float2(gid) + 0.5f) * step;
    float2 offset = step * 0.25f;
    float3 rgb = (analysisColor(source, chroma, parameters, uv + offset) +
                  analysisColor(source, chroma, parameters, uv - offset) +
                  analysisColor(source, chroma, parameters, uv + float2(offset.x, -offset.y)) +
                  analysisColor(source, chroma, parameters, uv + float2(-offset.x, offset.y))) * 0.25f;
    analysis.write(float4(rgb, 1.0f), gid);
}

kernel void visionInterpolationValidate(texture2d<float> previous [[texture(0)]],
                                        texture2d<float> current [[texture(1)]],
                                        texture2d<float> forward [[texture(2)]],
                                        texture2d<float> backward [[texture(3)]],
                                        device float4 *samples [[buffer(0)]],
                                        constant uint2 &grid [[buffer(1)]],
                                        uint2 gid [[thread_position_in_grid]]) {
    float2 extent = float2(forward.get_width(), forward.get_height());
    float2 uv = (float2(gid) + 0.5f) / float2(grid);
    samples[gid.y * grid.x + gid.x] = float4(validatePair(previous, current, forward, backward, uv, extent, 1.0f),
                                              validatePair(previous, current, forward, backward, uv, extent, -1.0f));
}

kernel void visionInterpolationSynthesize(texture2d<float> previous [[texture(0)]],
                                          texture2d<float> current [[texture(1)]],
                                          texture2d<float, access::write> output [[texture(2)]],
                                          texture2d<float> forward [[texture(3)]],
                                          texture2d<float> backward [[texture(4)]],
                                          texture2d<float> previousAnalysis [[texture(5)]],
                                          texture2d<float> currentAnalysis [[texture(6)]],
                                          constant float4 &parameters [[buffer(0)]],
                                          uint2 gid [[thread_position_in_grid]]) {
    float2 extent = float2(forward.get_width(), forward.get_height());
    float2 planeUV = (float2(gid) + 0.5f) / float2(output.get_width(), output.get_height());
    float2 target = planeUV + parameters.xy;
    float phase = parameters.w;
    float2 from;
    float2 to;
    bool hasPrevious = inverseWarp(forward, backward, target, extent, parameters.z, phase, from);
    bool hasCurrent = inverseWarp(backward, forward, target, extent, parameters.z, 1.0f - phase, to);
    if (hasPrevious && hasCurrent) {
        // Distinct surfaces can both appear consistent across a motion boundary.
        // Preserve a single surface when their warped colors disagree.
        float residual = colorResidual(previousAnalysis.sample(linearClamp, from).rgb,
                                       currentAnalysis.sample(linearClamp, to).rgb);
        if (residual < 0.16f) {
            float4 a = previous.sample(linearClamp, from - parameters.xy);
            float4 b = current.sample(linearClamp, to - parameters.xy);
            output.write(mix(a, b, phase), gid);
            return;
        }
    }
    if (hasCurrent && (!hasPrevious || phase >= 0.5f)) {
        output.write(current.sample(linearClamp, to - parameters.xy), gid);
    } else if (hasPrevious) {
        output.write(previous.sample(linearClamp, from - parameters.xy), gid);
    } else {
        float4 nearest = phase < 0.5f ? previous.sample(linearClamp, planeUV) : current.sample(linearClamp, planeUV);
        output.write(nearest, gid);
    }
}
