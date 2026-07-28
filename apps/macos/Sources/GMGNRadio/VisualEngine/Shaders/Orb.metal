#include <metal_stdlib>
using namespace metal;

struct OrbUniforms {
    float2 resolution;
    float time;
    float energy;
    float deformation;
    float glow;
    float particleAmount;
    float hue;
    float opacity;
    float audioLow;
    float audioMid;
    float audioHigh;
    float transitionProgress;
};

struct OrbVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex OrbVertexOut orbVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    OrbVertexOut output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = positions[vertexID] * 0.5 + 0.5;
    return output;
}

float orbHash(float2 point) {
    point = fract(point * float2(123.34, 456.21));
    point += dot(point, point + 45.32);
    return fract(point.x * point.y);
}

float orbNoise(float2 point) {
    float2 cell = floor(point);
    float2 local = fract(point);
    float2 curve = local * local * (3.0 - 2.0 * local);

    float a = orbHash(cell);
    float b = orbHash(cell + float2(1.0, 0.0));
    float c = orbHash(cell + float2(0.0, 1.0));
    float d = orbHash(cell + float2(1.0, 1.0));

    return mix(mix(a, b, curve.x), mix(c, d, curve.x), curve.y);
}

float3 orbPalette(float hue, float brightness) {
    float3 phase = float3(0.00, 0.33, 0.67);
    float3 color = 0.5 + 0.5 * cos(6.28318 * (hue + phase));
    return mix(float3(0.08, 0.11, 0.18), color, 0.42) * brightness;
}

fragment float4 orbFragment(
    OrbVertexOut input [[stage_in]],
    constant OrbUniforms &uniforms [[buffer(0)]]
) {
    float2 point = input.uv * 2.0 - 1.0;
    point.x *= uniforms.resolution.x / max(uniforms.resolution.y, 1.0);

    float angle = atan2(point.y, point.x);
    float radius = length(point);
    float breath = sin(uniforms.time * (0.72 + uniforms.energy * 0.8)) * 0.012;
    float contour = sin(angle * 5.0 + uniforms.time * 0.55) * 0.014;
    contour += sin(angle * 9.0 - uniforms.time * 0.36) * 0.007;
    float sphereRadius = 0.68 + breath + contour * uniforms.deformation;
    float signedDistance = radius - sphereRadius;

    float body = 1.0 - smoothstep(-0.01, 0.025, signedDistance);
    float rim = smoothstep(0.18, 0.0, abs(signedDistance))
        * smoothstep(0.50, 0.93, radius / max(sphereRadius, 0.001));
    float outerGlow = exp(-max(signedDistance, 0.0) * 15.0)
        * smoothstep(0.20, -0.02, signedDistance)
        * uniforms.glow;

    float2 flowPoint = point * 2.3;
    flowPoint += float2(uniforms.time * 0.045, -uniforms.time * 0.032);
    float flow = orbNoise(flowPoint)
        + 0.5 * orbNoise(flowPoint * 2.1 + 7.3)
        + 0.25 * orbNoise(flowPoint * 4.2 - 3.1);
    flow /= 1.75;

    float edgeCells = orbHash(floor((point + 1.0) * 38.0));
    float particles = step(0.985 - uniforms.particleAmount * 0.08, edgeCells)
        * smoothstep(0.20, 0.0, abs(signedDistance))
        * uniforms.particleAmount;

    float light = 0.32 + flow * 0.34 + rim * (0.25 + uniforms.energy * 0.34);
    float3 cool = orbPalette(uniforms.hue, light);
    float3 violet = orbPalette(uniforms.hue + 0.10, light * 0.86);
    float colorMix = smoothstep(-0.8, 0.8, point.x + flow * 0.3);
    float3 color = mix(cool, violet, colorMix);
    color += float3(0.34, 0.62, 0.92) * rim * uniforms.glow;
    color += particles;

    float alpha = clamp(
        (body * (0.62 + uniforms.energy * 0.18) + outerGlow * 0.28)
            * uniforms.opacity,
        0.0,
        1.0
    );
    return float4(color * alpha, alpha);
}
