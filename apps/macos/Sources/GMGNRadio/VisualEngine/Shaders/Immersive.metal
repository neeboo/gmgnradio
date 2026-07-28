#include <metal_stdlib>
using namespace metal;

struct ImmersiveUniforms {
    float2 resolution;
    float2 origin;
    float time;
    float progress;
    float audioLow;
    float audioMid;
    float audioHigh;
};

struct ImmersiveVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex ImmersiveVertexOut immersiveVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    ImmersiveVertexOut output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = positions[vertexID] * 0.5 + 0.5;
    return output;
}

float immersiveHash(float2 point) {
    point = fract(point * float2(127.1, 311.7));
    point += dot(point, point + 19.19);
    return fract(point.x * point.y);
}

float immersiveNoise(float2 point) {
    float2 cell = floor(point);
    float2 local = fract(point);
    float2 curve = local * local * (3.0 - 2.0 * local);
    float a = immersiveHash(cell);
    float b = immersiveHash(cell + float2(1.0, 0.0));
    float c = immersiveHash(cell + float2(0.0, 1.0));
    float d = immersiveHash(cell + float2(1.0, 1.0));
    return mix(mix(a, b, curve.x), mix(c, d, curve.x), curve.y);
}

fragment float4 immersiveFragment(
    ImmersiveVertexOut input [[stage_in]],
    constant ImmersiveUniforms &uniforms [[buffer(0)]]
) {
    float2 uv = input.uv;
    float aspect = uniforms.resolution.x / max(uniforms.resolution.y, 1.0);
    float2 delta = uv - uniforms.origin;
    delta.x *= aspect;
    float distanceFromOrigin = length(delta);

    float revealRadius = uniforms.progress * (1.8 + aspect * 0.35);
    float reveal = 1.0 - smoothstep(
        revealRadius - 0.20,
        revealRadius + 0.08,
        distanceFromOrigin
    );

    float coreRadius = mix(0.055, 0.26, smoothstep(0.0, 0.34, uniforms.progress));
    float core = 1.0 - smoothstep(coreRadius - 0.015, coreRadius, distanceFromOrigin);
    core *= 1.0 - smoothstep(0.24, 0.58, uniforms.progress);

    float2 flowPoint = float2(uv.x * aspect, uv.y) * 3.2;
    flowPoint += float2(uniforms.time * 0.032, -uniforms.time * 0.018);
    float noise = immersiveNoise(flowPoint)
        + immersiveNoise(flowPoint * 1.9 + 4.7) * 0.5;
    noise /= 1.5;

    float bandA = sin((uv.y + noise * 0.15) * 13.0 - uniforms.time * 0.22);
    float bandB = sin((uv.x * aspect - noise * 0.11) * 9.0 + uniforms.time * 0.16);
    float bands = smoothstep(0.76, 1.0, 0.5 + 0.25 * bandA + 0.25 * bandB);
    bands *= 0.15 + uniforms.audioMid * 0.12;

    float3 base = float3(0.018, 0.024, 0.048);
    float3 cyan = float3(0.08, 0.23, 0.34);
    float3 violet = float3(0.19, 0.10, 0.30);
    float colorBlend = smoothstep(0.12, 0.92, uv.x + noise * 0.12);
    float3 color = mix(cyan, violet, colorBlend);
    color = mix(base, color, 0.22 + bands);
    color += float3(0.04, 0.10, 0.15) * uniforms.audioLow * 0.20;
    color += float3(0.10, 0.05, 0.14) * uniforms.audioHigh * 0.12;

    float halo = exp(-distanceFromOrigin * 8.0)
        * (1.0 - smoothstep(0.35, 0.72, uniforms.progress));
    color += float3(0.12, 0.28, 0.42) * halo * 0.38;

    float alpha = clamp(reveal * 0.96 + core, 0.0, 0.98);
    return float4(color * alpha, alpha);
}
