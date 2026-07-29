#include <metal_stdlib>
using namespace metal;

struct StageUniforms {
    float4x4 viewProjection;
    float4 timeAndAudio;
    float4 viewportAndMotion;
};

struct StageParticleVertex {
    float4 positionAndSize;
    float4 colorAndPhase;
};

struct StageBackgroundOut {
    float4 position [[position]];
    float2 uv;
};

struct StageParticleOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
    float depth;
};

vertex StageBackgroundOut stageBackgroundVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    StageBackgroundOut output;
    output.position = float4(positions[vertexID], 0.999, 1.0);
    output.uv = positions[vertexID] * 0.5 + 0.5;
    return output;
}

float stageHash(float2 point) {
    point = fract(point * float2(123.34, 456.21));
    point += dot(point, point + 45.32);
    return fract(point.x * point.y);
}

fragment float4 stageBackgroundFragment(
    StageBackgroundOut input [[stage_in]],
    constant StageUniforms &uniforms [[buffer(0)]]
) {
    float2 uv = input.uv;
    float aspect = uniforms.viewportAndMotion.x
        / max(uniforms.viewportAndMotion.y, 1.0);
    float2 centered = uv - 0.5;
    centered.x *= aspect;

    float radial = length(centered);
    float horizon = smoothstep(0.10, 0.90, uv.y);
    float3 top = float3(0.985, 0.992, 1.0);
    float3 bottom = float3(0.91, 0.955, 1.0);
    float3 color = mix(bottom, top, horizon);
    color -= float3(0.018, 0.035, 0.060) * smoothstep(0.25, 1.1, radial);

    float perspectiveY = max(0.08, uv.y + 0.04);
    float2 gridPoint = float2(
        centered.x / perspectiveY * 1.8,
        1.0 / perspectiveY + uniforms.timeAndAudio.x * 0.025
    );
    float2 gridDistance = abs(fract(gridPoint) - 0.5);
    float gridLine = 1.0 - smoothstep(0.46, 0.495, max(gridDistance.x, gridDistance.y));
    gridLine *= smoothstep(0.64, 0.18, uv.y) * smoothstep(0.02, 0.20, uv.y);
    color = mix(color, float3(0.36, 0.68, 1.0), gridLine * 0.17);

    float ringA = 1.0 - smoothstep(
        0.008,
        0.024,
        abs(length(centered * float2(1.0, 1.7)) - 0.44)
    );
    float ringB = 1.0 - smoothstep(
        0.006,
        0.020,
        abs(length((centered + float2(0.08, -0.03)) * float2(1.0, 1.45)) - 0.62)
    );
    float ringGlow = (ringA * 0.055 + ringB * 0.032)
        * (0.75 + uniforms.timeAndAudio.z * 0.25);
    color = mix(color, float3(0.08, 0.42, 1.0), ringGlow);

    float2 starCell = floor(uv * uniforms.viewportAndMotion.xy / 5.0);
    float star = step(0.985, stageHash(starCell));
    float twinkle = 0.45 + 0.55 * sin(
        uniforms.timeAndAudio.x * 1.6 + stageHash(starCell + 7.3) * 6.283
    );
    color = mix(
        color,
        float3(0.08, 0.30, 0.92),
        star * twinkle * 0.14
    );

    return float4(color, 1.0);
}

vertex StageParticleOut stageParticleVertex(
    uint vertexID [[vertex_id]],
    device const StageParticleVertex *vertices [[buffer(0)]],
    constant StageUniforms &uniforms [[buffer(1)]]
) {
    StageParticleVertex particle = vertices[vertexID];
    float3 position = particle.positionAndSize.xyz;
    float phase = particle.colorAndPhase.w;
    float time = uniforms.timeAndAudio.x;
    float low = uniforms.timeAndAudio.y;
    float mid = uniforms.timeAndAudio.z;
    float high = uniforms.timeAndAudio.w;

    float radius = max(length(position), 0.001);
    float3 direction = position / radius;
    float breathing = sin(time * 1.25 + phase) * (0.018 + low * 0.052);
    float ripple = sin(radius * 6.0 - time * 2.6 + phase) * mid * 0.032;
    position += direction * (breathing + ripple);

    float4 clipPosition = uniforms.viewProjection * float4(position, 1.0);
    float perspective = clamp(8.5 / max(clipPosition.w, 0.6), 0.55, 2.4);
    float pointSize = particle.positionAndSize.w
        * perspective
        * (2.55 + high * 1.05);

    StageParticleOut output;
    output.position = clipPosition;
    output.pointSize = clamp(pointSize, 1.45, 9.0);
    output.color = float4(
        particle.colorAndPhase.rgb
            * (0.96 + high * 0.26 + uniforms.viewportAndMotion.z * 0.08),
        1.0
    );
    output.depth = perspective;
    return output;
}

fragment float4 stageParticleFragment(
    StageParticleOut input [[stage_in]],
    float2 pointCoordinate [[point_coord]]
) {
    float2 centered = pointCoordinate - 0.5;
    float distance = length(centered);
    float soft = 1.0 - smoothstep(0.26, 0.5, distance);
    float core = 1.0 - smoothstep(0.02, 0.19, distance);
    float front = smoothstep(0.62, 1.72, input.depth);
    float3 distantBlue = float3(0.18, 0.48, 0.96);
    float3 depthColor = mix(distantBlue, input.color.rgb * 0.72, front);
    float alpha = soft * (0.88 + core * 0.12);
    return float4(depthColor, alpha);
}
