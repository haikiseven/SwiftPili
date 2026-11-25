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
    uint tapStep;      // >= 1 (1 for <1.6x scale, 2 for >=1.6x e.g. 1080p->4K)
    uint splitCompare; // 0 = full enhanced, 1 = left bilinear original / right enhanced
};

struct RCASNV12Params {
    float strength;
    uint colorMatrix;  // 0 = BT.709, 1 = BT.601, 2 = BT.2020
    uint tapStep;      // >= 1
    uint splitCompare; // 0 = full enhanced, 1 = left bilinear original / right enhanced
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
static inline float3 evaluateRCASFromSamples(
    float3 c,
    float3 n,
    float3 s,
    float3 w,
    float3 e,
    float strength
) {
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

    float weight = lobe * denoise * strength;
    float3 sharpened = (c + weight * (n + s + w + e)) / (1.0f + 4.0f * weight);
    // AMD FidelityFX RCAS relies on hitMin/hitMax anti-ringing limits rather than [mn5, mx5]
    // clamping (clamping to [mn5, mx5] erases edge contrast enhancement on local extrema).
    return clamp(sharpened, 0.0f, 1.0f);
}

static inline float3 evaluateRCAS(
    texture2d<float, access::read> inTexture,
    uint cx,
    uint cy,
    uint maxX,
    uint maxY,
    uint tapStep,
    float strength
) {
    float3 c = inTexture.read(uint2(cx, cy)).rgb;
    if (strength <= 0.001f) {
        return c;
    }
    uint step = max(tapStep, 1u);
    uint ny = cy >= step ? cy - step : 0u;
    uint sy = min(cy + step, maxY);
    uint wx = cx >= step ? cx - step : 0u;
    uint ex = min(cx + step, maxX);
    float3 n = inTexture.read(uint2(cx, ny)).rgb;
    float3 s = inTexture.read(uint2(cx, sy)).rgb;
    float3 w = inTexture.read(uint2(wx, cy)).rgb;
    float3 e = inTexture.read(uint2(ex, cy)).rgb;
    return evaluateRCASFromSamples(c, n, s, w, e, strength);
}

static inline float3 sampleOriginalBilinear(
    texture2d<float, access::sample> originalTexture,
    uint px,
    uint py,
    uint outWidth,
    uint outHeight
) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(px, py) + float2(0.5f, 0.5f))
        / float2(max(outWidth, 1u), max(outHeight, 1u));
    return originalTexture.sample(linearSampler, uv).rgb;
}

static inline float3 applySplitDivider(
    float3 rgb,
    uint px,
    uint splitX,
    uint whiteHalfWidth
) {
    int dist = abs(int(px) - int(splitX));
    if (dist <= int(whiteHalfWidth)) {
        return mix(rgb, float3(1.0f, 1.0f, 1.0f), 0.88f);
    }
    if (dist == int(whiteHalfWidth) + 1) {
        return rgb * 0.55f;
    }
    return rgb;
}

kernel void rcasSharpen(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    texture2d<float, access::sample> originalTexture [[texture(2)]],
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

    float alpha = inTexture.read(uint2(cx, cy)).a;
    uint splitX = width / 2u;
    uint whiteHalfWidth = (width >= 2560u) ? 1u : 0u;
    float3 result;
    if (params.splitCompare != 0u && gid.x < splitX) {
        result = sampleOriginalBilinear(originalTexture, gid.x, gid.y, width, height);
    } else {
        result = evaluateRCAS(inTexture, cx, cy, maxX, maxY, params.tapStep, params.strength);
    }
    if (params.splitCompare != 0u) {
        result = applySplitDivider(result, gid.x, splitX, whiteHalfWidth);
    }
    outTexture.write(float4(result, alpha), gid);
}

// Fused RCAS sharpening + BGRA/RGBA -> video-range NV12 (420v) conversion,
// dispatched over the 4:2:0 chroma grid so each thread writes one 2x2 luma block + 1 CbCr texel.
// Uses a 12-tap shared neighborhood when tapStep == 1, and scale-aware 5-tap RCAS when tapStep > 1.
// Optionally renders a real-time split-screen A/B comparison (left: bilinear original, right: enhanced).
kernel void rcasToNV12(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outY [[texture(1)]],
    texture2d<float, access::write> outCbCr [[texture(2)]],
    texture2d<float, access::sample> originalTexture [[texture(3)]],
    constant RCASNV12Params &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint chromaWidth = outCbCr.get_width();
    uint chromaHeight = outCbCr.get_height();
    if (gid.x >= chromaWidth || gid.y >= chromaHeight) {
        return;
    }
    uint lumaWidth = outY.get_width();
    uint lumaHeight = outY.get_height();
    uint maxX = max(inTexture.get_width(), 1u) - 1;
    uint maxY = max(inTexture.get_height(), 1u) - 1;

    uint bx = gid.x * 2;
    uint by = gid.y * 2;
    uint x0 = min(bx, maxX);
    uint x1 = min(bx + 1, maxX);
    uint y0 = min(by, maxY);
    uint y1 = min(by + 1, maxY);

    uint splitX = lumaWidth / 2u;
    uint whiteHalfWidth = (lumaWidth >= 2560u) ? 1u : 0u;
    float3 rgb00, rgb10, rgb01, rgb11;

    if (params.splitCompare != 0u && (bx + 1u) < splitX) {
        rgb00 = sampleOriginalBilinear(originalTexture, bx, by, lumaWidth, lumaHeight);
        rgb10 = sampleOriginalBilinear(originalTexture, bx + 1u, by, lumaWidth, lumaHeight);
        rgb01 = sampleOriginalBilinear(originalTexture, bx, by + 1u, lumaWidth, lumaHeight);
        rgb11 = sampleOriginalBilinear(originalTexture, bx + 1u, by + 1u, lumaWidth, lumaHeight);
    } else if (params.splitCompare != 0u && bx < splitX) {
        rgb00 = sampleOriginalBilinear(originalTexture, bx, by, lumaWidth, lumaHeight);
        rgb01 = sampleOriginalBilinear(originalTexture, bx, by + 1u, lumaWidth, lumaHeight);
        rgb10 = evaluateRCAS(inTexture, x1, y0, maxX, maxY, params.tapStep, params.strength);
        rgb11 = evaluateRCAS(inTexture, x1, y1, maxX, maxY, params.tapStep, params.strength);
    } else if (params.strength <= 0.001f) {
        rgb00 = inTexture.read(uint2(x0, y0)).rgb;
        rgb10 = inTexture.read(uint2(x1, y0)).rgb;
        rgb01 = inTexture.read(uint2(x0, y1)).rgb;
        rgb11 = inTexture.read(uint2(x1, y1)).rgb;
    } else if (params.tapStep <= 1u) {
        float3 c00 = inTexture.read(uint2(x0, y0)).rgb;
        float3 c10 = inTexture.read(uint2(x1, y0)).rgb;
        float3 c01 = inTexture.read(uint2(x0, y1)).rgb;
        float3 c11 = inTexture.read(uint2(x1, y1)).rgb;

        uint xm1 = x0 > 0 ? x0 - 1 : 0;
        uint x2 = min(x1 + 1, maxX);
        uint ym1 = y0 > 0 ? y0 - 1 : 0;
        uint y2 = min(y1 + 1, maxY);

        float3 t0 = inTexture.read(uint2(x0, ym1)).rgb;
        float3 t1 = inTexture.read(uint2(x1, ym1)).rgb;
        float3 b0 = inTexture.read(uint2(x0, y2)).rgb;
        float3 b1 = inTexture.read(uint2(x1, y2)).rgb;
        float3 l0 = inTexture.read(uint2(xm1, y0)).rgb;
        float3 l1 = inTexture.read(uint2(xm1, y1)).rgb;
        float3 r0 = inTexture.read(uint2(x2, y0)).rgb;
        float3 r1 = inTexture.read(uint2(x2, y1)).rgb;

        float3 w10 = (x1 > x0) ? c00 : l0;
        float3 w11 = (x1 > x0) ? c01 : l1;
        float3 n01 = (y1 > y0) ? c00 : t0;
        float3 n11 = (y1 > y0) ? c10 : t1;

        rgb00 = evaluateRCASFromSamples(c00, t0, c01, l0, c10, params.strength);
        rgb10 = evaluateRCASFromSamples(c10, t1, c11, w10, r0, params.strength);
        rgb01 = evaluateRCASFromSamples(c01, n01, b0, l1, c11, params.strength);
        rgb11 = evaluateRCASFromSamples(c11, n11, b1, w11, r1, params.strength);
    } else {
        rgb00 = evaluateRCAS(inTexture, x0, y0, maxX, maxY, params.tapStep, params.strength);
        rgb10 = evaluateRCAS(inTexture, x1, y0, maxX, maxY, params.tapStep, params.strength);
        rgb01 = evaluateRCAS(inTexture, x0, y1, maxX, maxY, params.tapStep, params.strength);
        rgb11 = evaluateRCAS(inTexture, x1, y1, maxX, maxY, params.tapStep, params.strength);
    }

    if (params.splitCompare != 0u) {
        rgb00 = applySplitDivider(rgb00, bx, splitX, whiteHalfWidth);
        rgb10 = applySplitDivider(rgb10, bx + 1u, splitX, whiteHalfWidth);
        rgb01 = applySplitDivider(rgb01, bx, splitX, whiteHalfWidth);
        rgb11 = applySplitDivider(rgb11, bx + 1u, splitX, whiteHalfWidth);
    }

    float3 lumaCoeff;
    float cbDiv, crDiv;
    if (params.colorMatrix == 1) {
        // BT.601
        lumaCoeff = float3(0.299f, 0.587f, 0.114f);
        cbDiv = 1.772f;
        crDiv = 1.402f;
    } else if (params.colorMatrix == 2) {
        // BT.2020
        lumaCoeff = float3(0.2627f, 0.6780f, 0.0593f);
        cbDiv = 1.8814f;
        crDiv = 1.4746f;
    } else {
        // BT.709
        lumaCoeff = float3(0.2126f, 0.7152f, 0.0722f);
        cbDiv = 1.8556f;
        crDiv = 1.5748f;
    }

    const float yScale = 219.0f / 255.0f;
    const float yOffset = 16.0f / 255.0f;
    const float cScale = 224.0f / 255.0f;
    const float cOffset = 128.0f / 255.0f;

    if (bx < lumaWidth && by < lumaHeight) {
        float y = clamp(dot(rgb00, lumaCoeff) * yScale + yOffset, 0.0f, 1.0f);
        outY.write(float4(y, 0.0f, 0.0f, 1.0f), uint2(bx, by));
    }
    if (bx + 1 < lumaWidth && by < lumaHeight) {
        float y = clamp(dot(rgb10, lumaCoeff) * yScale + yOffset, 0.0f, 1.0f);
        outY.write(float4(y, 0.0f, 0.0f, 1.0f), uint2(bx + 1, by));
    }
    if (bx < lumaWidth && by + 1 < lumaHeight) {
        float y = clamp(dot(rgb01, lumaCoeff) * yScale + yOffset, 0.0f, 1.0f);
        outY.write(float4(y, 0.0f, 0.0f, 1.0f), uint2(bx, by + 1));
    }
    if (bx + 1 < lumaWidth && by + 1 < lumaHeight) {
        float y = clamp(dot(rgb11, lumaCoeff) * yScale + yOffset, 0.0f, 1.0f);
        outY.write(float4(y, 0.0f, 0.0f, 1.0f), uint2(bx + 1, by + 1));
    }

    float3 avg = 0.25f * (rgb00 + rgb10 + rgb01 + rgb11);
    float yAvg = dot(avg, lumaCoeff);
    float cb = clamp(((avg.b - yAvg) / cbDiv) * cScale + cOffset, 0.0f, 1.0f);
    float cr = clamp(((avg.r - yAvg) / crDiv) * cScale + cOffset, 0.0f, 1.0f);
    outCbCr.write(float4(cb, cr, 0.0f, 1.0f), gid);
}
