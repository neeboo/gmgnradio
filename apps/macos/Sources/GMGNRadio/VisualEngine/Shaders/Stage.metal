#include <metal_stdlib>
using namespace metal;

struct StageUniforms {
    float4x4 viewProjection;
    float4 timeAndAudio;
    float4 viewportAndMotion;
    float4 visualPreset;
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
    float low = uniforms.timeAndAudio.y;
    float mid = uniforms.timeAndAudio.z;
    float high = uniforms.timeAndAudio.w;
    float3 preset = uniforms.visualPreset.xyz;
    float2 centered = uv - 0.5;
    centered.x *= aspect;

    float liquidAmount = preset.y * (0.006 + mid * 0.010);
    float pulseAmount = preset.z * (0.003 + low * 0.008);
    centered += float2(
        sin(centered.y * 13.0 + uniforms.timeAndAudio.x * 0.38),
        cos(centered.x * 11.0 - uniforms.timeAndAudio.x * 0.31)
    ) * liquidAmount;
    centered *= 1.0 + sin(
        length(centered) * 18.0 - uniforms.timeAndAudio.x * 0.72
    ) * pulseAmount;

    float radial = length(centered);
    float horizon = smoothstep(0.10, 0.90, uv.y);
    float3 top = preset.x * float3(0.985, 0.992, 1.0)
        + preset.y * float3(0.975, 0.997, 1.0)
        + preset.z * float3(0.992, 0.988, 1.0);
    float3 bottom = preset.x * float3(0.91, 0.955, 1.0)
        + preset.y * float3(0.89, 0.975, 1.0)
        + preset.z * float3(0.92, 0.94, 1.0);
    float3 accent = preset.x * float3(0.12, 0.42, 1.0)
        + preset.y * float3(0.00, 0.62, 0.96)
        + preset.z * float3(0.24, 0.32, 1.0);
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
    float gridStrength = dot(preset, float3(0.17, 0.07, 0.12));
    color = mix(color, accent, gridLine * gridStrength);

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
        * (0.75 + mid * 0.25)
        * dot(preset, float3(1.0, 0.45, 1.25));
    color = mix(color, accent, ringGlow);

    float angle = atan2(centered.y, centered.x);
    float liquidBand = 0.5 + 0.5 * sin(
        radial * 34.0
            + sin(angle * 4.0 + uniforms.timeAndAudio.x * 0.22) * 2.2
            - uniforms.timeAndAudio.x * 0.86
    );
    liquidBand = smoothstep(0.78, 0.98, liquidBand)
        * smoothstep(0.76, 0.10, radial);
    color = mix(
        color,
        accent,
        liquidBand * preset.y * (0.025 + mid * 0.045)
    );

    float pulseRing = 1.0 - smoothstep(
        0.012,
        0.034,
        abs(fract(radial * 4.2 - uniforms.timeAndAudio.x * 0.075) - 0.5)
    );
    pulseRing *= smoothstep(0.84, 0.14, radial);
    color = mix(
        color,
        accent,
        pulseRing * preset.z * (0.026 + low * 0.045)
    );

    float2 starCell = floor(uv * uniforms.viewportAndMotion.xy / 5.0);
    float star = step(0.985, stageHash(starCell));
    float twinkle = 0.45 + 0.55 * sin(
        uniforms.timeAndAudio.x * 1.6 + stageHash(starCell + 7.3) * 6.283
    );
    color = mix(
        color,
        accent * 0.82,
        star * twinkle * (0.10 + high * 0.06)
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
    float3 preset = uniforms.visualPreset.xyz;

    float radius = max(length(position), 0.001);
    float3 direction = position / radius;
    float motion = dot(preset, float3(0.88, 1.18, 1.02));
    float breathing = sin(time * 1.25 + phase)
        * (0.018 + low * 0.052)
        * motion;
    float ripple = sin(radius * 6.0 - time * 2.6 + phase)
        * mid
        * 0.032
        * motion;
    position += direction * (breathing + ripple);

    float4 clipPosition = uniforms.viewProjection * float4(position, 1.0);
    float perspective = clamp(8.5 / max(clipPosition.w, 0.6), 0.55, 2.4);
    float pointSize = particle.positionAndSize.w
        * perspective
        * (2.55 + high * 1.05)
        * dot(preset, float3(1.0, 0.92, 1.12));

    StageParticleOut output;
    output.position = clipPosition;
    output.pointSize = clamp(pointSize, 1.45, 9.0);
    output.color = float4(
        mix(
            particle.colorAndPhase.rgb,
            float3(0.08, 0.48, 1.0),
            preset.y * 0.16 + preset.z * 0.08
        )
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
