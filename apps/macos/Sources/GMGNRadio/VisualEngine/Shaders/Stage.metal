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

float stageNoise(float2 point) {
    float2 cell = floor(point);
    float2 local = fract(point);
    local = local * local * (3.0 - 2.0 * local);

    float a = stageHash(cell);
    float b = stageHash(cell + float2(1.0, 0.0));
    float c = stageHash(cell + float2(0.0, 1.0));
    float d = stageHash(cell + float2(1.0, 1.0));
    return mix(mix(a, b, local.x), mix(c, d, local.x), local.y);
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

    float liquidAmount = preset.y * (0.008 + mid * 0.013);
    float pulseAmount = preset.z * (0.004 + low * 0.010);
    centered += float2(
        sin(centered.y * 13.0 + uniforms.timeAndAudio.x * 0.38),
        cos(centered.x * 11.0 - uniforms.timeAndAudio.x * 0.31)
    ) * liquidAmount;
    centered *= 1.0 + sin(
        length(centered) * 18.0 - uniforms.timeAndAudio.x * 0.72
    ) * pulseAmount;

    float radial = length(centered);
    float horizon = smoothstep(0.10, 0.90, uv.y);
    float3 top = preset.x * float3(0.002, 0.006, 0.025)
        + preset.y * float3(0.001, 0.012, 0.026)
        + preset.z * float3(0.009, 0.003, 0.028);
    float3 bottom = preset.x * float3(0.004, 0.018, 0.052)
        + preset.y * float3(0.002, 0.026, 0.046)
        + preset.z * float3(0.018, 0.006, 0.052);
    float3 accent = preset.x * float3(0.08, 0.56, 1.0)
        + preset.y * float3(0.00, 0.92, 0.88)
        + preset.z * float3(0.62, 0.18, 1.0);
    float3 secondaryAccent = preset.x * float3(0.12, 0.95, 1.0)
        + preset.y * float3(0.10, 0.48, 1.0)
        + preset.z * float3(0.12, 0.66, 1.0);
    float3 color = mix(bottom, top, horizon);

    float cloudA = stageNoise(
        centered * float2(2.6, 3.8)
            + float2(uniforms.timeAndAudio.x * 0.018, 0.0)
    );
    float cloudB = stageNoise(
        centered * float2(6.2, 5.4)
            - float2(0.0, uniforms.timeAndAudio.x * 0.013)
    );
    float nebula = smoothstep(0.48, 0.92, cloudA * 0.68 + cloudB * 0.32);
    nebula *= smoothstep(1.05, 0.18, radial);
    color += accent * nebula * (0.022 + mid * 0.015);

    float horizonGlow = exp(-abs(uv.y - 0.39) * 19.0);
    horizonGlow *= smoothstep(1.12, 0.12, abs(centered.x));
    color += secondaryAccent
        * horizonGlow
        * (0.032 + low * 0.026);

    float perspectiveY = max(0.08, uv.y + 0.04);
    float2 gridPoint = float2(
        centered.x / perspectiveY * 1.8,
        1.0 / perspectiveY + uniforms.timeAndAudio.x * 0.025
    );
    float2 gridCell = abs(fract(gridPoint) - 0.5);
    float gridEdgeDistance = 0.5 - max(gridCell.x, gridCell.y);
    float gridLine = 1.0 - smoothstep(0.0, 0.038, gridEdgeDistance);
    gridLine *= smoothstep(0.64, 0.18, uv.y) * smoothstep(0.02, 0.20, uv.y);
    float gridStrength = dot(preset, float3(0.28, 0.16, 0.22));
    color += accent * gridLine * gridStrength * (0.65 + low * 0.35);

    float depthRay = abs(
        sin(
            atan2(centered.y + 0.10, centered.x)
                * 14.0
                + uniforms.timeAndAudio.x * 0.025
        )
    );
    depthRay = pow(depthRay, 28.0)
        * smoothstep(0.96, 0.10, radial)
        * smoothstep(0.58, 0.12, uv.y);
    color += secondaryAccent * depthRay * preset.z * 0.10;

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
    color += accent * ringGlow * 1.65;

    float angle = atan2(centered.y, centered.x);
    float liquidBand = 0.5 + 0.5 * sin(
        radial * 34.0
            + sin(angle * 4.0 + uniforms.timeAndAudio.x * 0.22) * 2.2
            - uniforms.timeAndAudio.x * 0.86
    );
    liquidBand = smoothstep(0.78, 0.98, liquidBand)
        * smoothstep(0.76, 0.10, radial);
    color += secondaryAccent
        * liquidBand
        * preset.y
        * (0.035 + mid * 0.075);

    float pulseRing = 1.0 - smoothstep(
        0.012,
        0.034,
        abs(fract(radial * 4.2 - uniforms.timeAndAudio.x * 0.075) - 0.5)
    );
    pulseRing *= smoothstep(0.84, 0.14, radial);
    color += accent
        * pulseRing
        * preset.z
        * (0.05 + low * 0.085);

    float2 starDrift = float2(
        uniforms.timeAndAudio.x * 0.25,
        uniforms.timeAndAudio.x * -0.08
    );
    float2 starCell = floor(
        (uv * uniforms.viewportAndMotion.xy + starDrift) / 4.0
    );
    float star = step(0.996, stageHash(starCell));
    float twinkle = 0.45 + 0.55 * sin(
        uniforms.timeAndAudio.x * 1.6 + stageHash(starCell + 7.3) * 6.283
    );
    color += secondaryAccent
        * star
        * twinkle
        * (0.28 + high * 0.22);

    float2 distantCell = floor(
        (uv * uniforms.viewportAndMotion.xy - starDrift * 0.22) / 11.0
    );
    float distantStar = step(0.988, stageHash(distantCell + 19.7));
    color += accent * distantStar * (0.10 + high * 0.08);

    float vignette = smoothstep(1.22, 0.28, radial);
    color *= 0.30 + vignette * 0.70;
    color += accent
        * exp(-radial * 5.2)
        * (0.018 + low * 0.018);

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
            preset.x * float3(0.05, 0.72, 1.0)
                + preset.y * float3(0.02, 1.0, 0.82)
                + preset.z * float3(0.58, 0.16, 1.0),
            0.46 + preset.y * 0.12
        )
            * (1.06 + high * 0.34 + uniforms.viewportAndMotion.z * 0.10),
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
    float soft = 1.0 - smoothstep(0.20, 0.5, distance);
    float core = 1.0 - smoothstep(0.015, 0.17, distance);
    float front = smoothstep(0.62, 1.72, input.depth);
    float3 distantBlue = float3(0.03, 0.40, 1.0);
    float3 depthColor = mix(distantBlue, input.color.rgb, front);
    float3 neonColor = depthColor * (0.78 + core * 0.74);
    neonColor += float3(0.32, 0.82, 1.0) * core * 0.22;
    float alpha = soft * (0.42 + core * 0.58);
    return float4(neonColor, alpha);
}
