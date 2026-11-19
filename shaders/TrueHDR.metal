#include <metal_stdlib>
using namespace metal;

constant float LUT_L0 = -8.0f;
constant float LUT_L1 =  0.5f;

struct FrameU {
    float4 tone;   // peakBoost, threshold, localPunch, gamutBoost
    float4 extra;  // shadowDepth, aplGuard, splitPos (<0 = off), flags (1=HDR, 2=bypassNative, 4=linearInput, 8=upscale, 16=hasSrTex)
    float4 info;   // srcW, srcH, frameSeed, reset
    float4 outp;   // outW, outH, mapUvScaleX, mapUvScaleY
    float4 stat;   // aplUp, aplDown, mapAlpha, textRelease
    float4 upsc;   // srW, srH, sharpness, reserved
};

struct SRLayerU {
    int srcW;
    int srcH;
    int k;
    int cin;
    int cout;
    int hasPrelu;
    int skipFrom;
    uint wVec4Off;
    uint bVec4Off;
    uint aVec4Off;
    uint flags;
};

struct State {
    float apl;
    float hdrFrac;
    float effPeak;
    float textCap;
    float aplRaw;
    float cut;
    float histDist;
    float frames;
    float p50;
    float p98;
    float pad0;
    float pad1;
    float hist[32];
};

struct Partial {
    float sumY;
    float hdr;
    float n;
    float pad;
    uint hist[32];
};

inline float3 srgbToLinear(float3 c) {
    float3 lo = c / 12.92f;
    float3 hi = pow(max((c + 0.055f) / 1.055f, float3(0.0f)), float3(2.4f));
    return select(hi, lo, c <= float3(0.04045f));
}

inline float3 encodeSRGB(float3 lin) {
    float3 c = clamp(lin, float3(0.0f), float3(1.0f));
    float3 lo = c * 12.92f;
    float3 hi = 1.055f * pow(max(c, float3(1e-6f)), float3(1.0f / 2.4f)) - 0.055f;
    return select(hi, lo, c <= float3(0.0031308f));
}

inline float3 toPerceptual01(float3 raw, uint flags) {
    float3 safe = select(raw, float3(0.0f), isnan(raw) | isinf(raw));
    if ((flags & 4u) != 0u) {
        return encodeSRGB(clamp(safe, float3(0.0f), float3(1.0f)));
    }
    return clamp(safe, float3(0.0f), float3(1.0f));
}

inline float3 decodeLinear(float3 raw, uint flags) {
    float3 safe = select(raw, float3(0.0f), isnan(raw) | isinf(raw));
    float3 r = clamp(safe, float3(0.0f), float3(64.0f));
    if ((flags & 4u) != 0u) return r;
    return srgbToLinear(r);
}

inline float luma709(float3 c) {
    return dot(max(c, float3(0.0f)), float3(0.2126f, 0.7152f, 0.0722f));
}

inline float3 srgbToP3(float3 c) {
    return float3(
        0.8224621f * c.r + 0.1775380f * c.g,
        0.0331941f * c.r + 0.9668058f * c.g,
        0.0170827f * c.r + 0.0723974f * c.g + 0.9105199f * c.b
    );
}

inline float lumaP3(float3 c) {
    return dot(max(c, float3(0.0f)), float3(0.2289746f, 0.6917385f, 0.0792869f));
}

inline float med4(float a, float b, float c, float d) {
    return 0.5f * (a + b + c + d - min(min(a, b), min(c, d)) - max(max(a, b), max(c, d)));
}

// 1/8-res analysis: 1 invocation per 8x8 pixel cell, 16 bilinear 2x2-box taps.
kernel void csAnalyze(
    texture2d<float, access::sample> vidTex [[texture(0)]],
    texture2d<float, access::write> cellOut [[texture(1)]],
    device Partial *partials [[buffer(0)]],
    constant FrameU &u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 wid [[threadgroup_position_in_grid]],
    uint2 nwg [[threadgroups_per_grid]],
    uint li [[thread_index_in_threadgroup]]
) {
    constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear);
    threadgroup atomic_uint wAcc[3];
    threadgroup atomic_uint wHist[32];

    if (li < 32u) atomic_store_explicit(&wHist[li], 0u, memory_order_relaxed);
    if (li < 3u) atomic_store_explicit(&wAcc[li], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int2 dims = int2(vidTex.get_width(), vidTex.get_height());
    int2 cells = (dims + int2(7)) / 8;
    bool valid = int(gid.x) < cells.x && int(gid.y) < cells.y;
    uint flags = uint(u.extra.w + 0.5f);

    if (valid) {
        float2 inv = 1.0f / float2(dims);
        float2 base = float2(gid) * 8.0f + float2(2.0f);
        float q[4];
        float pv[4];
        float sumY = 0.0f;
        float hdr = 0.0f;

        for (int i = 0; i < 4; i++) {
            float2 o = float2(float(i & 1), float(i >> 1)) * 4.0f;
            float3 raw = max(vidTex.sample(samp, (base + o) * inv, level(0.0f)).rgb, float3(0.0f));
            float3 lin = decodeLinear(raw, flags);
            float mxLin = max(lin.r, max(lin.g, lin.b));
            float mxRaw = max(raw.r, max(raw.g, raw.b));
            float Y = luma709(lin);
            sumY += Y;
            hdr += (mxRaw > 1.05f) ? 1.0f : 0.0f;
            q[i] = log2(max(mix(Y, mxLin, 0.46f), 1.0f / 16384.0f));
            if ((flags & 4u) != 0u) {
                float3 approxSrgb = pow(clamp(lin, float3(0.0f), float3(1.0f)), float3(1.0f / 2.2f));
                pv[i] = mix(luma709(approxSrgb), max(approxSrgb.r, max(approxSrgb.g, approxSrgb.b)), 0.46f);
            } else {
                pv[i] = mix(luma709(raw), mxRaw, 0.46f);
            }
        }

        float edges = step(0.22f, abs(pv[0] - pv[1])) + step(0.22f, abs(pv[2] - pv[3]))
                    + step(0.22f, abs(pv[0] - pv[2])) + step(0.22f, abs(pv[1] - pv[3]));
        float cellY = sumY * 0.25f;
        cellOut.write(float4(cellY, med4(q[0], q[1], q[2], q[3]), edges * 0.25f, hdr * 0.25f), gid);

        uint bin = min(uint(pow(max(cellY, 0.0f), 1.0f / 2.2f) * 32.0f), 31u);
        atomic_fetch_add_explicit(&wHist[bin], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&wAcc[0], uint(round(min(cellY, 16.0f) * 1024.0f)), memory_order_relaxed);
        atomic_fetch_add_explicit(&wAcc[1], uint(round(hdr * 256.0f)), memory_order_relaxed);
        atomic_fetch_add_explicit(&wAcc[2], 1u, memory_order_relaxed);
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint wi = wid.y * nwg.x + wid.x;
    if (li == 0u) {
        partials[wi].sumY = float(atomic_load_explicit(&wAcc[0], memory_order_relaxed)) / 1024.0f;
        partials[wi].hdr  = float(atomic_load_explicit(&wAcc[1], memory_order_relaxed)) / 1024.0f;
        partials[wi].n    = float(atomic_load_explicit(&wAcc[2], memory_order_relaxed));
    }
    if (li < 32u) {
        partials[wi].hist[li] = atomic_load_explicit(&wHist[li], memory_order_relaxed);
    }
}

// Single-workgroup global reduction + 256-entry tone LUT.
kernel void csStats(
    const device Partial *partials [[buffer(0)]],
    device State &st [[buffer(1)]],
    constant FrameU &u [[buffer(2)]],
    constant uint &numPartials [[buffer(3)]],
    texture2d<float, access::write> lutOut [[texture(0)]],
    uint li [[thread_index_in_threadgroup]]
) {
    threadgroup atomic_uint aSum[4];
    threadgroup atomic_uint aHist[32];
    threadgroup float sPeak;

    if (li < 32u) atomic_store_explicit(&aHist[li], 0u, memory_order_relaxed);
    if (li < 4u) atomic_store_explicit(&aSum[li], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint n = numPartials;
    float scale = clamp(exp2(floor(log2(4.0e6f / float(max(n, 1u))))), 16.0f, 1024.0f);
    float sy = 0.0f, sh = 0.0f, sn = 0.0f;
    for (uint i = li; i < n; i += 256u) {
        sy += partials[i].sumY;
        sh += partials[i].hdr;
        sn += partials[i].n;
    }
    uint hc = 0u;
    for (uint i = li / 32u; i < n; i += 8u) {
        hc += partials[i].hist[li % 32u];
    }
    atomic_fetch_add_explicit(&aSum[0], uint(round(sy * scale)), memory_order_relaxed);
    atomic_fetch_add_explicit(&aSum[1], uint(round(sh * scale)), memory_order_relaxed);
    atomic_fetch_add_explicit(&aSum[2], uint(round(sn)), memory_order_relaxed);
    atomic_fetch_add_explicit(&aHist[li % 32u], hc, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float cells = max(float(atomic_load_explicit(&aSum[2], memory_order_relaxed)), 1.0f);
    if (li < 32u) {
        float h = float(atomic_load_explicit(&aHist[li], memory_order_relaxed)) / cells;
        atomic_fetch_add_explicit(&aSum[3], uint(round(abs(h - st.hist[li]) * 65536.0f)), memory_order_relaxed);
        st.hist[li] = h;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (li == 0u) {
        float aplRaw = float(atomic_load_explicit(&aSum[0], memory_order_relaxed)) / (scale * cells);
        float hdrRaw = float(atomic_load_explicit(&aSum[1], memory_order_relaxed)) / (scale * cells);
        float dist   = float(atomic_load_explicit(&aSum[3], memory_order_relaxed)) / 65536.0f;
        bool cut = st.frames < 0.5f || u.info.w > 0.5f || dist > 0.6f || abs(aplRaw - st.aplRaw) > 0.15f;
        float a = (aplRaw > st.apl) ? u.stat.x : u.stat.y;
        float apl = cut ? aplRaw : mix(st.apl, aplRaw, a);
        st.apl = apl;
        st.hdrFrac = cut ? hdrRaw : mix(st.hdrFrac, hdrRaw, u.stat.x);

        float aplAtten = 1.0f - u.extra.y * smoothstep(0.45f, 0.88f, apl);
        float effPeak = 1.0f + (u.tone.x - 1.0f) * clamp(aplAtten, 0.45f, 1.0f);
        st.effPeak = effPeak;
        st.textCap = max(1.65f, effPeak * 0.32f);
        st.aplRaw = aplRaw;
        st.cut = cut ? 1.0f : 0.0f;
        st.histDist = dist;

        float cum = 0.0f, p50 = 1.0f, p98 = 1.0f;
        bool got50 = false, got98 = false;
        for (uint b = 0u; b < 32u; b++) {
            cum += float(atomic_load_explicit(&aHist[b], memory_order_relaxed)) / cells;
            if (!got50 && cum >= 0.50f) { p50 = float(b + 1u) / 32.0f; got50 = true; }
            if (!got98 && cum >= 0.98f) { p98 = float(b + 1u) / 32.0f; got98 = true; }
        }
        st.p50 = p50;
        st.p98 = p98;
        st.frames = min(st.frames + 1.0f, 1000000.0f);
        sPeak = effPeak;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float L = LUT_L0 + (LUT_L1 - LUT_L0) * (float(li) + 0.5f) / 256.0f;
    float E = exp2(L);
    float Ep = exp2(L * (1.0f / 2.2f));
    float knee = clamp(u.tone.y, 0.15f, 0.88f);
    float gain = 1.0f;
    if (Ep > knee) {
        float t = clamp((Ep - knee) / max(1.0f - knee, 0.05f), 0.0f, 1.0f);
        float smoothRamp = t * t * (3.0f - 2.0f * t);
        float fastRamp = pow(t, 0.85f);
        gain = 1.0f + (sPeak - 1.0f) * mix(smoothRamp, fastRamp, 0.55f);
    }
    lutOut.write(float4(gain, smoothstep(0.10f, 0.62f, E), u.tone.w * 0.35f * smoothstep(0.06f, 0.70f, E), 1.0f), uint2(li, 0u));
}

inline void csSwap(thread float &a, thread float &b) {
    float lo = min(a, b);
    b = max(a, b);
    a = lo;
}

inline float median9(float a0, float a1, float a2, float a3, float a4, float a5, float a6, float a7, float a8) {
    float p0=a0, p1=a1, p2=a2, p3=a3, p4=a4, p5=a5, p6=a6, p7=a7, p8=a8;
    csSwap(p1, p2); csSwap(p4, p5); csSwap(p7, p8);
    csSwap(p0, p1); csSwap(p3, p4); csSwap(p6, p7);
    csSwap(p1, p2); csSwap(p4, p5); csSwap(p7, p8);
    csSwap(p0, p3); csSwap(p5, p8); csSwap(p4, p7);
    csSwap(p3, p6); csSwap(p1, p4); csSwap(p2, p5);
    csSwap(p4, p7); csSwap(p4, p2); csSwap(p6, p4);
    csSwap(p4, p2);
    return p4;
}

inline float rw(float m, float med) {
    float d = (m - med) / 0.40f;
    return exp(-d * d);
}

// Local adaptation + UI/text score map at 1/8 resolution.
kernel void csMap(
    texture2d<float, access::read> cellTex [[texture(0)]],
    texture2d<float, access::read> prevMap [[texture(1)]],
    texture2d<float, access::write> mapOut [[texture(2)]],
    const device State &st [[buffer(0)]],
    constant FrameU &u [[buffer(1)]],
    uint2 wid [[threadgroup_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]],
    uint li [[thread_index_in_threadgroup]]
) {
    threadgroup float tM[140];
    threadgroup float tD[140];

    int2 dims = int2(cellTex.get_width(), cellTex.get_height());
    int2 mxc = dims - int2(1);
    int2 origin = int2(wid) * 8 - int2(3, 1);
    for (uint k = li; k < 140u; k += 64u) {
        int2 p = clamp(origin + int2(int(k % 14u), int(k / 14u)), int2(0), mxc);
        float4 t = cellTex.read(uint2(p));
        tM[k] = t.y;
        tD[k] = t.z;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int2 c = int2(wid) * 8 + int2(lid);
    if (c.x >= dims.x || c.y >= dims.y) return;
    int tc = int(lid.y + 1u) * 14 + int(lid.x + 3u);

    float m0 = tM[tc - 15]; float m1 = tM[tc - 14]; float m2 = tM[tc - 13];
    float m3 = tM[tc - 1];  float m4 = tM[tc];      float m5 = tM[tc + 1];
    float m6 = tM[tc + 13]; float m7 = tM[tc + 14]; float m8 = tM[tc + 15];
    float med = median9(m0, m1, m2, m3, m4, m5, m6, m7, m8);
    float wc = rw(m0, med) * 0.5f + rw(m2, med) * 0.5f + rw(m6, med) * 0.5f + rw(m8, med) * 0.5f;
    float we = rw(m1, med) * 0.7f + rw(m3, med) * 0.7f + rw(m5, med) * 0.7f + rw(m7, med) * 0.7f;
    float w4 = rw(m4, med);
    float bsum = (rw(m0, med) * m0 + rw(m2, med) * m2 + rw(m6, med) * m6 + rw(m8, med) * m8) * 0.5f
               + (rw(m1, med) * m1 + rw(m3, med) * m3 + rw(m5, med) * m5 + rw(m7, med) * m7) * 0.7f
               + w4 * m4;
    float cardHi = max(max(m1, m3), max(m5, m7));
    float B = max(bsum / max(wc + we + w4, 1e-6f), mix(med, cardHi, 0.75f));
    mapOut.write(float4(B, 0.0f, 0.0f, 1.0f), uint2(c));
}

struct VSOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VSOut vsMain(uint idx [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0f, -1.0f),
        float2( 3.0f, -1.0f),
        float2(-1.0f,  3.0f)
    };
    float2 p = positions[idx];
    VSOut out;
    out.pos = float4(p, 0.0f, 1.0f);
    out.uv = float2(p.x * 0.5f + 0.5f, 0.5f - p.y * 0.5f);
    return out;
}

inline float2 sliceMap(texture2d<float, access::sample> mapTex, sampler samp, float2 uv, float2 mapUvScale, float L) {
    float2 muv = uv * mapUvScale;
    float4 g = mapTex.gather(samp, muv, int2(0), component::x);
    float2 f = fract(muv * float2(mapTex.get_width(), mapTex.get_height()) - float2(0.5f));
    float4 bw = float4((1.0f - f.x) * f.y, f.x * f.y, f.x * (1.0f - f.y), (1.0f - f.x) * (1.0f - f.y));
    float4 d = float4(L) - g;
    float4 k = select(float4(0.85f), float4(1.35f), d > float4(0.0f));
    float4 x = max(float4(1.0f) - k * d * d, float4(0.0f));
    float4 w = bw * (x * x + float4(1e-4f));
    float B = dot(w, g) / max(dot(w, float4(1.0f)), 1e-6f);
    float t = mapTex.sample(samp, muv, level(0.0f)).y;
    return float2(B, t);
}

// ---- Spatial EASU (12-tap directional Lanczos) + Catmull-Rom + RCAS ----
inline float3 tapPerceptual(texture2d<float, access::sample> tex, int2 ip, int2 mxc, uint flags, bool already01) {
    float3 raw = tex.read(uint2(clamp(ip, int2(0), mxc))).rgb;
    return already01 ? clamp(raw, float3(0.0f), float3(1.0f)) : toPerceptual01(raw, flags);
}

inline void easuTapM(
    thread float3 &cSum,
    thread float &wSum,
    float2 off,
    float2 dir,
    float2 len,
    float lob,
    float3 col
) {
    float2 v = float2(dot(off, dir), dot(off, float2(-dir.y, dir.x))) * len;
    float d2 = min(dot(v, v), 4.0f);
    float wB = 0.4f * d2 - 1.0f;
    float wA = lob * d2 - 1.0f;
    float w = (1.5625f * wB * wB - 0.5625f) * (wA * wA);
    cSum += col * w;
    wSum += w;
}

inline void easuAccDir(
    float tl, float tc, float tr,
    float ml, float mc, float mr,
    float bl, float bc, float br,
    float w,
    thread float2 &dir,
    thread float &lenX
) {
    (void)tl; (void)tr; (void)bl; (void)br;
    float dx = mr - ml;
    float dy = bc - tc;
    dir += float2(dx, dy) * w;
    float gx = abs(mr - mc) + abs(mc - ml);
    float gy = abs(bc - mc) + abs(mc - tc);
    float ax = abs(dx) / max(gx, 1e-4f);
    float ay = abs(dy) / max(gy, 1e-4f);
    lenX += max(ax, ay) * w;
}

inline float3 easuSample01(
    texture2d<float, access::sample> tex,
    float2 uv,
    int2 dims,
    uint flags,
    bool already01
) {
    int2 mxc = dims - int2(1);
    float2 pos = uv * float2(dims) - float2(0.5f);
    int2 fp = int2(floor(pos));
    float2 f = pos - float2(fp);

    float3 b = tapPerceptual(tex, fp + int2( 0, -1), mxc, flags, already01);
    float3 c = tapPerceptual(tex, fp + int2( 1, -1), mxc, flags, already01);
    float3 e = tapPerceptual(tex, fp + int2(-1,  0), mxc, flags, already01);
    float3 f0 = tapPerceptual(tex, fp + int2( 0,  0), mxc, flags, already01);
    float3 g = tapPerceptual(tex, fp + int2( 1,  0), mxc, flags, already01);
    float3 h = tapPerceptual(tex, fp + int2( 2,  0), mxc, flags, already01);
    float3 i = tapPerceptual(tex, fp + int2(-1,  1), mxc, flags, already01);
    float3 j = tapPerceptual(tex, fp + int2( 0,  1), mxc, flags, already01);
    float3 k = tapPerceptual(tex, fp + int2( 1,  1), mxc, flags, already01);
    float3 l = tapPerceptual(tex, fp + int2( 2,  1), mxc, flags, already01);
    float3 n = tapPerceptual(tex, fp + int2( 0,  2), mxc, flags, already01);
    float3 o = tapPerceptual(tex, fp + int2( 1,  2), mxc, flags, already01);

    float3 lw = float3(0.299f, 0.587f, 0.114f);
    float lb = dot(b, lw), lc = dot(c, lw), le = dot(e, lw), lf = dot(f0, lw);
    float lg = dot(g, lw), lh = dot(h, lw), li = dot(i, lw), lj = dot(j, lw);
    float lk = dot(k, lw), ll = dot(l, lw), ln = dot(n, lw), lo = dot(o, lw);

    float w00 = (1.0f - f.x) * (1.0f - f.y);
    float w10 = f.x * (1.0f - f.y);
    float w01 = (1.0f - f.x) * f.y;
    float w11 = f.x * f.y;

    float2 dir = float2(0.0f);
    float lenX = 0.0f;
    easuAccDir(le, lb, lc, le, lf, lg, li, lj, lk, w00, dir, lenX);
    easuAccDir(lb, lc, lh, lf, lg, lh, lj, lk, ll, w10, dir, lenX);
    easuAccDir(le, lf, lg, li, lj, lk, ln, ln, lo, w01, dir, lenX);
    easuAccDir(lf, lg, lh, lj, lk, ll, lj, lo, lo, w11, dir, lenX);

    float d2 = dot(dir, dir);
    float2 udir = (d2 < 1e-6f) ? float2(1.0f, 0.0f) : (dir * rsqrt(d2));
    float str = clamp(lenX, 0.0f, 1.0f);
    str *= str;
    float2 len = float2(1.0f + 0.9f * str, 1.0f - 0.5f * str);
    float lob = 0.5f - 0.25f * str;

    float3 cSum = float3(0.0f);
    float wSum = 0.0f;
    easuTapM(cSum, wSum, float2( 0, -1) - f, udir, len, lob, b);
    easuTapM(cSum, wSum, float2( 1, -1) - f, udir, len, lob, c);
    easuTapM(cSum, wSum, float2(-1,  0) - f, udir, len, lob, e);
    easuTapM(cSum, wSum, float2( 0,  0) - f, udir, len, lob, f0);
    easuTapM(cSum, wSum, float2( 1,  0) - f, udir, len, lob, g);
    easuTapM(cSum, wSum, float2( 2,  0) - f, udir, len, lob, h);
    easuTapM(cSum, wSum, float2(-1,  1) - f, udir, len, lob, i);
    easuTapM(cSum, wSum, float2( 0,  1) - f, udir, len, lob, j);
    easuTapM(cSum, wSum, float2( 1,  1) - f, udir, len, lob, k);
    easuTapM(cSum, wSum, float2( 2,  1) - f, udir, len, lob, l);
    easuTapM(cSum, wSum, float2( 0,  2) - f, udir, len, lob, n);
    easuTapM(cSum, wSum, float2( 1,  2) - f, udir, len, lob, o);

    float3 mn4 = min(min(f0, g), min(j, k));
    float3 mx4 = max(max(f0, g), max(j, k));
    return clamp(cSum / max(wSum, 1e-4f), mn4, mx4);
}

inline float3 catmullSample01(
    texture2d<float, access::sample> tex,
    float2 uv,
    int2 dims,
    uint flags,
    bool already01
) {
    int2 mxc = dims - int2(1);
    float2 pos = uv * float2(dims) - float2(0.5f);
    int2 fp = int2(floor(pos));
    float2 t = pos - float2(fp);
    float2 t2 = t * t;
    float2 t3 = t2 * t;

    float4 wx = float4(-0.5f * t.x + t2.x - 0.5f * t3.x,
                        1.0f - 2.5f * t2.x + 1.5f * t3.x,
                        0.5f * t.x + 2.0f * t2.x - 1.5f * t3.x,
                       -0.5f * t2.x + 0.5f * t3.x);
    float4 wy = float4(-0.5f * t.y + t2.y - 0.5f * t3.y,
                        1.0f - 2.5f * t2.y + 1.5f * t3.y,
                        0.5f * t.y + 2.0f * t2.y - 1.5f * t3.y,
                       -0.5f * t2.y + 0.5f * t3.y);

    float3 acc = float3(0.0f);
    for (int y = 0; y < 4; y++) {
        float3 row = float3(0.0f);
        for (int x = 0; x < 4; x++) {
            row += tapPerceptual(tex, fp + int2(x - 1, y - 1), mxc, flags, already01) * wx[x];
        }
        acc += row * wy[y];
    }
    float3 c00 = tapPerceptual(tex, fp + int2(0, 0), mxc, flags, already01);
    float3 c10 = tapPerceptual(tex, fp + int2(1, 0), mxc, flags, already01);
    float3 c01 = tapPerceptual(tex, fp + int2(0, 1), mxc, flags, already01);
    float3 c11 = tapPerceptual(tex, fp + int2(1, 1), mxc, flags, already01);
    return clamp(acc, min(min(c00, c10), min(c01, c11)), max(max(c00, c10), max(c01, c11)));
}

inline float3 rcasContrast(float3 c, float3 n, float3 s, float3 e, float3 w, float sharp) {
    if (sharp <= 0.001f) return c;
    float sh = clamp(sharp, 0.0f, 1.0f);
    float3 mn = min(min(n, s), min(e, w));
    float3 mx = max(max(n, s), max(e, w));
    float3 mn5 = min(mn, c);
    float3 mx5 = max(mx, c);
    float3 hitMin = mn5 / max(4.0f * mx + float3(1e-4f), float3(1e-4f));
    float3 hitMax = (float3(1.0f) - mx5) / max(4.0f * (float3(1.0f) - mn) + float3(1e-4f), float3(1e-4f));
    float3 lobeV = min(hitMin, hitMax);
    float lobe = clamp(min(lobeV.r, min(lobeV.g, lobeV.b)), 0.0f, 0.22f);
    float peak = mix(0.08f, 0.20f, sh);
    float w0 = -min(lobe, peak) * sh;
    float3 sharpCol = (c + (n + s + e + w) * w0) / max(1.0f + 4.0f * w0, 1e-4f);
    float3 ringTol = max(mx5 - mn5, float3(0.0f)) * (0.06f * sh);
    return clamp(sharpCol, mn5 - ringTol, mx5 + ringTol);
}

inline float3 sampleUp01(
    texture2d<float, access::sample> tex,
    sampler samp,
    float2 uv,
    float2 outDims,
    float sharp,
    uint flags,
    bool already01
) {
    int2 dims = int2(tex.get_width(), tex.get_height());
    int2 mxc = dims - int2(1);
    float2 scale = float2(dims) / max(outDims, float2(1.0f));
    float maxS = max(scale.x, scale.y);

    if (maxS >= 0.985f && maxS <= 1.015f) {
        int2 ip = clamp(int2(floor(uv * float2(dims))), int2(0), mxc);
        float3 c = tapPerceptual(tex, ip, mxc, flags, already01);
        if (sharp <= 0.001f) return c;
        return rcasContrast(c,
                            tapPerceptual(tex, ip + int2(0, -1), mxc, flags, already01),
                            tapPerceptual(tex, ip + int2(0,  1), mxc, flags, already01),
                            tapPerceptual(tex, ip + int2(1,  0), mxc, flags, already01),
                            tapPerceptual(tex, ip + int2(-1, 0), mxc, flags, already01),
                            sharp);
    }
    if (maxS > 1.015f) {
        return clamp(already01 ? tex.sample(samp, uv, level(0.0f)).rgb : toPerceptual01(tex.sample(samp, uv, level(0.0f)).rgb, flags),
                     float3(0.0f), float3(1.0f));
    }

    float3 c = (maxS < 0.85f)
        ? easuSample01(tex, uv, dims, flags, already01)
        : catmullSample01(tex, uv, dims, flags, already01);
    if (sharp <= 0.001f) return c;

    float2 stepUv = 1.0f / max(outDims, float2(1.0f));
    float3 n = toPerceptual01(tex.sample(samp, uv + float2(0.0f, -stepUv.y), level(0.0f)).rgb, already01 ? 0u : flags);
    float3 s = toPerceptual01(tex.sample(samp, uv + float2(0.0f,  stepUv.y), level(0.0f)).rgb, already01 ? 0u : flags);
    float3 e = toPerceptual01(tex.sample(samp, uv + float2( stepUv.x, 0.0f), level(0.0f)).rgb, already01 ? 0u : flags);
    float3 w = toPerceptual01(tex.sample(samp, uv + float2(-stepUv.x, 0.0f), level(0.0f)).rgb, already01 ? 0u : flags);
    return rcasContrast(c, n, s, e, w, sharp);
}

// Final pass into extendedLinearDisplayP3 rgba16Float drawable (HDR + Spatial/AI 4K Upscaling + RCAS).
fragment float4 fsTrueHDR(
    VSOut in [[stage_in]],
    texture2d<float, access::sample> srcTex [[texture(0)]],
    texture2d<float, access::sample> mapTex [[texture(1)]],
    texture2d<float, access::sample> lutTex [[texture(2)]],
    texture2d<float, access::sample> srTex  [[texture(3)]],
    constant FrameU &u [[buffer(0)]],
    constant float4 &sceneV [[buffer(1)]]
) {
    constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;

    if (u.extra.z >= 0.0f && abs(uv.x - u.extra.z) < 0.0014f) {
        return float4(1.8f, 1.8f, 1.8f, 1.0f);
    }

    float3 raw = srcTex.sample(samp, uv, level(0.0f)).rgb;
    raw = select(raw, float3(0.0f), isnan(raw) | isinf(raw));
    raw = clamp(raw, float3(0.0f), float3(64.0f));
    uint flags = uint(u.extra.w + 0.5f);
    float3 c0 = decodeLinear(raw, flags);

    bool leftSplit = (u.extra.z >= 0.0f && uv.x < u.extra.z);
    if (leftSplit) {
        return float4(srgbToP3(c0), 1.0f);
    }

    if ((flags & 8u) != 0u) {
        bool hasSr = ((flags & 16u) != 0u);
        float3 up01 = hasSr
            ? sampleUp01(srTex, samp, uv, u.outp.xy, u.upsc.z, flags, true)
            : sampleUp01(srcTex, samp, uv, u.outp.xy, u.upsc.z, flags, false);
        float3 excess = ((flags & 4u) != 0u) ? max(raw - float3(1.0f), float3(0.0f)) : float3(0.0f);
        c0 = srgbToLinear(up01) + excess;
    }

    float maxIn = max(c0.r, max(c0.g, c0.b));
    bool hdrOff = (flags & 1u) == 0u;
    if (hdrOff) {
        return float4(srgbToP3(c0), 1.0f);
    }

    float3 p3Linear = srgbToP3(c0);
    float E = mix(luma709(c0), maxIn, 0.46f);
    float L = log2(max(E, 1.0f / 16384.0f));
    float4 lut = lutTex.sample(samp, float2((L - LUT_L0) / (LUT_L1 - LUT_L0), 0.5f), level(0.0f));

    float2 loc = sliceMap(mapTex, samp, uv, u.outp.zw, L);
    float bg = exp2(loc.x);
    float detail = max(0.0f, E - bg * 1.15f);
    float textProt = clamp(loc.y, 0.0f, 1.0f) * smoothstep(0.10f, 0.32f, detail);

    float shadowRatio = 1.0f;
    if (maxIn < 0.015f) {
        float blackToe = pow(max(maxIn, 1e-5f), u.extra.x * 0.25f);
        float blackMix = 1.0f - smoothstep(0.002f, 0.015f, maxIn);
        shadowRatio = mix(1.0f, clamp(blackToe, 0.86f, 1.0f), blackMix);
    }

    float hdrGain = lut.x;
    float localMask = smoothstep(0.08f, 0.32f, detail) * lut.y * (1.0f - textProt * 0.85f);
    hdrGain = hdrGain * (1.0f + u.tone.z * 0.50f * localMask);
    hdrGain = mix(hdrGain, min(hdrGain, sceneV.w), textProt * 0.85f);

    float3 hdrP3 = p3Linear * (hdrGain * shadowRatio);
    float p3Y = lumaP3(hdrP3);
    float satScale = 1.0f + lut.z * (1.0f - textProt * 0.6f);
    hdrP3 = max(float3(0.0f), mix(float3(p3Y), hdrP3, satScale));

    if ((flags & 2u) != 0u && sceneV.y > 0.002f) {
        float nativeW = smoothstep(0.002f, 0.015f, sceneV.y);
        hdrP3 = mix(hdrP3, p3Linear, nativeW);
    }

    return float4(hdrP3, 1.0f);
}

struct HUDUniforms {
    float4 rect; // x, y, w, h in top-left normalized [0..1] coords
    float4 gain; // x = linear gain, yzw = reserved
};

vertex VSOut vsHUD(uint idx [[vertex_id]], constant HUDUniforms &hr [[buffer(0)]]) {
    float2 corners[6] = {
        float2(0.0f, 0.0f), float2(1.0f, 0.0f), float2(0.0f, 1.0f),
        float2(1.0f, 0.0f), float2(1.0f, 1.0f), float2(0.0f, 1.0f)
    };
    float2 c = corners[idx];
    float2 n = hr.rect.xy + c * hr.rect.zw;
    VSOut out;
    out.pos = float4(n.x * 2.0f - 1.0f, 1.0f - n.y * 2.0f, 0.0f, 1.0f);
    out.uv = c;
    return out;
}

fragment float4 fsHUD(
    VSOut in [[stage_in]],
    texture2d<float, access::sample> hudTex [[texture(0)]],
    constant HUDUniforms &hr [[buffer(0)]]
) {
    constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 px = hudTex.sample(samp, in.uv, level(0.0f));
    float a = clamp(px.a, 0.0f, 1.0f);
    if (a <= 1e-4f) return float4(0.0f);
    // Input texture is premultiplied sRGB RGBA8Unorm; unpremultiply, decode to linear P3, re-premultiply.
    float3 straight = clamp(px.rgb / a, float3(0.0f), float3(1.0f));
    float3 linP3 = srgbToP3(srgbToLinear(straight)) * hr.gain.x;
    return float4(linP3 * a, a);
}

// ---- Neural AI Super-Resolution Compute Kernels (f12x5 / q16x6 Crisp4K) ----
kernel void csSRIn(
    texture2d<float, access::read> srcTex [[texture(0)]],
    texture2d_array<half, access::write> outArr [[texture(1)]],
    const device half4 *w4 [[buffer(0)]],
    constant SRLayerU &u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]],
    uint2 wid [[threadgroup_position_in_grid]],
    uint li [[thread_index_in_threadgroup]]
) {
    threadgroup half yTile[12][20];
    int2 dims = int2(u.srcW, u.srcH);
    int2 mxc = dims - int2(1);
    int rad = u.k >> 1;
    int tw = 16 + 2 * rad;
    int th = 8 + 2 * rad;
    int total = tw * th;
    int2 base = int2(wid) * int2(16, 8) - int2(rad, rad);

    for (int idx = int(li); idx < total; idx += 128) {
        int lx = idx % tw;
        int ly = idx / tw;
        int2 p = clamp(base + int2(lx, ly), int2(0), mxc);
        float3 p01 = toPerceptual01(srcTex.read(uint2(p)).rgb, u.flags);
        yTile[ly][lx] = half(luma709(p01));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (int(gid.x) >= dims.x || int(gid.y) >= dims.y) return;
    int ocG = u.cout >> 2;
    int taps = u.k * u.k;

    for (int oc4 = 0; oc4 < ocG; oc4++) {
        half4 acc = w4[u.bVec4Off + uint(oc4)];
        uint wBase = u.wVec4Off + uint(oc4);
        int tap = 0;
        for (int ky = 0; ky < u.k; ky++) {
            for (int kx = 0; kx < u.k; kx++) {
                half yv = yTile[int(lid.y) + ky][int(lid.x) + kx];
                acc = fma(half4(yv), w4[wBase + uint(tap * ocG)], acc);
                tap++;
            }
        }
        (void)taps;
        if (u.hasPrelu != 0) {
            half4 a = w4[u.aVec4Off + uint(oc4)];
            acc = select(acc * a, acc, acc >= half4(0.0h));
        }
        outArr.write(acc, gid, uint(oc4));
    }
}

kernel void csSRMid(
    texture2d_array<half, access::read> inArr [[texture(0)]],
    texture2d_array<half, access::read> skipArr [[texture(1)]],
    texture2d_array<half, access::write> outArr [[texture(2)]],
    const device half4 *w4 [[buffer(0)]],
    constant SRLayerU &u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]],
    uint2 wid [[threadgroup_position_in_grid]],
    uint li [[thread_index_in_threadgroup]]
) {
    threadgroup half4 tile[10][18][4];
    int2 dims = int2(u.srcW, u.srcH);
    int2 mxc = dims - int2(1);
    int2 base = int2(wid) * int2(16, 8) - int2(1, 1);
    int icG = u.cin >> 2;
    int ocG = u.cout >> 2;

    for (int idx = int(li); idx < 180; idx += 128) {
        int lx = idx % 18;
        int ly = idx / 18;
        int2 p = clamp(base + int2(lx, ly), int2(0), mxc);
        for (int g = 0; g < icG; g++) {
            tile[ly][lx][g] = inArr.read(uint2(p), uint(g));
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (int(gid.x) >= dims.x || int(gid.y) >= dims.y) return;

    for (int oc4 = 0; oc4 < ocG; oc4++) {
        half4 acc = w4[u.bVec4Off + uint(oc4)];
        for (int ic4 = 0; ic4 < icG; ic4++) {
            uint blockOff = u.wVec4Off + uint(((oc4 * icG + ic4) * 9) * 4);
            for (int tap = 0; tap < 9; tap++) {
                half4 x = tile[int(lid.y) + tap / 3][int(lid.x) + tap % 3][ic4];
                uint wi = blockOff + uint(tap * 4);
                acc = fma(half4(x.x), w4[wi + 0u], acc);
                acc = fma(half4(x.y), w4[wi + 1u], acc);
                acc = fma(half4(x.z), w4[wi + 2u], acc);
                acc = fma(half4(x.w), w4[wi + 3u], acc);
            }
        }
        if (u.skipFrom >= 0) {
            acc += skipArr.read(gid, uint(oc4));
        }
        if (u.hasPrelu != 0) {
            half4 a = w4[u.aVec4Off + uint(oc4)];
            acc = select(acc * a, acc, acc >= half4(0.0h));
        }
        outArr.write(acc, gid, uint(oc4));
    }
}

kernel void csSROut(
    texture2d_array<half, access::read> inArr [[texture(0)]],
    texture2d<float, access::read> srcTex [[texture(1)]],
    texture2d<half, access::write> outTex [[texture(2)]],
    const device half4 *w4 [[buffer(0)]],
    constant SRLayerU &u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]],
    uint2 wid [[threadgroup_position_in_grid]],
    uint li [[thread_index_in_threadgroup]]
) {
    threadgroup half4 tile[10][18][4];
    threadgroup half4 rgbTile[12][20];
    int2 dims = int2(u.srcW, u.srcH);
    int2 mxc = dims - int2(1);
    int2 featBase = int2(wid) * int2(16, 8) - int2(1, 1);
    int2 rgbBase  = int2(wid) * int2(16, 8) - int2(2, 2);
    int icG = u.cin >> 2;

    for (int idx = int(li); idx < 180; idx += 128) {
        int lx = idx % 18;
        int ly = idx / 18;
        int2 p = clamp(featBase + int2(lx, ly), int2(0), mxc);
        for (int g = 0; g < icG; g++) {
            tile[ly][lx][g] = inArr.read(uint2(p), uint(g));
        }
    }
    for (int idx = int(li); idx < 240; idx += 128) {
        int lx = idx % 20;
        int ly = idx / 20;
        int2 p = clamp(rgbBase + int2(lx, ly), int2(0), mxc);
        float3 p01 = toPerceptual01(srcTex.read(uint2(p)).rgb, u.flags);
        rgbTile[ly][lx] = half4(half3(p01), 1.0h);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (int(gid.x) >= dims.x || int(gid.y) >= dims.y) return;

    half4 res = w4[u.bVec4Off];
    for (int ic4 = 0; ic4 < icG; ic4++) {
        uint blockOff = u.wVec4Off + uint((ic4 * 9) * 4);
        for (int tap = 0; tap < 9; tap++) {
            half4 x = tile[int(lid.y) + tap / 3][int(lid.x) + tap % 3][ic4];
            uint wi = blockOff + uint(tap * 4);
            res = fma(half4(x.x), w4[wi + 0u], res);
            res = fma(half4(x.y), w4[wi + 1u], res);
            res = fma(half4(x.z), w4[wi + 2u], res);
            res = fma(half4(x.w), w4[wi + 3u], res);
        }
    }

    // Exact PyTorch 2x bicubic (a = -0.75, align_corners=False) on rgbTile.
    // Input tile origin for this pixel is rgbTile[lid.y + 2][lid.x + 2] (center = (0,0)).
    const half4 bic0 = half4(-0.03515625h, 0.26171875h, 0.87890625h, -0.10546875h);
    const half4 bic1 = half4(-0.10546875h, 0.87890625h, 0.26171875h, -0.03515625h);
    int rx = int(lid.x);
    int ry = int(lid.y);
    half3 h0[5], h1[5];
    for (int r = 0; r < 5; r++) {
        half3 a0 = rgbTile[ry + r][rx + 0].rgb;
        half3 a1 = rgbTile[ry + r][rx + 1].rgb;
        half3 a2 = rgbTile[ry + r][rx + 2].rgb;
        half3 a3 = rgbTile[ry + r][rx + 3].rgb;
        half3 a4 = rgbTile[ry + r][rx + 4].rgb;
        h0[r] = a0 * bic0.x + a1 * bic0.y + a2 * bic0.z + a3 * bic0.w;
        h1[r] = a1 * bic1.x + a2 * bic1.y + a3 * bic1.z + a4 * bic1.w;
    }

    uint2 outBase = gid * 2u;
    half3 u00 = h0[0] * bic0.x + h0[1] * bic0.y + h0[2] * bic0.z + h0[3] * bic0.w;
    half3 u10 = h1[0] * bic0.x + h1[1] * bic0.y + h1[2] * bic0.z + h1[3] * bic0.w;
    half3 u01 = h0[1] * bic1.x + h0[2] * bic1.y + h0[3] * bic1.z + h0[4] * bic1.w;
    half3 u11 = h1[1] * bic1.x + h1[2] * bic1.y + h1[3] * bic1.z + h1[4] * bic1.w;

    outTex.write(half4(clamp(u00 + half3(res.x), half3(0.0h), half3(1.0h)), 1.0h), outBase + uint2(0u, 0u));
    outTex.write(half4(clamp(u10 + half3(res.y), half3(0.0h), half3(1.0h)), 1.0h), outBase + uint2(1u, 0u));
    outTex.write(half4(clamp(u01 + half3(res.z), half3(0.0h), half3(1.0h)), 1.0h), outBase + uint2(0u, 1u));
    outTex.write(half4(clamp(u11 + half3(res.w), half3(0.0h), half3(1.0h)), 1.0h), outBase + uint2(1u, 1u));
}
