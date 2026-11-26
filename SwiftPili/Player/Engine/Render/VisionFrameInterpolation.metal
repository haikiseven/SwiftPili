#include <metal_stdlib>
using namespace metal;

namespace {
constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
constant uint kEmptySplat = 0xFFFFFFFFu;
constant float kMaxDisplacementFraction = 0.30f;

// Phase-field synthesis modes stored in `phaseField.z`:
//   0.0 = invalid (hard cut / chaotic fallback)
//   1.0 = bidirectional matched surface (`mix(prevWarped, currWarped, phase)`)
//   2.0 = disoccluded hole uncovered in `current` (warp predominantly from `current`)
//   3.0 = soon-to-be-occluded surface visible in `previous` (warp predominantly from `previous`)
constant float kModeBidirectional = 1.0f;
constant float kModeCurrUncovered = 2.0f;
constant float kModePrevVisible = 3.0f;

inline bool isFiniteFloat2(float2 v) {
    return all((as_type<uint2>(v) & 0x7f800000u) != 0x7f800000u);
}

inline bool inside(float2 uv) {
    return all(uv >= 0.0f) && all(uv <= 1.0f);
}

// Reconstructs normalized perceptual RGB in [0, 1] for Vision optical flow & residual matching.
// Works seamlessly for BGRA, 8-bit NV12, 10-bit SDR P010, and 10-bit PQ/HLG HDR (since PQ/HLG
// code values are already perceptually non-linear in [0, 1]).
inline float3 analysisColor(texture2d<float> source, texture2d<float> chroma, float4 parameters, float2 uv) {
    float4 sample = source.sample(linearClamp, uv);
    float mode = parameters.z;
    if (mode < 0.5f) {
        return saturate(sample.rgb);
    }
    float y = sample.r;
    float2 cbcr = chroma.sample(linearClamp, uv - parameters.xy).rg - 0.5f;
    if (mode > 1.5f) {
        y = (y - (16.0f / 255.0f)) * (255.0f / 219.0f);
        cbcr *= (255.0f / 224.0f);
    }
    if (parameters.w > 0.5f) {
        // BT.2020
        return saturate(float3(
            y + 1.4746f * cbcr.y,
            y - 0.164553f * cbcr.x - 0.571353f * cbcr.y,
            y + 1.8814f * cbcr.x
        ));
    }
    // BT.709
    return saturate(float3(
        y + 1.5748f * cbcr.y,
        y - 0.187324f * cbcr.x - 0.468124f * cbcr.y,
        y + 1.8556f * cbcr.x
    ));
}

inline float colorResidual(float3 a, float3 b) {
    float3 d = abs(a - b);
    return max(d.r, max(d.g, d.b));
}

inline float normalizeLuma(float rawY, float videoRange) {
    if (videoRange > 0.5f) {
        return saturate((rawY - (16.0f / 255.0f)) * (255.0f / 219.0f));
    }
    return saturate(rawY);
}

inline float bgraPerceptualLuma(float4 rgba) {
    return dot(rgba.rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

inline float sampleLuma(texture2d<float> tex, float2 uv, float isBGRA, float videoRange) {
    if (isBGRA > 0.5f) {
        return bgraPerceptualLuma(tex.sample(linearClamp, uv));
    }
    return normalizeLuma(tex.sample(linearClamp, uv).r, videoRange);
}

// Quantizes 10-bit P010 (`x420` / `xf20`) output cleanly onto the upper 10 MSB bits [15:6]
// so low 6 padding bits stay strictly zero on hardware display layers.
inline float quantize10BitMSB(float v) {
    float code10 = rint(saturate(v) * (65535.0f / 64.0f));
    code10 = min(code10, 1023.0f);
    return (code10 * 64.0f) / 65535.0f;
}

inline float2 quantize10BitMSB2(float2 v) {
    return float2(quantize10BitMSB(v.x), quantize10BitMSB(v.y));
}

inline bool sampleFlowUV(texture2d<float> flow, float2 uv, float2 extent, float signY, thread float2 &delta) {
    float2 pixels = flow.sample(linearClamp, uv).rg;
    if (!isFiniteFloat2(pixels)) { return false; }
    if (any(abs(pixels) > extent * kMaxDisplacementFraction)) { return false; }
    delta = float2(pixels.x, pixels.y * signY) / extent;
    return true;
}

inline float median9(thread float *v) {
    // Partial sorting network for exact median of 9 elements.
    #define SWAP(i, j) { float t = min(v[i], v[j]); v[j] = max(v[i], v[j]); v[i] = t; }
    SWAP(1, 2); SWAP(4, 5); SWAP(7, 8);
    SWAP(0, 1); SWAP(3, 4); SWAP(6, 7);
    SWAP(1, 2); SWAP(4, 5); SWAP(7, 8);
    SWAP(0, 3); SWAP(5, 8); SWAP(4, 7);
    SWAP(3, 6); SWAP(1, 4); SWAP(2, 5);
    SWAP(4, 7); SWAP(4, 2); SWAP(6, 4);
    SWAP(4, 2);
    #undef SWAP
    return v[4];
}

// Evaluates discrete 4-corner phaseField candidates PLUS an explicit `v = (0, 0)` stationary candidate
// at motion boundaries, followed by a local 5-tap zero-motion vs 3-tap warped-motion dominance test
// so stationary video content never wobbles from Vision's coarse-grid motion halo or sub-pixel noise.
inline bool resolvePixelVelocity(
    texture2d<float> phaseField,
    float2 uv,
    float2 flowExtent,
    float phase,
    float zeroCrossAvg,
    float zeroCrossMax,
    float2 fullExtent,
    texture2d<float> prevLumaTex,
    texture2d<float> currLumaTex,
    float isBGRA,
    float videoRange,
    thread float2 &bestV,
    thread float &outMode
) {
    float2 fCoord = uv * flowExtent - 0.5f;
    int2 base = int2(floor(fCoord));
    float2 frac = saturate(fCoord - float2(base));
    int2 maxC = int2(flowExtent) - 1;

    float4 c00 = phaseField.read(uint2(clamp(base, int2(0), maxC)));
    float4 c10 = phaseField.read(uint2(clamp(base + int2(1, 0), int2(0), maxC)));
    float4 c01 = phaseField.read(uint2(clamp(base + int2(0, 1), int2(0), maxC)));
    float4 c11 = phaseField.read(uint2(clamp(base + int2(1, 1), int2(0), maxC)));

    bool v00 = c00.z > 0.5f;
    bool v10 = c10.z > 0.5f;
    bool v01 = c01.z > 0.5f;
    bool v11 = c11.z > 0.5f;

    if (!(v00 || v10 || v01 || v11)) {
        outMode = 0.0f;
        return false;
    }

    bool sameMode = abs(c00.z - c10.z) < 0.25f && abs(c00.z - c01.z) < 0.25f && abs(c00.z - c11.z) < 0.25f;

    // Smooth interior fast-path: all 4 splatted corners valid, same mode, and consistent within 1.5 analysis px.
    if (v00 && v10 && v01 && v11 && sameMode) {
        float2 minV = min(min(c00.xy, c10.xy), min(c01.xy, c11.xy));
        float2 maxV = max(max(c00.xy, c10.xy), max(c01.xy, c11.xy));
        if (length((maxV - minV) * flowExtent) <= 1.5f) {
            bestV = mix(mix(c00.xy, c10.xy, frac.x), mix(c01.xy, c11.xy, frac.x), frac.y);
            outMode = c00.z;
        } else {
            bestV = float2(1e9f);
            outMode = kModeBidirectional;
        }
    } else {
        bestV = float2(1e9f);
        outMode = kModeBidirectional;
    }

    if (bestV.x > 1e8f) {
        // Silhouette / boundary competition: test the 4 coarse corners AND explicit zero-motion `(0, 0)`
        // so stationary background pixels inside a 4x4 analysis cell aren't dragged by adjacent foreground.
        float4 candidates[5] = {
            c00, c10, c01, c11,
            float4(0.0f, 0.0f, kModeBidirectional, zeroCrossAvg)
        };
        bool flags[5] = { v00, v10, v01, v11, zeroCrossMax <= 0.065f };
        float bestErr = 1e9f;
        bool found = false;
        for (uint i = 0; i < 5; ++i) {
            if (!flags[i]) { continue; }
            float2 cand = candidates[i].xy;
            float candMode = candidates[i].z;
            float2 pUV = clamp(uv - phase * cand, 0.0f, 1.0f);
            float2 cUV = clamp(uv + (1.0f - phase) * cand, 0.0f, 1.0f);
            float lp = sampleLuma(prevLumaTex, pUV, isBGRA, videoRange);
            float lc = sampleLuma(currLumaTex, cUV, isBGRA, videoRange);
            float rawMatch = abs(lp - lc);
            float err = (candMode < 1.5f)
                ? (rawMatch + 0.06f * candidates[i].w)
                : (min(rawMatch, 0.16f) + 0.10f);
            if (err < bestErr) {
                bestErr = err;
                bestV = cand;
                outMode = candMode;
                found = true;
            }
        }
        if (!found) {
            outMode = 0.0f;
            return false;
        }
    }

    // Local per-pixel Zero-Motion Dominance + Sub-Pixel Deadzone:
    // Compares local 5-tap stationary error (`zeroCrossAvg`) against 3-tap warped error (`warpedAvg`).
    float pixelMotion = length(bestV * fullExtent);
    if (pixelMotion > 0.0f) {
        // 1) Sub-pixel deadzone (<0.65 full-res px) when pixel is locally stationary within codec noise.
        if (pixelMotion < 0.65f && zeroCrossAvg <= 0.028f && zeroCrossMax <= 0.055f) {
            bestV = float2(0.0f);
            outMode = kModeBidirectional;
            return true;
        }

        // 2) Only test stationary lock when the 5-tap cross did NOT experience an object entering/leaving
        //    (`zeroCrossMax <= 0.095`), leaving true motion edges & occlusions 100% untouched.
        if (zeroCrossAvg <= 0.045f && zeroCrossMax <= 0.095f) {
            float2 stepFull = 1.0f / max(fullExtent, float2(1.0f));
            float2 pC = clamp(uv - phase * bestV, 0.0f, 1.0f);
            float2 cC = clamp(uv + (1.0f - phase) * bestV, 0.0f, 1.0f);
            float2 pR = clamp(pC + float2(stepFull.x, 0.0f), 0.0f, 1.0f);
            float2 cR = clamp(cC + float2(stepFull.x, 0.0f), 0.0f, 1.0f);
            float2 pD = clamp(pC + float2(0.0f, stepFull.y), 0.0f, 1.0f);
            float2 cD = clamp(cC + float2(0.0f, stepFull.y), 0.0f, 1.0f);

            float wC = abs(sampleLuma(prevLumaTex, pC, isBGRA, videoRange) - sampleLuma(currLumaTex, cC, isBGRA, videoRange));
            float wR = abs(sampleLuma(prevLumaTex, pR, isBGRA, videoRange) - sampleLuma(currLumaTex, cR, isBGRA, videoRange));
            float wD = abs(sampleLuma(prevLumaTex, pD, isBGRA, videoRange) - sampleLuma(currLumaTex, cD, isBGRA, videoRange));
            float warpedAvg = (wC + wR + wD) * (1.0f / 3.0f);

            bool ultraStill = (zeroCrossAvg <= 0.010f && zeroCrossMax <= 0.022f)
                && !(warpedAvg < zeroCrossAvg * 0.55f - 0.002f);
            bool codecStill = (zeroCrossAvg <= 0.024f && zeroCrossMax <= 0.052f)
                && !(warpedAvg < zeroCrossAvg * 0.72f - 0.003f);
            bool haloWorse = (warpedAvg > zeroCrossAvg * 1.20f + 0.008f);

            if (ultraStill || codecStill || haloWorse) {
                bestV = float2(0.0f);
                outMode = kModeBidirectional;
            }
        }
    }

    return true;
}
}

// MARK: - 1. Analysis Frame Preparation (4-tap Anti-Aliased Perceptual BGRA for Vision)

kernel void visionInterpolationPrepare(texture2d<float> source [[texture(0)]],
                                       texture2d<float> chroma [[texture(1)]],
                                       texture2d<float, access::write> analysis [[texture(2)]],
                                       constant float4 &parameters [[buffer(0)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    uint w = analysis.get_width();
    uint h = analysis.get_height();
    if (gid.x >= w || gid.y >= h) { return; }

    float2 step = 1.0f / float2(w, h);
    float2 uv = (float2(gid) + 0.5f) * step;
    float2 offset = step * 0.25f;
    float3 rgb = 0.25f * (
        analysisColor(source, chroma, parameters, uv + offset) +
        analysisColor(source, chroma, parameters, uv - offset) +
        analysisColor(source, chroma, parameters, uv + float2(offset.x, -offset.y)) +
        analysisColor(source, chroma, parameters, uv + float2(-offset.x, offset.y))
    );
    analysis.write(float4(rgb, 1.0f), gid);
}

// Lightweight fallback block-matching flow estimator used in Simulator unit tests where Vision's
// ANE runtime is unavailable; device playback uses `VNGenerateOpticalFlowRequest`.
kernel void visionInterpolationCoarseFlow(texture2d<float> previous [[texture(0)]],
                                          texture2d<float> current [[texture(1)]],
                                          texture2d<half, access::write> flowOut [[texture(2)]],
                                          uint2 gid [[thread_position_in_grid]]) {
    int w = int(flowOut.get_width());
    int h = int(flowOut.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }

    int2 maxC = int2(w - 1, h - 1);
    int2 center = int2(gid);
    float3 refPatch[9];
    for (int py = -1; py <= 1; ++py) {
        for (int px = -1; px <= 1; ++px) {
            refPatch[(py + 1) * 3 + (px + 1)] = previous.read(uint2(clamp(center + int2(px * 2, py * 2), int2(0), maxC))).rgb;
        }
    }

    float bestCost = 1e9f;
    float2 bestVec = float2(0.0f);
    for (int dy = -20; dy <= 20; dy += 2) {
        for (int dx = -20; dx <= 20; dx += 2) {
            float sad = 0.0f;
            for (int py = -1; py <= 1; ++py) {
                for (int px = -1; px <= 1; ++px) {
                    float3 c = current.read(uint2(clamp(center + int2(dx + px * 2, dy + py * 2), int2(0), maxC))).rgb;
                    sad += colorResidual(refPatch[(py + 1) * 3 + (px + 1)], c);
                }
            }
            float cost = sad + 0.0018f * float(abs(dx) + abs(dy));
            if (cost < bestCost) {
                bestCost = cost;
                bestVec = float2(float(dx), float(dy));
            }
        }
    }
    int2 refineBase = int2(bestVec);
    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            int dx = refineBase.x + ox;
            int dy = refineBase.y + oy;
            float sad = 0.0f;
            for (int py = -1; py <= 1; ++py) {
                for (int px = -1; px <= 1; ++px) {
                    float3 c = current.read(uint2(clamp(center + int2(dx + px, dy + py), int2(0), maxC))).rgb;
                    float3 r = previous.read(uint2(clamp(center + int2(px, py), int2(0), maxC))).rgb;
                    sad += colorResidual(r, c);
                }
            }
            float cost = sad + 0.0014f * float(abs(dx) + abs(dy));
            if (cost < bestCost) {
                bestCost = cost;
                bestVec = float2(float(dx), float(dy));
            }
        }
    }
    flowOut.write(half4(half2(bestVec), 0.0h, 0.0h), gid);
}

// MARK: - 2. Zero-Readback GPU Sign Resolution & Hard Scene-Cut / Chaos Guard

kernel void visionInterpolationValidate(texture2d<float> previous [[texture(0)]],
                                        texture2d<float> current [[texture(1)]],
                                        texture2d<float> forward [[texture(2)]],
                                        device float4 *sceneStats [[buffer(0)]],
                                        uint2 tid [[thread_position_in_threadgroup]],
                                        uint2 tgSize [[threads_per_threadgroup]]) {
    threadgroup float4 partialA[256];
    threadgroup float3 partialB[256];
    uint linear = tid.y * tgSize.x + tid.x;
    uint count = tgSize.x * tgSize.y;

    float2 extent = float2(forward.get_width(), forward.get_height());
    float2 stepUV = 1.0f / max(extent, float2(1.0f));
    float2 uv = mix(float2(0.06f), float2(0.94f), (float2(tid) + 0.5f) / float2(tgSize));

    float3 p0 = previous.sample(linearClamp, uv).rgb;
    float3 p1 = current.sample(linearClamp, uv).rgb;
    float rawDiff = colorResidual(p0, p1);

    float2 fCenter = forward.sample(linearClamp, uv).rg;
    float2 fLeft = forward.sample(linearClamp, max(uv - float2(stepUV.x, 0.0f), float2(0.0f))).rg;
    float2 fRight = forward.sample(linearClamp, min(uv + float2(stepUV.x, 0.0f), float2(1.0f))).rg;
    float2 fUp = forward.sample(linearClamp, max(uv - float2(0.0f, stepUV.y), float2(0.0f))).rg;
    float2 fDown = forward.sample(linearClamp, min(uv + float2(0.0f, stepUV.y), float2(1.0f))).rg;

    // One-sided smoothness preserves fast silhouettes while catching chaotic alternating garbage fields.
    bool oneSidedSmooth = isFiniteFloat2(fCenter)
        && ((isFiniteFloat2(fRight) && length(fCenter - fRight) <= 8.0f)
            || (isFiniteFloat2(fLeft) && length(fCenter - fLeft) <= 8.0f))
        && ((isFiniteFloat2(fDown) && length(fCenter - fDown) <= 8.0f)
            || (isFiniteFloat2(fUp) && length(fCenter - fUp) <= 8.0f));

    float posRes = rawDiff;
    float posValid = 0.0f;
    float2 posDelta;
    if (oneSidedSmooth && sampleFlowUV(forward, uv, extent, 1.0f, posDelta) && inside(uv + posDelta)) {
        posRes = colorResidual(p0, current.sample(linearClamp, uv + posDelta).rgb);
        posValid = (posRes < 0.24f && posRes <= rawDiff + 0.06f) ? 1.0f : 0.0f;
    }

    float negRes = rawDiff;
    float negValid = 0.0f;
    float2 negDelta;
    if (oneSidedSmooth && sampleFlowUV(forward, uv, extent, -1.0f, negDelta) && inside(uv + negDelta)) {
        negRes = colorResidual(p0, current.sample(linearClamp, uv + negDelta).rgb);
        negValid = (negRes < 0.24f && negRes <= rawDiff + 0.06f) ? 1.0f : 0.0f;
    }

    partialA[linear] = float4(posRes, posValid, negRes, negValid);
    partialB[linear] = float3(rawDiff, oneSidedSmooth ? 1.0f : 0.0f, 1.0f);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = count >> 1; stride > 0; stride >>= 1) {
        if (linear < stride) {
            partialA[linear] += partialA[linear + stride];
            partialB[linear] += partialB[linear + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (linear == 0) {
        float denom = max(partialB[0].z, 1.0f);
        float avgPosRes = partialA[0].x / denom;
        float posValidFrac = partialA[0].y / denom;
        float avgNegRes = partialA[0].z / denom;
        float negValidFrac = partialA[0].w / denom;
        float avgRaw = partialB[0].x / denom;
        float smoothFrac = partialB[0].y / denom;

        float posScore = avgPosRes + (1.0f - posValidFrac) * 0.20f;
        float negScore = avgNegRes + (1.0f - negValidFrac) * 0.20f;
        bool useNegY = negScore < posScore - 0.030f;
        float bestSignY = useNegY ? -1.0f : 1.0f;
        float avgWarped = useNegY ? avgNegRes : avgPosRes;
        float validFraction = useNegY ? negValidFrac : posValidFrac;

        // Snap whole frame ONLY on genuine hard scene cuts / flashes or totally non-smooth chaotic fields.
        bool snapNearest = (smoothFrac < 0.25f)
            || (avgRaw > 0.28f && avgWarped > 0.20f && validFraction < 0.22f)
            || (avgRaw > 0.38f && avgWarped > 0.24f);

        sceneStats[0] = float4(snapNearest ? 1.0f : 0.0f, bestSignY, validFraction, avgWarped);
    }
}

// MARK: - 3. Outlier Median + Local 3x3 Patch Zero-Motion Dominance & Deadzone

kernel void visionInterpolationRegularizeFlow(texture2d<float> forward [[texture(0)]],
                                              texture2d<float> previous [[texture(1)]],
                                              texture2d<float> current [[texture(2)]],
                                              texture2d<half, access::write> cleanFlowOut [[texture(3)]],
                                              device const float4 *sceneStats [[buffer(0)]],
                                              uint2 gid [[thread_position_in_grid]]) {
    int w = int(cleanFlowOut.get_width());
    int h = int(cleanFlowOut.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }

    if (sceneStats[0].x > 0.5f) {
        cleanFlowOut.write(half4(0.0h, 0.0h, 1.0h, 0.0h), gid);
        return;
    }

    float signY = sceneStats[0].y;
    float2 extent = float2(w, h);
    float2 maxPixels = extent * kMaxDisplacementFraction;
    int2 maxC = int2(w - 1, h - 1);
    int2 center = int2(gid);

    float xs[9];
    float ys[9];
    int validNeighbors = 0;
    float zeroSum = 0.0f;
    float zeroMax = 0.0f;

    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            int idx = (oy + 1) * 3 + (ox + 1);
            uint2 nc = uint2(clamp(center + int2(ox, oy), int2(0), maxC));
            float2 raw = forward.read(nc).rg;
            float2 oriented = float2(raw.x, raw.y * signY);
            if (isFiniteFloat2(oriented) && all(abs(oriented) <= maxPixels)) {
                xs[idx] = oriented.x;
                ys[idx] = oriented.y;
                validNeighbors += 1;
            } else {
                xs[idx] = 0.0f;
                ys[idx] = 0.0f;
            }
            float d0 = colorResidual(previous.read(nc).rgb, current.read(nc).rgb);
            zeroSum += d0;
            zeroMax = max(zeroMax, d0);
        }
    }

    if (validNeighbors < 5) {
        cleanFlowOut.write(half4(0.0h, 0.0h, 1.0h, 0.0h), gid);
        return;
    }

    float medX = median9(xs);
    float medY = median9(ys);
    float2 medPixels = float2(medX, medY);
    float magPx = length(medPixels);
    float zeroPatchSAD = zeroSum * (1.0f / 9.0f);

    // 1. Sub-pixel noise deadzone on stationary patches (<0.22 analysis px ≈ <0.9 px at 1080p).
    if (magPx < 0.22f && zeroPatchSAD <= 0.028f && zeroMax <= 0.060f) {
        cleanFlowOut.write(half4(0.0h, 0.0h, half(zeroPatchSAD), half(kModeBidirectional)), gid);
        return;
    }

    // One-sided neighbor continuity preserves sharp moving silhouettes and thin fast objects while
    // rejecting isolated chaotic speckles where neither side agrees with `medPixels`.
    float2 fL = forward.read(uint2(clamp(center + int2(-1, 0), int2(0), maxC))).rg;
    float2 fR = forward.read(uint2(clamp(center + int2(1, 0), int2(0), maxC))).rg;
    float2 fU = forward.read(uint2(clamp(center + int2(0, -1), int2(0), maxC))).rg;
    float2 fD = forward.read(uint2(clamp(center + int2(0, 1), int2(0), maxC))).rg;
    fL.y *= signY; fR.y *= signY; fU.y *= signY; fD.y *= signY;

    float dL = isFiniteFloat2(fL) ? length(fL - medPixels) : 99.0f;
    float dR = isFiniteFloat2(fR) ? length(fR - medPixels) : 99.0f;
    float dU = isFiniteFloat2(fU) ? length(fU - medPixels) : 99.0f;
    float dD = isFiniteFloat2(fD) ? length(fD - medPixels) : 99.0f;
    float minCardH = min(dL, dR);
    float minCardV = min(dU, dD);

    float2 uv = (float2(gid) + 0.5f) / extent;
    float2 delta = medPixels / extent;
    float2 dstUV = uv + delta;

    // 2. Local 3-tap L-Patch Zero-Motion Dominance (66% fewer bilinear samples than full 3x3):
    //    When the 3x3 analysis block did not have an object enter/leave (`zeroMax <= 0.095`), compare
    //    warped 3-tap residual against stationary `(0, 0)` residual so Vision's motion-bleed halo
    //    and aperture drift cannot drag stationary video backgrounds or stationary body parts.
    if (magPx > 0.0f && zeroPatchSAD <= 0.048f && zeroMax <= 0.095f && inside(dstUV)) {
        float2 invExtent = 1.0f / extent;
        uint2 ncR = uint2(clamp(center + int2(1, 0), int2(0), maxC));
        uint2 ncD = uint2(clamp(center + int2(0, 1), int2(0), maxC));
        float wC = colorResidual(previous.read(gid).rgb, current.sample(linearClamp, dstUV).rgb);
        float wR = colorResidual(
            previous.read(ncR).rgb,
            current.sample(linearClamp, clamp((float2(ncR) + 0.5f) * invExtent + delta, 0.0f, 1.0f)).rgb
        );
        float wD = colorResidual(
            previous.read(ncD).rgb,
            current.sample(linearClamp, clamp((float2(ncD) + 0.5f) * invExtent + delta, 0.0f, 1.0f)).rgb
        );
        float warpedPatchSAD = (wC + wR + wD) * (1.0f / 3.0f);

        bool stillWithinNoise = (zeroPatchSAD <= 0.024f && zeroMax <= 0.058f)
            && !(warpedPatchSAD < zeroPatchSAD * 0.78f - 0.004f);
        bool haloDegradesMatch = (warpedPatchSAD > zeroPatchSAD * 1.22f + 0.010f);

        if (stillWithinNoise || haloDegradesMatch) {
            cleanFlowOut.write(half4(0.0h, 0.0h, half(zeroPatchSAD), half(kModeBidirectional)), gid);
            return;
        }
    }

    if (!inside(dstUV)) {
        // Exiting border surface: visible in `previous`, moves off-screen in `current`.
        bool coherentBorder = (minCardH <= 8.0f && minCardV <= 8.0f);
        cleanFlowOut.write(half4(half2(delta), 0.35h, coherentBorder ? half(kModePrevVisible) : 0.0h), gid);
        return;
    }

    float3 prevColor = previous.read(gid).rgb;
    float3 currColor = current.sample(linearClamp, dstUV).rgb;
    float err = colorResidual(prevColor, currColor);

    if ((minCardH > 8.0f || minCardV > 8.0f) && err > 0.24f) {
        cleanFlowOut.write(half4(0.0h, 0.0h, 1.0h, 0.0h), gid);
        return;
    }

    float mode = (err <= 0.28f) ? kModeBidirectional : kModePrevVisible;
    cleanFlowOut.write(half4(half2(delta), half(err), half(mode)), gid);
}

// MARK: - 4. Atomic Z-Buffered Forward Splatting & Background-Velocity Disocclusion Fill

kernel void visionInterpolationClearSplat(device uint *splatBuffer [[buffer(0)]],
                                          constant uint &elementCount [[buffer(1)]],
                                          uint gid [[thread_position_in_grid]]) {
    if (gid < elementCount) {
        splatBuffer[gid] = kEmptySplat;
    }
}

kernel void visionInterpolationSplatPhase(texture2d<float> cleanFlow [[texture(0)]],
                                          device atomic_uint *splatBuffer [[buffer(0)]],
                                          device const float4 *sceneStats [[buffer(1)]],
                                          constant float4 &params [[buffer(2)]],
                                          uint2 gid [[thread_position_in_grid]]) {
    uint w = cleanFlow.get_width();
    uint h = cleanFlow.get_height();
    if (gid.x >= w || gid.y >= h || sceneStats[0].x > 0.5f) { return; }

    float4 flowInfo = cleanFlow.read(gid);
    if (flowInfo.w < 0.5f) { return; }

    float phase = params.x;
    float2 extent = float2(w, h);
    float2 delta = flowInfo.xy;
    float err = saturate(flowInfo.z);
    bool isPrevOnly = flowInfo.w > 2.0f;

    // Project source texel center along `phase * delta` onto the intermediate frame grid.
    float2 projected = float2(gid) + phase * (delta * extent);
    int2 base = int2(floor(projected));
    float2 frac = projected - float2(base);

    // Lower 20 bits hold exact source linear index (< 1,048,576); upper 12 bits hold priority key.
    // Note: no artificial `-motionBonus` bias here so bloated moving halos cannot overwrite lower-error
    // stationary (`v = 0`) texels, while bidirectional foreground (`<=0.58`) still strictly beats
    // occluded `isPrevOnly` background (`>=0.65`).
    uint srcIndex = (gid.y * w + gid.x) & 0xFFFFFu;

    for (int oy = 0; oy <= 1; ++oy) {
        int ty = base.y + oy;
        if (ty < 0 || ty >= int(h)) { continue; }
        float wy = (oy == 0) ? (1.0f - frac.y) : frac.y;
        for (int ox = 0; ox <= 1; ++ox) {
            int tx = base.x + ox;
            if (tx < 0 || tx >= int(w)) { continue; }
            float wgt = wy * ((ox == 0) ? (1.0f - frac.x) : frac.x);
            if (wgt < 0.20f) { continue; }

            float score = isPrevOnly
                ? clamp(0.68f + err * 0.22f + (1.0f - wgt) * 0.08f, 0.65f, 0.99f)
                : clamp(err * 1.45f + (1.0f - wgt) * 0.12f + 0.02f, 0.0f, 0.58f);
            uint priority12 = min(uint(score * 4093.0f + 0.5f), 4094u);
            uint packed = (priority12 << 20) | srcIndex;
            uint dstLinear = uint(ty) * w + uint(tx);
            atomic_fetch_min_explicit(&splatBuffer[dstLinear], packed, memory_order_relaxed);
        }
    }
}

kernel void visionInterpolationResolvePhase(texture2d<float> cleanFlow [[texture(0)]],
                                            device const uint *splatBuffer [[buffer(0)]],
                                            device const float4 *sceneStats [[buffer(1)]],
                                            texture2d<half, access::write> phaseFieldOut [[texture(1)]],
                                            uint2 gid [[thread_position_in_grid]]) {
    uint w = phaseFieldOut.get_width();
    uint h = phaseFieldOut.get_height();
    if (gid.x >= w || gid.y >= h) { return; }

    if (sceneStats[0].x > 0.5f) {
        phaseFieldOut.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
        return;
    }

    uint linear = gid.y * w + gid.x;
    uint entry = splatBuffer[linear];
    if (entry != kEmptySplat) {
        uint srcIdx = entry & 0xFFFFFu;
        uint2 srcCoord = uint2(srcIdx % w, srcIdx / w);
        float4 flowInfo = cleanFlow.read(srcCoord);
        phaseFieldOut.write(half4(half2(flowInfo.xy), half(flowInfo.w), half(flowInfo.z)), gid);
        return;
    }

    // 1. Fill 1-texel zoom/rotation pinholes inside a coherent surface with bidirectional mode.
    float2 extent = float2(w, h);
    int2 cardOffsets[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
    float2 validV[4];
    float validErr = 0.0f;
    int biCount = 0;
    for (int i = 0; i < 4; ++i) {
        int2 nc = int2(gid) + cardOffsets[i];
        if (nc.x < 0 || nc.x >= int(w) || nc.y < 0 || nc.y >= int(h)) { continue; }
        uint nEntry = splatBuffer[uint(nc.y) * w + uint(nc.x)];
        if (nEntry != kEmptySplat) {
            uint nSrc = nEntry & 0xFFFFFu;
            float4 nf = cleanFlow.read(uint2(nSrc % w, nSrc / w));
            if (nf.w < 1.5f) {
                validV[biCount] = nf.xy;
                validErr += nf.z;
                biCount += 1;
            }
        }
    }

    if (biCount >= 3) {
        float2 minV = validV[0];
        float2 maxV = validV[0];
        float2 sumV = validV[0];
        for (int i = 1; i < biCount; ++i) {
            minV = min(minV, validV[i]);
            maxV = max(maxV, validV[i]);
            sumV += validV[i];
        }
        if (length((maxV - minV) * extent) <= 1.6f) {
            phaseFieldOut.write(
                half4(half2(sumV / float(biCount)), half(kModeBidirectional), half(validErr / float(biCount))),
                gid
            );
            return;
        }
    }

    // 2. Disocclusion hole behind moving foreground: search outward across 8 directions and adopt
    //    the lowest-motion splatted background velocity (`kModeCurrUncovered`).
    int2 dirs[8] = {
        int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1),
        int2(-1, -1), int2(1, -1), int2(-1, 1), int2(1, 1)
    };
    int radii[4] = { 1, 3, 7, 13 };
    float bestMotionScore = 1e9f;
    float2 bestBgVel = float2(0.0f);
    float bestBgErr = 0.25f;
    bool foundBg = false;

    for (int rIdx = 0; rIdx < 4; ++rIdx) {
        int rad = radii[rIdx];
        for (int d = 0; d < 8; ++d) {
            int2 nc = int2(gid) + dirs[d] * rad;
            if (nc.x < 0 || nc.x >= int(w) || nc.y < 0 || nc.y >= int(h)) { continue; }
            uint nEntry = splatBuffer[uint(nc.y) * w + uint(nc.x)];
            if (nEntry == kEmptySplat) { continue; }
            uint nSrc = nEntry & 0xFFFFFu;
            float4 nf = cleanFlow.read(uint2(nSrc % w, nSrc / w));
            float motionMag = length(nf.xy * extent);
            float penalty = (nf.w < 1.5f) ? 0.0f : 4.0f;
            float mScore = motionMag + penalty + float(rad) * 0.08f;
            if (mScore < bestMotionScore) {
                bestMotionScore = mScore;
                bestBgVel = nf.xy;
                bestBgErr = nf.z;
                foundBg = true;
            }
        }
        if (foundBg && bestMotionScore < 1.0f) { break; }
    }

    if (foundBg) {
        phaseFieldOut.write(half4(half2(bestBgVel), half(kModeCurrUncovered), half(bestBgErr)), gid);
    } else {
        phaseFieldOut.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
    }
}

// MARK: - 5. Full-Resolution Stationary-Locked Occlusion-Aware Synthesis (BGRA & 8/10-bit Bi-Planar SDR/HDR)

kernel void visionInterpolationSynthesize(texture2d<float> previous [[texture(0)]],
                                          texture2d<float> current [[texture(1)]],
                                          texture2d<float, access::write> output [[texture(2)]],
                                          texture2d<float> phaseField [[texture(3)]],
                                          device const float4 *sceneStats [[buffer(0)]],
                                          constant float4 &parameters [[buffer(1)]],
                                          uint2 gid [[thread_position_in_grid]]) {
    uint w = output.get_width();
    uint h = output.get_height();
    if (gid.x >= w || gid.y >= h) { return; }

    float phase = parameters.x;
    if (sceneStats[0].x > 0.5f) {
        output.write(phase < 0.5f ? previous.read(gid) : current.read(gid), gid);
        return;
    }

    float2 fullExtent = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / fullExtent;
    float2 flowExtent = float2(phaseField.get_width(), phaseField.get_height());

    float4 prevHere = previous.read(gid);
    float4 currHere = current.read(gid);
    float dC = abs(bgraPerceptualLuma(prevHere) - bgraPerceptualLuma(currHere));

    uint lx = gid.x > 0u ? gid.x - 1u : 0u;
    uint rx = min(gid.x + 1u, w - 1u);
    uint uy = gid.y > 0u ? gid.y - 1u : 0u;
    uint dy = min(gid.y + 1u, h - 1u);
    float dL = abs(bgraPerceptualLuma(previous.read(uint2(lx, gid.y))) - bgraPerceptualLuma(current.read(uint2(lx, gid.y))));
    float dR = abs(bgraPerceptualLuma(previous.read(uint2(rx, gid.y))) - bgraPerceptualLuma(current.read(uint2(rx, gid.y))));
    float dU = abs(bgraPerceptualLuma(previous.read(uint2(gid.x, uy))) - bgraPerceptualLuma(current.read(uint2(gid.x, uy))));
    float dD = abs(bgraPerceptualLuma(previous.read(uint2(gid.x, dy))) - bgraPerceptualLuma(current.read(uint2(gid.x, dy))));
    float zeroCrossAvg = (dC + dL + dR + dU + dD) * 0.2f;
    float zeroCrossMax = max(dC, max(max(dL, dR), max(dU, dD)));

    float2 v;
    float mode;
    if (!resolvePixelVelocity(
        phaseField, uv, flowExtent, phase, zeroCrossAvg, zeroCrossMax, fullExtent,
        previous, current, 1.0f, 0.0f, v, mode
    )) {
        output.write(phase < 0.5f ? prevHere : currHere, gid);
        return;
    }

    // Exact integer texel read when `v == 0`: zero bilinear resampling shimmer, while still honoring
    // `kModeCurrUncovered` / `kModePrevVisible` when foreground departs or arrives over static background.
    if (length(v * fullExtent) < 0.05f) {
        if (dC <= 0.25f) {
            output.write(mix(prevHere, currHere, phase), gid);
        } else if (mode > 2.5f) {
            float t = smoothstep(0.24f, 0.42f, dC);
            output.write(mix(mix(prevHere, currHere, phase), prevHere, t), gid);
        } else if (mode > 1.5f) {
            float t = smoothstep(0.24f, 0.42f, dC);
            output.write(mix(mix(prevHere, currHere, phase), currHere, t), gid);
        } else {
            float t = smoothstep(0.28f, 0.58f, dC) * 0.60f;
            output.write(mix(mix(prevHere, currHere, phase), phase < 0.5f ? prevHere : currHere, t), gid);
        }
        return;
    }

    float2 uvPrev = uv - phase * v;
    float2 uvCurr = uv + (1.0f - phase) * v;
    bool inPrev = inside(uvPrev);
    bool inCurr = inside(uvCurr);
    if (!inPrev && !inCurr) {
        output.write(phase < 0.5f ? prevHere : currHere, gid);
        return;
    }
    if (inPrev && !inCurr) {
        output.write(previous.sample(linearClamp, uvPrev), gid);
        return;
    }
    if (!inPrev && inCurr) {
        output.write(current.sample(linearClamp, uvCurr), gid);
        return;
    }

    float4 a = previous.sample(linearClamp, uvPrev);
    float4 b = current.sample(linearClamp, uvCurr);
    float diff = colorResidual(a.rgb, b.rgb);
    if (diff <= 0.26f) {
        output.write(mix(a, b, phase), gid);
    } else if (mode > 2.5f) {
        float t = smoothstep(0.24f, 0.42f, diff);
        output.write(mix(mix(a, b, phase), a, t), gid);
    } else if (mode > 1.5f) {
        float t = smoothstep(0.24f, 0.42f, diff);
        output.write(mix(mix(a, b, phase), b, t), gid);
    } else {
        float t = smoothstep(0.28f, 0.58f, diff) * 0.60f;
        float4 closer = phase < 0.5f ? a : b;
        output.write(mix(mix(a, b, phase), closer, t), gid);
    }
}

kernel void visionInterpolationSynthesizeNV12(texture2d<float> prevY [[texture(0)]],
                                              texture2d<float> currY [[texture(1)]],
                                              texture2d<float> prevUV [[texture(2)]],
                                              texture2d<float> currUV [[texture(3)]],
                                              texture2d<float, access::write> outY [[texture(4)]],
                                              texture2d<float, access::write> outUV [[texture(5)]],
                                              texture2d<float> phaseField [[texture(6)]],
                                              device const float4 *sceneStats [[buffer(0)]],
                                              constant float4 &parameters [[buffer(1)]],
                                              uint2 gid [[thread_position_in_grid]]) {
    uint cw = outUV.get_width();
    uint ch = outUV.get_height();
    if (gid.x >= cw || gid.y >= ch) { return; }

    uint lw = outY.get_width();
    uint lh = outY.get_height();
    uint2 base = gid * 2u;

    // parameters = (chromaOffsetX, chromaOffsetY, phase, flags: bit0=videoRange, bit1=is10Bit)
    float phase = parameters.z;
    int flags = int(parameters.w + 0.5f);
    float videoRange = (flags & 1) != 0 ? 1.0f : 0.0f;
    bool is10Bit = (flags & 2) != 0;

    if (sceneStats[0].x > 0.5f) {
        bool usePrev = phase < 0.5f;
        for (uint oy = 0; oy < 2u; ++oy) {
            for (uint ox = 0; ox < 2u; ++ox) {
                uint2 lc = base + uint2(ox, oy);
                if (lc.x < lw && lc.y < lh) {
                    float y = usePrev ? prevY.read(lc).r : currY.read(lc).r;
                    outY.write(float4(is10Bit ? quantize10BitMSB(y) : y, 0.0f, 0.0f, 1.0f), lc);
                }
            }
        }
        float2 c = usePrev ? prevUV.read(gid).rg : currUV.read(gid).rg;
        if (is10Bit) { c = quantize10BitMSB2(c); }
        outUV.write(float4(c, 0.0f, 1.0f), gid);
        return;
    }

    float2 fullExtent = float2(lw, lh);
    float2 invLuma = 1.0f / fullExtent;
    float2 flowExtent = float2(phaseField.get_width(), phaseField.get_height());

    float2 chromaVelAccum = float2(0.0f);
    float chromaValidCount = 0.0f;
    float dominantMode = kModeBidirectional;

    for (uint oy = 0; oy < 2u; ++oy) {
        for (uint ox = 0; ox < 2u; ++ox) {
            uint2 lc = base + uint2(ox, oy);
            if (lc.x >= lw || lc.y >= lh) { continue; }

            float rawPrev = prevY.read(lc).r;
            float rawCurr = currY.read(lc).r;
            float dC = abs(normalizeLuma(rawPrev, videoRange) - normalizeLuma(rawCurr, videoRange));

            uint lx = lc.x > 0u ? lc.x - 1u : 0u;
            uint rx = min(lc.x + 1u, lw - 1u);
            uint uy = lc.y > 0u ? lc.y - 1u : 0u;
            uint dy = min(lc.y + 1u, lh - 1u);
            float dL = abs(normalizeLuma(prevY.read(uint2(lx, lc.y)).r, videoRange)
                - normalizeLuma(currY.read(uint2(lx, lc.y)).r, videoRange));
            float dR = abs(normalizeLuma(prevY.read(uint2(rx, lc.y)).r, videoRange)
                - normalizeLuma(currY.read(uint2(rx, lc.y)).r, videoRange));
            float dU = abs(normalizeLuma(prevY.read(uint2(lc.x, uy)).r, videoRange)
                - normalizeLuma(currY.read(uint2(lc.x, uy)).r, videoRange));
            float dD = abs(normalizeLuma(prevY.read(uint2(lc.x, dy)).r, videoRange)
                - normalizeLuma(currY.read(uint2(lc.x, dy)).r, videoRange));
            float zeroCrossAvg = (dC + dL + dR + dU + dD) * 0.2f;
            float zeroCrossMax = max(dC, max(max(dL, dR), max(dU, dD)));

            float2 uv = (float2(lc) + 0.5f) * invLuma;
            float2 v;
            float mode;
            float outVal;
            if (!resolvePixelVelocity(
                phaseField, uv, flowExtent, phase, zeroCrossAvg, zeroCrossMax, fullExtent,
                prevY, currY, 0.0f, videoRange, v, mode
            )) {
                outVal = phase < 0.5f ? rawPrev : rawCurr;
            } else {
                chromaVelAccum += v;
                chromaValidCount += 1.0f;
                if (mode > dominantMode) { dominantMode = mode; }

                if (length(v * fullExtent) < 0.05f) {
                    // Exact integer texel read without bilinear sub-pixel drift, preserving occlusion modes.
                    if (dC <= 0.25f) {
                        outVal = mix(rawPrev, rawCurr, phase);
                    } else if (mode > 2.5f) {
                        float t = smoothstep(0.24f, 0.42f, dC);
                        outVal = mix(mix(rawPrev, rawCurr, phase), rawPrev, t);
                    } else if (mode > 1.5f) {
                        float t = smoothstep(0.24f, 0.42f, dC);
                        outVal = mix(mix(rawPrev, rawCurr, phase), rawCurr, t);
                    } else {
                        float t = smoothstep(0.28f, 0.58f, dC) * 0.60f;
                        outVal = mix(mix(rawPrev, rawCurr, phase), phase < 0.5f ? rawPrev : rawCurr, t);
                    }
                } else {
                    float2 uvPrev = uv - phase * v;
                    float2 uvCurr = uv + (1.0f - phase) * v;
                    bool inPrev = inside(uvPrev);
                    bool inCurr = inside(uvCurr);
                    if (!inPrev && !inCurr) {
                        outVal = phase < 0.5f ? rawPrev : rawCurr;
                    } else if (inPrev && !inCurr) {
                        outVal = prevY.sample(linearClamp, uvPrev).r;
                    } else if (!inPrev && inCurr) {
                        outVal = currY.sample(linearClamp, uvCurr).r;
                    } else {
                        float ya = prevY.sample(linearClamp, uvPrev).r;
                        float yb = currY.sample(linearClamp, uvCurr).r;
                        float diff = abs(normalizeLuma(ya, videoRange) - normalizeLuma(yb, videoRange));
                        if (diff <= 0.25f) {
                            outVal = mix(ya, yb, phase);
                        } else if (mode > 2.5f) {
                            float t = smoothstep(0.24f, 0.42f, diff);
                            outVal = mix(mix(ya, yb, phase), ya, t);
                        } else if (mode > 1.5f) {
                            float t = smoothstep(0.24f, 0.42f, diff);
                            outVal = mix(mix(ya, yb, phase), yb, t);
                        } else {
                            float t = smoothstep(0.28f, 0.58f, diff) * 0.60f;
                            float closer = phase < 0.5f ? ya : yb;
                            outVal = mix(mix(ya, yb, phase), closer, t);
                        }
                    }
                }
            }
            if (is10Bit) { outVal = quantize10BitMSB(outVal); }
            outY.write(float4(outVal, 0.0f, 0.0f, 1.0f), lc);
        }
    }

    float2 rawUVPrev = prevUV.read(gid).rg;
    float2 rawUVCurr = currUV.read(gid).rg;
    float2 outChroma;
    if (chromaValidCount > 0.5f) {
        float2 vChroma = chromaVelAccum / chromaValidCount;
        if (length(vChroma * fullExtent) < 0.20f) {
            float cDiff0 = max(abs(rawUVPrev.x - rawUVCurr.x), abs(rawUVPrev.y - rawUVCurr.y));
            if (cDiff0 <= 0.20f) {
                outChroma = mix(rawUVPrev, rawUVCurr, phase);
            } else if (dominantMode > 2.5f) {
                outChroma = mix(mix(rawUVPrev, rawUVCurr, phase), rawUVPrev, smoothstep(0.18f, 0.34f, cDiff0));
            } else if (dominantMode > 1.5f) {
                outChroma = mix(mix(rawUVPrev, rawUVCurr, phase), rawUVCurr, smoothstep(0.18f, 0.34f, cDiff0));
            } else {
                float t = smoothstep(0.22f, 0.45f, cDiff0) * 0.60f;
                outChroma = mix(mix(rawUVPrev, rawUVCurr, phase), phase < 0.5f ? rawUVPrev : rawUVCurr, t);
            }
        } else {
            float2 chromaUV = (float2(gid) + 0.5f) / float2(cw, ch);
            float2 uvPrev = chromaUV - phase * vChroma;
            float2 uvCurr = chromaUV + (1.0f - phase) * vChroma;
            bool inPrev = inside(uvPrev);
            bool inCurr = inside(uvCurr);
            if (inPrev && !inCurr) {
                outChroma = prevUV.sample(linearClamp, uvPrev).rg;
            } else if (!inPrev && inCurr) {
                outChroma = currUV.sample(linearClamp, uvCurr).rg;
            } else if (inPrev && inCurr) {
                float2 ca = prevUV.sample(linearClamp, uvPrev).rg;
                float2 cb = currUV.sample(linearClamp, uvCurr).rg;
                float cDiff = max(abs(ca.x - cb.x), abs(ca.y - cb.y));
                if (cDiff <= 0.20f) {
                    outChroma = mix(ca, cb, phase);
                } else if (dominantMode > 2.5f) {
                    outChroma = mix(mix(ca, cb, phase), ca, smoothstep(0.18f, 0.34f, cDiff));
                } else if (dominantMode > 1.5f) {
                    outChroma = mix(mix(ca, cb, phase), cb, smoothstep(0.18f, 0.34f, cDiff));
                } else {
                    float t = smoothstep(0.22f, 0.45f, cDiff) * 0.60f;
                    outChroma = mix(mix(ca, cb, phase), phase < 0.5f ? ca : cb, t);
                }
            } else {
                outChroma = phase < 0.5f ? rawUVPrev : rawUVCurr;
            }
        }
    } else {
        outChroma = phase < 0.5f ? rawUVPrev : rawUVCurr;
    }

    if (is10Bit) { outChroma = quantize10BitMSB2(outChroma); }
    outUV.write(float4(outChroma, 0.0f, 1.0f), gid);
}
