/// Metal shader source, compiled at launch so the package builds with plain `swift build`.
enum Shaders {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    constant float EXTENT = \#(World.extent);
    constant float SHADOW_TEXELS = \#(Float(Renderer.shadowMapSize));
    constant float2 PLAZA = float2(\#(World.plazaCenter.x), \#(World.plazaCenter.y));
    constant float PLAZA_R = \#(World.plazaRadius);

    constant float3 HORIZON = float3(0.80, 0.94, 1.0);
    constant float3 ZENITH = float3(0.10, 0.44, 0.93);
    constant float CLOUD_H = 260.0;

    struct Frame {
        float4x4 viewProj;
        float4x4 invViewProj;
        float4 cam;   // xyz position, w time
        float4 sun;   // xyz direction towards the sun
        float4 sunCol;
        float4x4 lightViewProj;
    };

    struct Obj {
        float4x4 model;
        float4x4 normalMat;
        float4 tint;
    };

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
                   mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
    }

    float fbm(float2 p) {
        float s = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) {
            s += a * vnoise(p);
            p = p * 2.03 + 7.1;
            a *= 0.5;
        }
        return s / 0.96875;
    }

    /// Value noise that fades to its mean (0.5) once it gets finer than a pixel,
    /// so distant ground detail dissolves instead of shimmering.
    float aaNoise(float2 p, float freq, float foot) {
        return mix(0.5, vnoise(p * freq), saturate(1.0 - foot * freq * 1.2));
    }

    // ---- Underwater ---------------------------------------------------------

    constant float3 UWDEEP = float3(0.025, 0.24, 0.36);
    constant float3 UWSURF = float3(0.10, 0.50, 0.60);
    /// Everything decays toward this with distance. It must be the same for the
    /// water surface and the seabed, or the far waterline reads as a dark bar.
    constant float3 UWFOG = float3(0.05, 0.38, 0.50);

    /// 0 above water, 1 below, crossfaded over a short band so the moment the
    /// camera breaks the surface is not a hard cut.
    float uwAmount(float camY) {
        return smoothstep(0.30, -0.10, camY);
    }

    /// Sunlight refracted through the rippling surface: a web of bright filaments.
    float caustics(float2 p, float t) {
        float2 q = p * 0.75;
        float a = vnoise(q + float2(t * 0.21, t * 0.16));
        float b = vnoise(q * 1.9 + float2(-t * 0.18, t * 0.25));
        return pow(saturate(1.0 - abs(a - b)), 6.0);
    }

    // Warm horizon as the sun drops, shared by the sky and the distance fog so a
    // sunset does not fade into a daylight-blue band.
    float3 horizonColor(float3 sunDir) {
        float low = 1.0 - saturate(sunDir.y * 2.2);
        return mix(HORIZON, float3(1.0, 0.70, 0.44), low * 0.55);
    }

    // One cloud layer at a fixed altitude. The sky intersects it along the view
    // ray and shading projects onto it along the sun, so the shadow you walk
    // through is the cloud you can see.
    float cloudField(float2 xz, float time) {
        return fbm(xz * 0.0055 + float2(time * 0.011, time * 0.006));
    }

    float cloudShade(float3 wp, float3 sunDir, float time) {
        float t = (CLOUD_H - wp.y) / max(sunDir.y, 0.10);
        return smoothstep(0.50, 0.68, cloudField(wp.xz + sunDir.xz * t, time));
    }

    float3 skyColor(float3 d, float3 sunDir, float3 sunCol, float3 cam, float time, float clouds) {
        float h = saturate(d.y);
        float low = 1.0 - saturate(sunDir.y * 2.2);
        float3 c = mix(horizonColor(sunDir), mix(ZENITH, float3(0.22, 0.30, 0.62), low * 0.5), pow(h, 0.55));
        float sd = saturate(dot(d, sunDir));
        c += sunCol * (pow(sd, 700.0) * 5.0 + pow(sd, 10.0) * 0.18);
        if (d.y > 0.01) {
            float t = (CLOUD_H - cam.y) / max(d.y, 0.02);
            float n = cloudField(cam.xz + d.xz * t, time);
            // A grazing ray meets the cloud plane thousands of units away, where
            // one noise cell is sub-pixel: without this the water's reflection of
            // the sky stretched clouds into ragged white shards.
            float cl = smoothstep(0.52, 0.72, n) * (1.0 - smoothstep(700.0, 2400.0, t));
            float fade = smoothstep(0.0, 0.16, d.y);
            float3 cc = mix(float3(0.80, 0.87, 0.97), float3(1.0), smoothstep(0.5, 0.92, n));
            c = mix(c, cc, cl * fade * 0.95 * clouds);
        }
        return c;
    }

    float3 applyFog(float3 c, float3 wp, float3 cam, float3 sunDir) {
        float d = distance(wp, cam);
        // Gentler than it was: the island used to be the whole world, so haze
        // at 200 m was the horizon. An archipelago has to stay readable across
        // 400 m or the far islands are just pale smudges.
        float f = 1.0 - exp(-d * 0.0022);
        float3 lit = mix(c, horizonColor(sunDir), f);
        float uw = uwAmount(cam.y);
        if (uw > 0.0) {
            // Water absorbs red first and swallows distance far faster than air.
            lit = mix(lit, UWFOG, (1.0 - exp(-d * 0.065)) * uw);
        }
        return lit;
    }

    // ---- Sky ----------------------------------------------------------------

    struct SkyOut {
        float4 pos [[position]];
        float2 ndc;
    };

    vertex SkyOut vs_sky(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        SkyOut o;
        o.pos = float4(p * 2.0 - 1.0, 1.0, 1.0);
        o.ndc = p * 2.0 - 1.0;
        return o;
    }

    fragment float4 fs_sky(SkyOut in [[stage_in]], constant Frame& f [[buffer(1)]]) {
        float4 w = f.invViewProj * float4(in.ndc, 1.0, 1.0);
        float3 dir = normalize(w.xyz / w.w - f.cam.xyz);
        float3 c = skyColor(dir, normalize(f.sun.xyz), f.sunCol.rgb, f.cam.xyz, f.cam.w, 1.0);
        // Submerged, the water surface geometry covers everything above the
        // horizon, so this only shows where a downward ray misses the terrain:
        // the open water below.
        float uw = uwAmount(f.cam.y);
        if (uw > 0.0) {
            // Open water below the horizon has to match UWFOG exactly, or the
            // sliver where a ray grazes past both the surface and the terrain
            // shows up as a dark bar; it darkens as the view tips downward.
            float3 deep = UWFOG * (1.0 - 0.30 * saturate(-dir.y));
            c = mix(c, deep, uw);
        }
        return float4(c, 1.0);
    }

    // ---- Terrain, props and characters ----------------------------------------

    struct VIn {
        float4 pos [[attribute(0)]];
        float4 nrm [[attribute(1)]];
        float4 col [[attribute(2)]];
    };

    struct VOut {
        float4 pos [[position]];
        float3 wp;
        float3 n;
        float4 col;
        float trans;
    };

    vertex VOut vs_main(VIn in [[stage_in]], constant Frame& f [[buffer(1)]], constant Obj& o [[buffer(2)]]) {
        float4 wp = o.model * float4(in.pos.xyz, 1.0);
        VOut r;
        r.pos = f.viewProj * wp;
        r.wp = wp.xyz;
        r.n = normalize((o.normalMat * float4(in.nrm.xyz, 0.0)).xyz);
        r.col = in.col * o.tint;
        r.trans = in.nrm.w;
        return r;
    }

    /// Per-instance transform for props. Uniform-ish scale keeps the model
    /// matrix usable as its own normal matrix, and the fragment normalises.
    struct Inst {
        float4x4 model;
        float4 tint;
    };

    vertex VOut vs_inst(VIn in [[stage_in]], uint iid [[instance_id]],
                        constant Frame& f [[buffer(1)]], const device Inst* insts [[buffer(3)]]) {
        Inst o = insts[iid];
        float4 wp = o.model * float4(in.pos.xyz, 1.0);
        VOut r;
        r.pos = f.viewProj * wp;
        r.wp = wp.xyz;
        r.n = normalize((o.model * float4(in.nrm.xyz, 0.0)).xyz);
        r.col = in.col * o.tint;
        r.trans = in.nrm.w;
        return r;
    }

    // Depth-only shadow caster.
    struct ShadowOut {
        float4 pos [[position]];
    };

    vertex ShadowOut vs_shadow(VIn in [[stage_in]], constant Frame& f [[buffer(1)]], constant Obj& o [[buffer(2)]]) {
        float4 wp = o.model * float4(in.pos.xyz, 1.0);
        ShadowOut r;
        r.pos = f.lightViewProj * wp;
        return r;
    }

    vertex ShadowOut vs_shadow_inst(VIn in [[stage_in]], uint iid [[instance_id]],
                                    constant Frame& f [[buffer(1)]], const device Inst* insts [[buffer(3)]]) {
        ShadowOut r;
        r.pos = f.lightViewProj * (insts[iid].model * float4(in.pos.xyz, 1.0));
        return r;
    }

    fragment float4 fs_main(VOut in [[stage_in]], constant Frame& f [[buffer(1)]], depth2d<float> shadowMap [[texture(1)]]) {
        float3 Ng = normalize(in.n);
        float3 V = normalize(f.cam.xyz - in.wp);
        float3 L = normalize(f.sun.xyz);
        float3 albedo = in.col.rgb;

        if (in.col.a < 0.75) {
            float pd = length(in.wp.xz - PLAZA);
            if (pd < PLAZA_R) {
                float2 g = in.wp.xz / 2.0;
                float2 cell = floor(g);
                float chk = fmod(abs(cell.x + cell.y), 2.0);
                albedo = mix(float3(0.97, 0.90, 0.74), float3(0.94, 0.66, 0.38), chk);
                // Per-tile tone so the floor is not perfectly flat.
                albedo *= 0.96 + 0.08 * hash21(cell);
                // Grout, anti-aliased with the pixel footprint so it does not
                // shimmer into a moire field on the far side of the plaza.
                float2 fr = fract(g);
                float2 e = min(fr, 1.0 - fr);
                float gw = max(fwidth(g.x), fwidth(g.y));
                float grout = 1.0 - smoothstep(0.018, 0.018 + max(gw, 0.006), min(e.x, e.y));
                albedo *= 1.0 - 0.16 * grout;
                // Deliberate stone border ring, then a contact shadow under the
                // kerb — the floor used to just stop against the grass.
                albedo = mix(albedo, float3(0.90, 0.85, 0.75), smoothstep(PLAZA_R - 1.1, PLAZA_R - 0.75, pd));
                albedo *= 1.0 - 0.10 * smoothstep(PLAZA_R - 0.55, PLAZA_R - 0.15, pd);
            } else {
                // Ground detail. The vertex colour already carries the broad
                // material blend (sand -> grass -> rock, by height then slope);
                // this only modulates it, so the two blends don't compound.
                float2 p = in.wp.xz;
                // Footprint of a pixel in world units. The X and Y derivatives
                // differ a lot on flat ground seen obliquely, so take the larger
                // one; summing them faded detail that was still resolvable.
                float foot = max(max(fwidth(p).x, fwidth(p).y), 0.002);
                float grassW = smoothstep(1.2, 2.3, in.wp.y);
                float rockW = 1.0 - smoothstep(0.52, 0.74, Ng.y);

                float big = fbm(p * 0.05 + 11.3);
                float mid = aaNoise(p, 0.55, foot);
                float fine = aaNoise(p, 2.8, foot);

                // Grass: broad tonal drift, then grain, warmed where `big` is high
                // so the hills read as sun-bleached patches rather than flat green.
                float3 gMul = (0.76 + 0.44 * big) * (0.82 + 0.36 * mid) * (0.90 + 0.20 * fine);
                gMul *= mix(float3(1.0), float3(1.09, 1.03, 0.88), saturate(big * 1.4 - 0.3));

                // Sand: soft grain plus a shallow dune ripple.
                float dune = sin(dot(p, float2(0.83, 0.55)) * 2.1 + big * 6.0 + vnoise(p * 0.13) * 4.0);
                float3 sMul = (0.90 + 0.20 * mid)
                            * (1.0 + 0.05 * dune * saturate(1.0 - foot * 20.0));
                // Damp sand near the water line: darker and a touch more saturated.
                float wet = 1.0 - smoothstep(-0.05, 0.70, in.wp.y);
                sMul *= mix(float3(1.0), float3(0.78, 0.86, 0.93), wet * 0.85);

                // Rock: broken blotches. Height-based strata were tried and read
                // as contour lines, so the variation stays 2D and low contrast.
                float3 rMul = 0.86 + 0.26 * aaNoise(p, 1.1, foot);
                rMul *= mix(float3(1.0), float3(1.06, 1.0, 0.92), saturate(big * 1.2));

                albedo *= mix(mix(sMul, gMul, grassW), rMul, rockW);
            }
        }

        // Shadow mapping with PCF. Receiver-plane offset along the geometric
        // normal plus a slope-scaled bias kills the acne on flat/lit surfaces.
        float shadow = 1.0;
        float3 wpShadow = in.wp + Ng * 0.25;
        float4 lp = f.lightViewProj * float4(wpShadow, 1.0);
        if (lp.w > 0.0) {
            float3 lndc = lp.xyz / lp.w;
            float2 uv = float2(lndc.x * 0.5 + 0.5, 0.5 - lndc.y * 0.5);
            if (all(uv >= 0.0) && all(uv <= 1.0)) {
                float ref = lndc.z - (0.0007 + 0.0015 * (1.0 - saturate(dot(Ng, L))));
                // Hardware bilinear PCF over a 3x3 grid of 2x2 footprints.
                constexpr sampler smp(coord::normalized, address::clamp_to_edge,
                                      filter::linear, compare_func::less_equal);
                float2 texel = 1.0 / float2(SHADOW_TEXELS);
                float sum = 0.0;
                for (int y = -1; y <= 1; y++) {
                    for (int x = -1; x <= 1; x++) {
                        sum += shadowMap.sample_compare(smp, uv + float2(float(x), float(y)) * texel, ref);
                    }
                }
                shadow = sum / 9.0;
            }
        }

        // Two-sided lighting, blended rather than flipped. A hard flip at
        // dot(N,V)=0 puts a discontinuity exactly on the line where the ground
        // is tangent to the view, which shows up as a dotted seam along shores.
        float side = smoothstep(-0.12, 0.12, dot(Ng, V));
        // Drifting cloud shadows. Same field the sky draws, projected along the
        // sun, so a shadow crossing the island matches the cloud overhead.
        float sunlit = 1.0 - 0.60 * cloudShade(in.wp, L, f.cam.w);
        float wrap = mix(saturate(dot(-Ng, L) * 0.5 + 0.5), saturate(dot(Ng, L) * 0.5 + 0.5), side);
        float diff = smoothstep(0.35, 0.80, wrap);
        float ny = mix(-Ng.y, Ng.y, side);
        // Hemispheric ambient: cool sky above, warm bounce below. Vertical faces
        // get a little extra warmth when they face the sun, otherwise every wall
        // of a building receives identical light and the form disappears.
        float3 amb = mix(float3(0.80, 0.73, 0.62), float3(0.70, 0.82, 1.0), ny * 0.5 + 0.5);
        float horiz = saturate(1.0 - abs(ny));
        float2 nxz = Ng.xz / max(length(Ng.xz), 1e-4);
        float face = 0.5 + 0.5 * dot(nxz, normalize(float3(L.x, 0.0, L.z)).xz);
        amb *= mix(float3(1.0), float3(1.14, 1.05, 0.90), face * horiz);
        // Dusk: the sky dims and warms as the sun drops, otherwise the fixed
        // ambient keeps a sunset looking like midday.
        float day = saturate(L.y * 2.6);
        amb *= mix(0.72, 1.0, day) * mix(float3(1.16, 0.94, 0.80), float3(1.0), day);
        float3 col = albedo * (amb * 0.74 + f.sunCol.rgb * diff * 0.58 * shadow * sunlit);
        // Thin foliage transmits sunlight: viewing a frond from underneath while
        // the sun lights its top should glow, not go black.
        float through = in.trans * saturate(-dot(Ng, V)) * saturate(dot(Ng, L));
        col += albedo * f.sunCol.rgb * through * 0.55 * sunlit;
        // Caustics on anything below the surface, fading out with depth.
        float uw = uwAmount(f.cam.y);
        if (uw > 0.0 && in.wp.y < 0.0 && Ng.y > 0.0) {
            float cau = caustics(in.wp.xz, f.cam.w);
            col += f.sunCol.rgb * cau * uw * Ng.y * 0.55 * exp(in.wp.y * 0.35) * shadow * sunlit;
        }
        // A little additive sky fill in shade: cool, and it keeps shadowed sand
        // and grass from going muddy without desaturating the lit areas.
        col += float3(0.030, 0.050, 0.082) * (1.0 - shadow);
        float luma = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(float3(luma), col, 1.12);
        return float4(applyFog(col, in.wp, f.cam.xyz, L), 1.0);
    }

    // ---- Water ----------------------------------------------------------------

    void addWave(thread float3& r, float2 p, float t, float2 dir, float k, float amp) {
        float ph = dot(dir, p) * k + t * 0.6 * sqrt(9.8 * k);
        r.x += amp * sin(ph);
        r.yz += amp * k * cos(ph) * dir;
    }

    float3 waveLow(float2 p, float t) {
        float3 r = float3(0.0);
        addWave(r, p, t, normalize(float2(1.0, 0.3)), 0.45, 0.10);
        addWave(r, p, t, normalize(float2(-0.4, 1.0)), 0.80, 0.055);
        addWave(r, p, t, normalize(float2(0.7, 0.7)), 1.30, 0.03);
        return r;
    }

    float3 waveHigh(float2 p, float t) {
        float3 r = float3(0.0);
        addWave(r, p, t, normalize(float2(-0.9, -0.2)), 2.7, 0.03);
        addWave(r, p, t, normalize(float2(0.2, -1.0)), 4.6, 0.02);
        addWave(r, p, t, normalize(float2(0.8, -0.5)), 7.3, 0.012);
        addWave(r, p, t, normalize(float2(-0.5, 0.8)), 11.0, 0.007);
        return r;
    }

    struct WOut {
        float4 pos [[position]];
        float3 wp;
    };

    vertex WOut vs_water(uint vid [[vertex_id]],
                         const device float2* grid [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Obj& o [[buffer(2)]]) {
        // tint = (origin.x, origin.z, cell size, unused): the ring's cells are
        // laid out on a grid that is snapped to whole cells in world space, so
        // the surface stays put while the camera moves.
        float2 xz = o.tint.xy + grid[vid] * o.tint.z;
        float fade = saturate(1.0 - distance(xz, f.cam.xz) / 300.0);
        float3 w = waveLow(xz, f.cam.w);
        WOut r;
        r.wp = float3(xz.x, w.x * fade, xz.y);
        r.pos = f.viewProj * float4(r.wp, 1.0);
        return r;
    }

    fragment float4 fs_water(WOut in [[stage_in]],
                             constant Frame& f [[buffer(1)]],
                             texture2d<float> hmap [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float t = f.cam.w;
        float dist = distance(in.wp, f.cam.xyz);
        float3 V = normalize(f.cam.xyz - in.wp);
        float3 L = normalize(f.sun.xyz);

        float3 wv = waveLow(in.wp.xz, t) + waveHigh(in.wp.xz, t);
        float calm = saturate((dist - 40.0) / 260.0);
        float2 slope = wv.yz * 1.5 * (1.0 - 0.8 * calm);
        float3 N = normalize(float3(-slope.x, 1.0, -slope.y));

        // Refraction: bend the lookup of the seabed along the wave normal. It
        // shifts the shoreline and the shallow shelf instead of the whole
        // screen, which is what a second scene pass would cost us.
        float2 uv0 = (in.wp.xz + EXTENT) / (2.0 * EXTENT);
        float d0 = max(-hmap.sample(s, uv0).r, 0.0);
        float2 uv = (in.wp.xz + N.xz * (0.35 + d0 * 0.55) + EXTENT) / (2.0 * EXTENT);
        float ground = hmap.sample(s, uv).r;
        // Depth from the mean sea level, not the displaced surface: measuring
        // from `wp.y` made the shallow band and its foam follow the wave crests
        // and smear into vertical streaks.
        float depth = max(-ground, 0.0);

        float shallow = exp(-depth * 0.30);
        float3 deepC = float3(0.02, 0.27, 0.62);
        float3 shalC = float3(0.10, 0.88, 0.82);
        float3 base = mix(deepC, shalC, shallow);

        float3 R = reflect(-V, N);
        R.y = abs(R.y);
        // Clouds are left out of the reflection: the wave normals jitter the
        // reflected ray enough to turn their high-contrast edges into shards.
        float3 refl = skyColor(R, L, f.sunCol.rgb, f.cam.xyz, t, 0.0);
        float fres = 0.05 + 0.95 * pow(1.0 - saturate(dot(N, V)), 5.0);
        float3 col = mix(base, refl, clamp(fres * 1.15, 0.0, 0.85));

        float3 H = normalize(L + V);
        col += f.sunCol.rgb * pow(saturate(dot(N, H)), 350.0) * 2.2;

        // Shadows are intentionally not applied to the water surface: at grazing
        // angles the shadow-map texel footprint blows up and the island's terrain
        // silhouette shows up as hard-edged bands offshore.

        // Wide, gentle shore: foam at the waterline, then a translucent turquoise
        // shelf before the water turns opaque. A steep alpha ramp here is what
        // turned the shallows into a hard cut with a dark seam at the sand.
        float wob = 0.25 * sin(t * 1.3 + in.wp.x * 0.15) + 0.1 * sin(t * 2.1);
        float fo = smoothstep(0.85 + wob, 0.0, depth);
        // Foam: a band at the waterline, broken into flecks. The breakup noise is
        // deliberately fine — at 2.2/m it read as cloud-shaped smears sitting on
        // the shallow banks rather than churned water.
        float breakup = vnoise(in.wp.xz * 5.5 + float2(t * 0.25, 0.0)) * 0.6
                      + vnoise(in.wp.xz * 13.0 - float2(0.0, t * 0.31)) * 0.4;
        fo *= smoothstep(0.30, 0.70, breakup + 0.45 * fo);
        col = mix(col, float3(1.0), fo * 0.9);

        float alpha = saturate(0.20 + depth * 0.30);
        alpha = max(alpha, fo * 0.92);

        // Seen from below the surface: a bright rippling ceiling inside the Snell
        // window (~49 degrees from vertical), and total internal reflection makes
        // the grazing view a dark mirror of the water instead.
        float uw = uwAmount(f.cam.y);
        if (uw > 0.0) {
            float3 toSurf = normalize(in.wp - f.cam.xyz);
            float3 surfN = normalize(float3(-slope.x * 2.2, 1.0, -slope.y * 2.2));
            float window = smoothstep(0.58, 0.78, saturate(dot(toSurf, surfN)));
            float3 ceilCol = mix(skyColor(float3(0.0, 1.0, 0.0), L, f.sunCol.rgb, f.cam.xyz, t, 1.0), float3(0.72, 0.95, 1.0), 0.35);
            float3 under = mix(UWDEEP * 1.6, ceilCol, window);
            col = mix(col, under, uw);
            alpha = mix(alpha, 1.0, uw);
        }
        return float4(applyFog(col, in.wp, f.cam.xyz, L), alpha);
    }

    // ---- Particles -----------------------------------------------------------

    struct POut {
        float4 pos [[position]];
        float4 col;
        float2 uv;
        float3 wp;
        float kind;
    };

    vertex POut vs_particle(uint vid [[vertex_id]],
                            const device VIn* vin [[buffer(0)]],
                            constant Frame& f [[buffer(1)]]) {
        VIn v = vin[vid];
        POut o;
        o.pos = f.viewProj * float4(v.pos.xyz, 1.0);
        o.col = v.col;
        o.uv = v.nrm.xy;
        o.wp = v.pos.xyz;
        o.kind = v.nrm.z;
        return o;
    }

    fragment float4 fs_particle(POut in [[stage_in]]) {
        float d = length(in.uv);
        if (d > 1.0) { discard_fragment(); }
        float a = in.col.a * smoothstep(1.0, 0.45, d);
        if (in.kind > 4.5) {
            // Goo: a lobed splat with a ragged rim, so it reads as something
            // stuck to the ground rather than as a shadow.
            float n = vnoise(in.wp.xz * 4.0) * 0.55 + vnoise(in.wp.xz * 11.0 + 2.7) * 0.45;
            float th = atan2(in.uv.y, in.uv.x);
            float rr = d / (0.78 + 0.22 * sin(th * 3.0 + n * 6.2831));
            a *= smoothstep(1.0, 0.80, rr);
        } else if (in.kind > 3.5) {
            // Wet ground: no internal breakup, because water soaks in evenly,
            // but the rim wobbles with noise. A clean ellipse reads as a shadow.
            float n = vnoise(in.wp.xz * 6.0) * 0.6 + vnoise(in.wp.xz * 15.0 + 7.3) * 0.4;
            a *= smoothstep(1.0, 0.72, d * (0.86 + 0.28 * n));
        } else if (in.kind > 2.5) {
            // Spray: a crisp core, since these are stretched streaks of water
            // rather than mist.
            a *= smoothstep(1.0, 0.62, d);
        } else if (in.kind > 1.5) {
            // Dust: a small sprite, so the breakup needs a higher frequency than
            // foam, and the edge has to be softer than a droplet's.
            float n = vnoise(in.wp.xz * 17.0 + in.wp.y * 7.0) * 0.6 + vnoise(in.wp.xz * 31.0) * 0.4;
            a *= smoothstep(0.95, 0.28, d) * (0.55 + 0.75 * n);
        } else if (in.kind > 0.5) {
            // A soft disc reads as a bubble no matter how it is tinted, so foam
            // is broken up with noise on the world position instead.
            float n = vnoise(in.wp.xz * 5.0) * 0.55 + vnoise(in.wp.xz * 12.0 + 3.1) * 0.45;
            a *= smoothstep(0.36, 0.70, n + 0.40 * smoothstep(0.65, 0.0, d));
        }
        float3 c = in.col.rgb * (1.0 + 0.18 * (1.0 - d));
        return float4(c, a);
    }

    // ---- Bloom + tone mapping ------------------------------------------------

    struct PostOut {
        float4 pos [[position]];
        float2 uv;
    };

    vertex PostOut vs_post(uint vid [[vertex_id]], const device float2* quad [[buffer(0)]]) {
        float2 p = quad[vid];
        PostOut o;
        o.pos = float4(p, 0.0, 1.0);
        o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return o;
    }

    /// Threshold + soft knee so only genuinely bright pixels bloom.
    fragment float4 fs_bloom_extract(PostOut in [[stage_in]],
                                     texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 c = src.sample(s, in.uv).rgb;
        float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
        float knee = 0.5;
        float thresh = 1.0;
        float soft = saturate((lum - thresh + knee) / (2.0 * knee));
        soft = soft * soft * knee;
        float contrib = max(soft, lum - thresh) / max(lum, 1e-4);
        return float4(c * contrib, 1.0);
    }

    /// Separable 9-tap Gaussian; direction is horizontal by default.
    float3 blurTapW(PostOut in, texture2d<float> src, sampler s, float2 texelSize, float2 dir, float w) {
        return src.sample(s, in.uv + dir * texelSize * w).rgb;
    }

    fragment float4 fs_bloom_blur_h(PostOut in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    constant float2& texelSize [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 d = float2(1.0, 0.0);
        float3 c = float3(0.0);
        c += blurTapW(in, src, s, texelSize, d, -4.0) * 0.0162;
        c += blurTapW(in, src, s, texelSize, d, -3.0) * 0.0540;
        c += blurTapW(in, src, s, texelSize, d, -2.0) * 0.1216;
        c += blurTapW(in, src, s, texelSize, d, -1.0) * 0.1946;
        c += blurTapW(in, src, s, texelSize, d,  0.0) * 0.2270;
        c += blurTapW(in, src, s, texelSize, d,  1.0) * 0.1946;
        c += blurTapW(in, src, s, texelSize, d,  2.0) * 0.1216;
        c += blurTapW(in, src, s, texelSize, d,  3.0) * 0.0540;
        c += blurTapW(in, src, s, texelSize, d,  4.0) * 0.0162;
        return float4(c, 1.0);
    }

    fragment float4 fs_bloom_blur_v(PostOut in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    constant float2& texelSize [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 d = float2(0.0, 1.0);
        float3 c = float3(0.0);
        c += blurTapW(in, src, s, texelSize, d, -4.0) * 0.0162;
        c += blurTapW(in, src, s, texelSize, d, -3.0) * 0.0540;
        c += blurTapW(in, src, s, texelSize, d, -2.0) * 0.1216;
        c += blurTapW(in, src, s, texelSize, d, -1.0) * 0.1946;
        c += blurTapW(in, src, s, texelSize, d,  0.0) * 0.2270;
        c += blurTapW(in, src, s, texelSize, d,  1.0) * 0.1946;
        c += blurTapW(in, src, s, texelSize, d,  2.0) * 0.1216;
        c += blurTapW(in, src, s, texelSize, d,  3.0) * 0.0540;
        c += blurTapW(in, src, s, texelSize, d,  4.0) * 0.0162;
        return float4(c, 1.0);
    }

    /// Highlight-only tone curve: identity below the knee, smooth compression above.
    /// Keeps the hand-authored display-space colours intact and only rolls off HDR.
    float3 tonemapKnee(float3 x) {
        const float knee = 0.86;
        float3 over = max(x - knee, 0.0);
        return min(x, knee) + over / (1.0 + over * 1.5);
    }

    // ---- HUD font -----------------------------------------------------------
    // A 5x6 pixel font: six rows of five bits, top row first, bit 4 leftmost.
    // Swift formats the numbers into character codes, so the shader never has
    // to split an integer into digits; anything it does not know is blank.

    struct HUD {
        int4 steps;
        int4 miles;
        int4 calories;
    };

    static uint glyphBits(int c) {
        switch (c) {
            case 48: return 0x3F18C63F;   // '0'
            case 49: return 0x19C6319E;   // '1'
            case 50: return 0x3D11321F;   // '2'
            case 51: return 0x3D17062E;   // '3'
            case 52: return 0x252F8842;   // '4'
            case 53: return 0x3F0F062E;   // '5'
            case 54: return 0x1D0F462E;   // '6'
            case 55: return 0x3E111108;   // '7'
            case 56: return 0x1D17462E;   // '8'
            case 57: return 0x1D18BC2E;   // '9'
            case 83: return 0x1F07062E;   // 'S'
            case 84: return 0x3E421084;   // 'T'
            case 69: return 0x3F0F421F;   // 'E'
            case 80: return 0x3D1F4210;   // 'P'
            case 77: return 0x23BAC631;   // 'M'
            case 73: return 0x3E42109F;   // 'I'
            case 67: return 0x1F08420F;   // 'C'
            case 65: return 0x1D18FE31;   // 'A'
            case 76: return 0x2108421F;   // 'L'
            case 75: return 0x232E4A31;   // 'K'
            case 46: return 0x000006;   // '.'
            default: return 0u;
        }
    }

    /// One glyph; `origin` is its top-left corner in pixels, y down.
    static float glyphAt(float2 p, float2 origin, float scale, int ch) {
        if (ch == 0) { return 0.0; }
        float2 cell = float2(p.x - origin.x, origin.y - p.y) / scale;
        if (cell.x < -1.0 || cell.y < -1.0 || cell.x >= 6.0 || cell.y >= 7.0) { return 0.0; }
        // The cell grid is not an integer number of screen pixels at every
        // resolution, so feather the glyph's own edges by half a pixel instead
        // of letting the bitmap stair-step.
        float2 fd = fwidth(cell) * 0.5 + 1e-4;
        float2 lo = smoothstep(-fd, fd, cell);
        float2 hi = smoothstep(-fd, fd, float2(5.0, 6.0) - cell);
        float inside = lo.x * lo.y * hi.x * hi.y;
        uint bits = glyphBits(ch);
        uint row = (bits >> uint((5 - clamp(int(cell.y), 0, 5)) * 5)) & 0x1Fu;
        return inside * float((row >> uint(4 - clamp(int(cell.x), 0, 4))) & 1u);
    }

    /// Up to four characters in a row, six columns apart.
    static float textRow(float2 p, float2 origin, float scale, int4 chars, int count) {
        float m = 0.0;
        for (int i = 0; i < count; ++i) {
            int ch = i == 0 ? chars.x : (i == 1 ? chars.y : (i == 2 ? chars.z : chars.w));
            m = max(m, glyphAt(p, origin + float2(float(i) * 6.0 * scale, 0.0), scale, ch));
        }
        return m;
    }

    static float roundBox(float2 p, float2 c, float2 hb, float r) {
        float2 q = abs(p - c) - (hb - r);
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    fragment float4 fs_bloom_composite(PostOut in [[stage_in]],
                                       texture2d<float> scene [[texture(0)]],
                                       texture2d<float> bloom [[texture(1)]],
                                       constant float4& gauge [[buffer(0)]],
                                       constant HUD& hud [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 c = scene.sample(s, in.uv).rgb;
        float3 b = bloom.sample(s, in.uv).rgb;
        c += b * 0.30;                 // bloom strength
        // Trim exposure slightly: lit grass and sand sat right at the top of the
        // curve, which flattened ground detail and blew out the wet sand.
        c *= 0.92;
        c = tonemapKnee(c);
        // Gentle saturation / warm grading for the sunny look.
        float luma = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(float3(luma), c, 1.06);
        c.b *= 0.99;
        c.r *= 1.01;
        c = saturate(c);

        // Water gauge: a slim bar in the bottom-left corner. Drawn after the
        // grade so the scene's warmth does not tint it, and sized in pixels so
        // it is the same size at any resolution. `gauge.x` is the level, `.y` is
        // 1 once the pack is too dry to fire and `.z` is 1 while the aim lands
        // on something (which is what shows the reticle further down).
        float2 res = float2(scene.get_width(), scene.get_height());
        float sc = res.y / 1080.0;
        // p is in pixels from the bottom-left, so the bar fills upwards.
        float2 p = float2(in.uv.x * res.x, (1.0 - in.uv.y) * res.y);
        float r = 6.0 * sc;
        float2 ctr = float2(38.0 * sc, 30.0 * sc + 52.0 * sc);
        float2 hb = float2(8.0 * sc, 52.0 * sc);
        {
            float2 q = abs(p - ctr) - (hb - r);
            float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
            float frame = 1.0 - smoothstep(-sc, sc, sd);
            c = mix(c, float3(0.05, 0.09, 0.12), frame * 0.55);

            // Water column, filled from the bottom. Amber once it is nearly out,
            // because at that point the level is a warning rather than a readout.
            float2 iq = abs(p - ctr) - (hb - float2(3.0, 3.0) * sc - (r - 2.0 * sc));
            float isd = length(max(iq, 0.0)) + min(max(iq.x, iq.y), 0.0) - (r - 2.0 * sc);
            float inside = 1.0 - smoothstep(-sc, sc, isd);
            float top = ctr.y + hb.y - 3.0 * sc;
            float bot = ctr.y - hb.y + 3.0 * sc;
            float surface = mix(bot, top, gauge.x);
            float filled = 1.0 - smoothstep(-1.5 * sc, 1.5 * sc, p.y - surface);
            // A narrow band, not a long crossfade: amber and aqua are opposite
            // colours, so blending them across the whole low range turned the
            // warning a muddy olive instead of either one.
            float3 water = mix(float3(0.98, 0.60, 0.26), float3(0.36, 0.80, 0.96),
                               smoothstep(0.22, 0.28, gauge.x));
            c = mix(c, water, inside * filled * 0.90);
        }


        // Activity readout, to the right of the bar: footfalls, miles covered on
        // foot and a rough calorie count, small enough to read as a watch widget
        // and never in the way. Labels are baked in the font above; the numbers
        // arrive pre-formatted as character codes.
        {
            float2 pc = float2(167.0 * sc, 84.0 * sc);
            float2 ph = float2(112.0 * sc, 23.0 * sc);
            float sd = roundBox(p, pc, ph, 9.0 * sc);
            c = mix(c, float3(0.04, 0.07, 0.11), (1.0 - smoothstep(-sc, sc, sd)) * 0.42);

            // Whole-pixel cells: a 0.9 px stroke aliases into dashes, so the
            // font snaps to an integer size and the edges are feathered instead.
            float ls = max(1.0, round(1.4 * sc));
            float vs = max(2.0, round(2.6 * sc));
            float2 l0 = float2(60.0 * sc, 101.0 * sc);
            float2 l1 = float2(140.0 * sc, 101.0 * sc);
            float2 l2 = float2(220.0 * sc, 101.0 * sc);
            float2 v0 = float2(60.0 * sc, 85.0 * sc);
            float2 v1 = float2(140.0 * sc, 85.0 * sc);
            float2 v2 = float2(220.0 * sc, 85.0 * sc);

            float label = max(max(textRow(p, l0, ls, int4(83, 84, 69, 80), 4),
                                  textRow(p, l1, ls, int4(77, 73, 76, 69), 4)),
                              textRow(p, l2, ls, int4(75, 67, 65, 76), 4));
            float value = max(max(textRow(p, v0, vs, hud.steps, 4),
                                  textRow(p, v1, vs, hud.miles, 4)),
                              textRow(p, v2, vs, hud.calories, 3));
            c = mix(c, float3(0.62, 0.80, 0.90), label * 0.78);
            c = mix(c, float3(0.98, 0.99, 1.0), value);
        }

        // Aim reticle. The stream is solved to land on the eye ray, so the
        // middle of the screen is exactly where the water goes. A marker on the
        // ground would work too, but the camera looks *at* the player, so that
        // spot sits behind the character every single time.
        if (gauge.z > 0.5) {
            float2 mid = res * 0.5;
            float d = length(p - mid);
            float ring = smoothstep(1.7 * sc, 0.7 * sc, abs(d - 8.0 * sc));
            float pip = smoothstep(2.0 * sc, 0.8 * sc, d);
            c = mix(c, float3(0.96, 1.0, 1.0), ring * 0.40 + pip * 0.55);
        }
        return float4(c, 1.0);
    }
    """#
}
