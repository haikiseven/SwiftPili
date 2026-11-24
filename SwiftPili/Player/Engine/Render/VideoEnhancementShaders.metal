#include <metal_stdlib>
using namespace metal;

struct NV12ConvertParams {
    uint fullRange;
    uint colorMatrix; // 0 = BT.709, 1 = BT.601, 2 = BT.2020
    float chromaOffsetX;
    float chromaOffsetY;
};

struct NV12RangeConvertParams {
    uint fullToVideo; // 1 = 420f -> 420v, 0 = 420v -> 420f
};

struct NV12StageCopyParams {
    uint activeWidth;
    uint activeHeight;
    uint padLeft;
    uint padTop;
};

struct RCASParams {
    float strength;
};

kernel void nv12ToBGRA(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::sample> cbcrTexture [[texture(1)]],
    texture2d<float, access::write> outTexture [[texture(2)]],
    constant NV12ConvertParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint outWidth = outTexture.get_width();
    uint outHeight = outTexture.get_height();
    if (gid.x >= outWidth || gid.y >= outHeight) {
        return;
    }
    uint srcWidth = max(yTexture.get_width(), 1u);
    uint srcHeight = max(yTexture.get_height(), 1u);
    uint2 activeCoord = min(gid, uint2(srcWidth - 1, srcHeight - 1));

    constexpr sampler chromaSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float y = yTexture.read(activeCoord).r;
    // MPEG-2 / H.264 / HEVC / AV1 default left-sited 4:2:0 uses chromaOffset = (1.0, 0.5)
    // so even columns co-site exactly with chroma texel centers (i + 0.5) / (W / 2) = (2*i + 1) / W.
    float2 uv = (float2(activeCoord) + float2(params.chromaOffsetX, params.chromaOffsetY))
        / float2(srcWidth, srcHeight);
    float2 cbcr = cbcrTexture.sample(chromaSampler, uv).rg - float2(0.5f, 0.5f);
    float yAdj = params.fullRange != 0 ? y : clamp((y - 16.0f / 255.0f) * (255.0f / 219.0f), 0.0f, 1.0f);
    float cb = params.fullRange != 0 ? cbcr.x : cbcr.x * (255.0f / 224.0f);
    float cr = params.fullRange != 0 ? cbcr.y : cbcr.y * (255.0f / 224.0f);

    float crv, cgu, cgv, cbu;
    if (params.colorMatrix == 1) {
        // BT.601
        crv = 1.402f;
        cgu = 0.344136f;
        cgv = 0.714136f;
        cbu = 1.772f;
    } else if (params.colorMatrix == 2) {
        // BT.2020
        crv = 1.4746f;
        cgu = 0.164553f;
        cgv = 0.571353f;
        cbu = 1.8814f;
    } else {
        // BT.709
        crv = 1.5748f;
        cgu = 0.187324f;
        cgv = 0.468124f;
        cbu = 1.8556f;
    }

    float r = clamp(yAdj + crv * cr, 0.0f, 1.0f);
    float g = clamp(yAdj - cgu * cb - cgv * cr, 0.0f, 1.0f);
    float b = clamp(yAdj + cbu * cb, 0.0f, 1.0f);
    outTexture.write(float4(r, g, b, 1.0f), gid);
}

kernel void nv12RangeConvertY(
    texture2d<float, access::read> inY [[texture(0)]],
    texture2d<float, access::write> outY [[texture(1)]],
    constant NV12RangeConvertParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outY.get_width() || gid.y >= outY.get_height()) {
        return;
    }
    uint2 srcCoord = min(gid, uint2(max(inY.get_width(), 1u) - 1, max(inY.get_height(), 1u) - 1));
    float y = inY.read(srcCoord).r;
    float converted = params.fullToVideo != 0
        ? clamp(y * (219.0f / 255.0f) + (16.0f / 255.0f), 0.0f, 1.0f)
        : clamp((y - (16.0f / 255.0f)) * (255.0f / 219.0f), 0.0f, 1.0f);
    outY.write(float4(converted, 0.0f, 0.0f, 1.0f), gid);
}

kernel void nv12RangeConvertCbCr(
    texture2d<float, access::read> inCbCr [[texture(0)]],
    texture2d<float, access::write> outCbCr [[texture(1)]],
    constant NV12RangeConvertParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outCbCr.get_width() || gid.y >= outCbCr.get_height()) {
        return;
    }
    uint2 srcCoord = min(gid, uint2(max(inCbCr.get_width(), 1u) - 1, max(inCbCr.get_height(), 1u) - 1));
    float2 cbcr = inCbCr.read(srcCoord).rg;
    const float2 center = float2(128.0f / 255.0f);
    float2 converted = params.fullToVideo != 0
        ? clamp((cbcr - center) * (224.0f / 255.0f) + center, 0.0f, 1.0f)
        : clamp((cbcr - center) * (255.0f / 224.0f) + center, 0.0f, 1.0f);
    outCbCr.write(float4(converted.x, converted.y, 0.0f, 1.0f), gid);
}

// Copies active luma pixels and clamp-fills any extended padding pixels exposed in `outY`.
kernel void nv12StageCopyY(
    texture2d<float, access::read> inY [[texture(0)]],
    texture2d<float, access::write> outY [[texture(1)]],
    constant NV12StageCopyParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outY.get_width() || gid.y >= outY.get_height()) {
        return;
    }
    int maxX = max(0, int(min(inY.get_width(), params.activeWidth)) - 1);
    int maxY = max(0, int(min(inY.get_height(), params.activeHeight)) - 1);
    uint sx = uint(clamp(int(gid.x) - int(params.padLeft), 0, maxX));
    uint sy = uint(clamp(int(gid.y) - int(params.padTop), 0, maxY));
    outY.write(inY.read(uint2(sx, sy)), gid);
}

// Copies active 4:2:0 CbCr pixels and clamp-fills any extended padding pixels exposed in `outCbCr`.
kernel void nv12StageCopyCbCr(
    texture2d<float, access::read> inCbCr [[texture(0)]],
    texture2d<float, access::write> outCbCr [[texture(1)]],
    constant NV12StageCopyParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outCbCr.get_width() || gid.y >= outCbCr.get_height()) {
        return;
    }
    int maxX = max(0, int(min(inCbCr.get_width(), params.activeWidth)) - 1);
    int maxY = max(0, int(min(inCbCr.get_height(), params.activeHeight)) - 1);
    uint sx = uint(clamp(int(gid.x) - int(params.padLeft), 0, maxX));
    uint sy = uint(clamp(int(gid.y) - int(params.padTop), 0, maxY));
    outCbCr.write(inCbCr.read(uint2(sx, sy)), gid);
}

// AMD FidelityFX RCAS-style 5-tap contrast-adaptive sharpening with anti-ringing clamping
// and isolated compression-speckle attenuation.
kernel void rcasSharpen(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant RCASParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    uint maxX = max(inTexture.get_width(), 1u) - 1;
    uint maxY = max(inTexture.get_height(), 1u) - 1;
    uint cx = min(gid.x, maxX);
    uint cy = min(gid.y, maxY);

    float4 centerSample = inTexture.read(uint2(cx, cy));
    float3 c = centerSample.rgb;
    float3 n = inTexture.read(uint2(cx, cy > 0 ? cy - 1 : 0)).rgb;
    float3 s = inTexture.read(uint2(cx, min(cy + 1, maxY))).rgb;
    float3 w = inTexture.read(uint2(cx > 0 ? cx - 1 : 0, cy)).rgb;
    float3 e = inTexture.read(uint2(min(cx + 1, maxX), cy)).rgb;

    float3 mn4 = min(min(n, s), min(w, e));
    float3 mx4 = max(max(n, s), max(w, e));
    float3 mn5 = min(mn4, c);
    float3 mx5 = max(mx4, c);

    // Per-channel anti-ringing limits merged to a single RGB lobe to avoid chroma fringes.
    float3 hitMin = mn5 / max(4.0f * mx4, float3(1e-5f));
    float3 hitMax = (1.0f - mx5) / min(4.0f * mn4 - 4.0f, float3(-1e-5f));
    float3 lobeRGB = max(-hitMin, hitMax);
    float lobe = max(-0.1875f, min(max(lobeRGB.r, max(lobeRGB.g, lobeRGB.b)), 0.0f));

    // Gently attenuate sharpening on isolated 1px compression speckles while preserving edges.
    float cL = 0.25f * c.r + 0.5f * c.g + 0.25f * c.b;
    float nL = 0.25f * n.r + 0.5f * n.g + 0.25f * n.b;
    float sL = 0.25f * s.r + 0.5f * s.g + 0.25f * s.b;
    float wL = 0.25f * w.r + 0.5f * w.g + 0.25f * w.b;
    float eL = 0.25f * e.r + 0.5f * e.g + 0.25f * e.b;
    float nz = 0.25f * (nL + sL + wL + eL) - cL;
    float rangeL = max(max(max(nL, sL), max(wL, eL)), cL) - min(min(min(nL, sL), min(wL, eL)), cL);
    float denoise = -0.5f * clamp(abs(nz) / max(rangeL, 1e-4f), 0.0f, 1.0f) + 1.0f;

    float weight = lobe * denoise * params.strength;
    float3 sharpened = (c + weight * (n + s + w + e)) / (1.0f + 4.0f * weight);
    float3 result = clamp(sharpened, mn5, mx5);
    outTexture.write(float4(result, centerSample.a), gid);
}
