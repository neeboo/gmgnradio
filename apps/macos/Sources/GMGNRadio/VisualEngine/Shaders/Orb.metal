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
    float scale;
    float listeningRing;
    float4 accentColor;
    float flowIntensity;
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

fragment float4 orbFragment(
    OrbVertexOut input [[stage_in]],
    constant OrbUniforms &uniforms [[buffer(0)]]
) {
    float2 point = input.uv * 2.0 - 1.0;
    point.x *= uniforms.resolution.x / max(uniforms.resolution.y, 1.0);

    float angle = atan2(point.y, point.x);
    float radius = length(point);
    float motionAmount = saturate(uniforms.deformation);
    float breath = sin(uniforms.time * (0.72 + uniforms.energy * 0.8))
        * 0.026
        * motionAmount;
    float contour = sin(angle * 5.0 + uniforms.time * 0.55) * 0.014;
    contour += sin(angle * 9.0 - uniforms.time * 0.36) * 0.007;
    float sphereRadius = (0.68 + breath + contour * motionAmount)
        * uniforms.scale;
    float signedDistance = radius - sphereRadius;

    float body = 1.0 - smoothstep(-0.01, 0.025, signedDistance);
    float rim = smoothstep(0.18, 0.0, abs(signedDistance))
        * smoothstep(0.50, 0.93, radius / max(sphereRadius, 0.001));
    float outerGlow = exp(-max(signedDistance, 0.0) * 15.0)
        * smoothstep(0.20, -0.02, signedDistance)
        * uniforms.glow;
    float listeningRing = exp(-abs(signedDistance - 0.09) * 80.0)
        * uniforms.listeningRing
        * (0.18 + 0.12 * sin(uniforms.time * 2.2));

    float edgeCells = orbHash(floor((point + 1.0) * 38.0));
    float particles = step(0.985 - uniforms.particleAmount * 0.08, edgeCells)
        * smoothstep(0.20, 0.0, abs(signedDistance))
        * uniforms.particleAmount;

    float normalizedRadius = radius / max(sphereRadius, 0.001);
    float normalZ = sqrt(max(1.0 - normalizedRadius * normalizedRadius, 0.0));
    float flowCoordinate = point.x * 4.1 + point.y * 2.2;
    float flowCurve = sin(point.y * 3.4 - uniforms.time * 0.22) * 0.52;
    float flowWaveA = 0.5 + 0.5 * sin(
        flowCoordinate + flowCurve - uniforms.time * 0.48
    );
    float flowWaveB = 0.5 + 0.5 * sin(
        point.x * -2.8 + point.y * 4.6 + uniforms.time * 0.34
    );
    float flowBand = smoothstep(0.68, 0.98, flowWaveA)
        + smoothstep(0.78, 1.0, flowWaveB) * 0.55;
    flowBand = saturate(flowBand) * uniforms.flowIntensity;
    float flowSheen = pow(
        saturate(0.28 + normalZ * 0.72),
        2.2
    ) * (0.16 + flowBand * 0.44);

    float3 whiteBase = float3(0.96, 0.985, 1.0);
    float3 accent = saturate(uniforms.accentColor.rgb);
    float3 accentSoft = mix(whiteBase, accent, 0.58);
    float3 accentDeep = accent * 0.42;
    float3 color = mix(whiteBase, accentSoft, 0.20 + flowBand * 0.42);
    color = mix(color, accentDeep, smoothstep(0.86, 1.35, flowBand) * 0.18);
    color += accentSoft * flowSheen * 0.24;

    float sphereLight = 0.82 + normalZ * 0.24;
    color *= sphereLight;
    color = mix(color, accent, rim * 0.48);

    float3 surfaceNormal = normalize(float3(
        point / max(sphereRadius, 0.001),
        normalZ
    ));
    float highlight = pow(
        saturate(dot(surfaceNormal, normalize(float3(-0.38, 0.44, 0.82)))),
        14.0
    );
    color += highlight * 0.26;
    color += accentSoft * outerGlow * 0.38;
    color += accent * listeningRing;
    color += particles;

    float alpha = clamp(
        (body * (0.84 + uniforms.energy * 0.08)
            + outerGlow * 0.34
            + listeningRing * 0.22)
            * uniforms.opacity,
        0.0,
        1.0
    );
    return float4(color * alpha, alpha);
}
