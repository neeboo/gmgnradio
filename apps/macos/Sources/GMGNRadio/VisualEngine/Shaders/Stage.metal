#include <metal_stdlib>
using namespace metal;

struct StageUniforms {
    float4x4 viewProjection;
    float4 timeAndAudio;
    float4 viewportAndMotion;
    float4 visualPreset;
    float4 topologyMotion;
    float4 rhythm;
    float4 waveformA;
    float4 waveformB;
    float4 palettePrimary;
    float4 paletteSecondary;
    float4 paletteBackground;
    float4 compositing;
    float4 layering;
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
    float bloomStrength;
    float edgeContrast;
    float ambientShape;
    float ambientRotation;
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

float3 stagePrismaticColor(float hue) {
    float3 offsets = float3(0.0, 0.6666667, 0.3333333);
    return 0.52 + 0.48 * cos(
        6.2831853 * (fract(hue) + offsets)
    );
}

float3 stageReadableArtworkColor(
    float3 color,
    float luminance,
    float edge
) {
    float shadowAmount = 1.0 - smoothstep(0.06, 0.48, luminance);
    float liftAmount = 0.28 + shadowAmount * 0.38;
    float3 gammaLifted = sqrt(max(color, float3(0.0)));
    float3 lifted = mix(color, gammaLifted, liftAmount);
    return min(
        lifted * (1.04 + edge * 0.32),
        float3(1.32)
    );
}

float stageWaveValue(
    int index,
    float4 waveformA,
    float4 waveformB
) {
    switch (index) {
        case 0: return waveformA.x;
        case 1: return waveformA.y;
        case 2: return waveformA.z;
        case 3: return waveformA.w;
        case 4: return waveformB.x;
        case 5: return waveformB.y;
        case 6: return waveformB.z;
        default: return waveformB.w;
    }
}

float stageWaveEnvelope(
    float coordinate,
    float4 waveformA,
    float4 waveformB
) {
    float scaled = clamp(fract(coordinate), 0.0, 0.9999) * 8.0;
    int left = int(floor(scaled));
    int right = min(left + 1, 7);
    return mix(
        stageWaveValue(left, waveformA, waveformB),
        stageWaveValue(right, waveformA, waveformB),
        fract(scaled)
    );
}

float3 stageNeutralBackgroundColor(float2 uv, float aspect) {
    float2 centered = uv - 0.5;
    centered.x *= aspect;
    float radius = length(centered);
    float vertical = smoothstep(0.0, 1.0, uv.y);
    float3 bottom = float3(0.0060, 0.0065, 0.0080);
    float3 top = float3(0.0020, 0.0024, 0.0032);
    float3 color = mix(bottom, top, vertical);
    color += float3(0.0050)
        * exp(-radius * 5.2);
    color *= 0.52 + smoothstep(1.08, 0.20, radius) * 0.48;
    return color;
}

fragment float4 stageBackgroundFragment(
    StageBackgroundOut input [[stage_in]],
    constant StageUniforms &uniforms [[buffer(0)]]
) {
    float neutralAspect = uniforms.viewportAndMotion.x
        / max(uniforms.viewportAndMotion.y, 1.0);
    float3 quietColor = stageNeutralBackgroundColor(
        input.uv,
        neutralAspect
    );
    float backgroundAlpha = clamp(uniforms.paletteBackground.a, 0.0, 1.0);
    return float4(quietColor * backgroundAlpha, backgroundAlpha);

    float2 uv = input.uv;
    float aspect = uniforms.viewportAndMotion.x
        / max(uniforms.viewportAndMotion.y, 1.0);
    float low = uniforms.timeAndAudio.y;
    float mid = uniforms.timeAndAudio.z;
    float high = uniforms.timeAndAudio.w;
    float beat = uniforms.rhythm.x;
    float onset = uniforms.rhythm.y;
    float3 preset = uniforms.visualPreset.xyz;
    float intensity = uniforms.visualPreset.w;
    float2 centered = uv - 0.5;
    centered.x *= aspect;

    float liquidAmount = preset.y * (0.008 + mid * 0.013) * intensity;
    float pulseAmount = preset.z * (0.004 + low * 0.010) * intensity;
    centered += float2(
        sin(centered.y * 13.0 + uniforms.timeAndAudio.x * 0.38),
        cos(centered.x * 11.0 - uniforms.timeAndAudio.x * 0.31)
    ) * liquidAmount;
    centered *= 1.0 + sin(
        length(centered) * 18.0 - uniforms.timeAndAudio.x * 0.72
    ) * pulseAmount + beat * 0.018;

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
        * (0.05 + low * 0.085 + beat * 0.12);

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
        * (0.28 + high * 0.22 + onset * 0.24);

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
    constant StageUniforms &uniforms [[buffer(1)]],
    texture2d<float> artworkTexture [[texture(0)]]
) {
    StageParticleVertex particle = vertices[vertexID];
    float3 position = particle.positionAndSize.xyz;
    float phase = particle.colorAndPhase.w;
    float time = uniforms.timeAndAudio.x;
    float low = uniforms.timeAndAudio.y;
    float mid = uniforms.timeAndAudio.z;
    float high = uniforms.timeAndAudio.w;
    float beat = uniforms.rhythm.x;
    float onset = uniforms.rhythm.y;
    float amplitude = uniforms.rhythm.z;
    float3 preset = uniforms.visualPreset.xyz;
    float intensity = uniforms.visualPreset.w;
    float coherentSpeed = uniforms.topologyMotion.x;
    float deformationGain = uniforms.topologyMotion.y;
    float jitterGain = uniforms.topologyMotion.z;
    float composition = uniforms.topologyMotion.w;
    float compositionBase = clamp(composition, 0.0, 1.0);
    float manualVariant = clamp(composition - 1.0, 0.0, 1.0);
    float presetMass = clamp(dot(preset, float3(1.0)), 0.0, 1.0);
    float topologyAlpha = 1.0;

    float2 coverUV = clamp(position.xy / 6.0 + 0.5, 0.0, 1.0);
    constexpr sampler artworkSampler(
        filter::linear,
        address::clamp_to_edge
    );
    float2 artworkSampleUV = float2(coverUV.x, 1.0 - coverUV.y);
    float3 artworkColor = artworkTexture.sample(
        artworkSampler,
        artworkSampleUV
    ).rgb;
    float2 artworkTexel = float2(
        1.0 / max(float(artworkTexture.get_width()), 1.0),
        1.0 / max(float(artworkTexture.get_height()), 1.0)
    );
    float curtainNoise = sin(
        coverUV.x * 18.0
            + coverUV.y * 11.0
            - time * 1.45
            + phase
    );
    float3 curtainPosition = float3(
        position.x,
        position.y,
        curtainNoise * (0.10 + mid * 0.34)
    );
    float foldAngle = (coverUV.x - 0.5) * 1.34;
    float foldDepth = sin(
        coverUV.x * 8.0 * 3.14159265 + time * 0.16
    ) * (0.34 + mid * 0.24);
    float3 foldedCanvasPosition = float3(
        sin(foldAngle) * 4.25,
        position.y * 0.92,
        cos(foldAngle) * 2.1 - 1.65 + foldDepth
    );
    curtainPosition = mix(
        curtainPosition,
        foldedCanvasPosition,
        compositionBase
    );

    // Mineradio's cover-particle preset samples the complete artwork and
    // raises it into a shallow relief. Frequency columns move only along the
    // surface normal, so the cover remains readable and never self-rotates.
    float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
    float artworkLuma = dot(artworkColor, lumaWeights);
    float artworkLeft = dot(
        artworkTexture.sample(
            artworkSampler,
            artworkSampleUV - float2(artworkTexel.x * 2.0, 0.0)
        ).rgb,
        lumaWeights
    );
    float artworkRight = dot(
        artworkTexture.sample(
            artworkSampler,
            artworkSampleUV + float2(artworkTexel.x * 2.0, 0.0)
        ).rgb,
        lumaWeights
    );
    float artworkUp = dot(
        artworkTexture.sample(
            artworkSampler,
            artworkSampleUV - float2(0.0, artworkTexel.y * 2.0)
        ).rgb,
        lumaWeights
    );
    float artworkDown = dot(
        artworkTexture.sample(
            artworkSampler,
            artworkSampleUV + float2(0.0, artworkTexel.y * 2.0)
        ).rgb,
        lumaWeights
    );
    float artworkEdge = clamp(
        length(float2(
            artworkRight - artworkLeft,
            artworkDown - artworkUp
        )) * 2.4,
        0.0,
        1.0
    );
    float coverCenterBias = 1.0 - clamp(
        length((coverUV - 0.5) * 1.34),
        0.0,
        1.0
    );
    float coverRelief = (artworkLuma - 0.5) * 0.34
        + artworkEdge * 0.28
        + (coverCenterBias - 0.5) * 0.10;
    float coverColumnWave = stageWaveEnvelope(
        coverUV.x,
        uniforms.waveformA,
        uniforms.waveformB
    );
    float coverColumnDisplacement = (
        coverColumnWave - uniforms.rhythm.w
    ) * (0.28 + amplitude * 0.68) * (0.72 + intensity * 0.28);
    coverColumnDisplacement += beat
        * (0.08 + low * 0.18)
        * (0.40 + 0.60 * sin(coverUV.x * 18.0 + phase));
    float3 albumReliefPosition = float3(
        position.xy * 0.88,
        coverRelief + coverColumnDisplacement
    );
    curtainPosition = mix(
        curtainPosition,
        albumReliefPosition,
        manualVariant
    );

    float theta = coverUV.x * 6.2831853 + time * 0.12;
    float phi = (coverUV.y - 0.5) * 3.14159265;
    float surfaceLuma = dot(
        artworkColor,
        float3(0.2126, 0.7152, 0.0722)
    ) - 0.5;
    float shellFold = sin(theta * 3.0 + phi * 2.2)
        * cos(phi * 4.0 - theta)
        * 0.18;
    float meridianFold = cos(theta * 5.0 - phi * 1.5) * 0.10;
    float sphereRadius = 2.46
        + low * 0.24
        + beat * 0.14
        + shellFold
        + meridianFold
        + surfaceLuma * 0.32;
    float equatorTension = 1.0 + cos(phi * 2.0) * 0.12;
    float3 spherePosition = float3(
        sphereRadius * cos(phi) * cos(theta) * equatorTension,
        sphereRadius * sin(phi)
            * (0.94 + sin(theta * 2.0 + phi) * 0.06),
        sphereRadius * cos(phi) * sin(theta)
            * (1.04 - cos(phi * 3.0) * 0.08)
    );
    float helixStrand = floor(coverUV.x * 2.0);
    float helixWidth = fract(coverUV.x * 2.0) - 0.5;
    float helixAngle = (coverUV.y - 0.5) * 8.0 * 3.14159265
        + helixStrand * 3.14159265
        + time * 0.22;
    float helixRadius = 1.34 + helixWidth * 0.72;
    float3 helixPosition = float3(
        cos(helixAngle) * helixRadius,
        (coverUV.y - 0.5) * 6.7,
        sin(helixAngle) * helixRadius
    );
    spherePosition = mix(
        spherePosition,
        helixPosition,
        compositionBase
    );

    // Kept as a manual-only variant. Automatic direction never selects the
    // tunnel because a closed tube overwhelms the desktop stage.
    float tunnelFlow = fract(coverUV.y - time * 0.032);
    float tunnelAngle = coverUV.x * 6.2831853 + time * 0.09;
    float tunnelDepth = (tunnelFlow - 0.5) * 8.8;
    float tunnelRadius = 2.16
        + sin(tunnelAngle * 5.0 + tunnelDepth * 1.2)
            * (0.055 + mid * 0.16)
        - low * 0.14;
    float3 tunnelPosition = float3(
        cos(tunnelAngle) * tunnelRadius,
        sin(tunnelAngle) * tunnelRadius,
        tunnelDepth
    );
    spherePosition = mix(
        spherePosition,
        tunnelPosition,
        manualVariant
    );

    // An open, twisting album ribbon replaces the closed tunnel. Its visible
    // edges keep the form from reading as a tube while the cover stays legible.
    float ribbonAlong = (coverUV.y - 0.5) * 7.2;
    float ribbonAcross = (coverUV.x - 0.5) * 4.8;
    float ribbonTime = time * coherentSpeed;
    float twistWave = sin(ribbonTime * 0.18) * 0.08;
    float ribbonTwist = ribbonAlong * (0.68 + twistWave)
        + ribbonTime * 0.10;
    float ribbonWidth = 0.82
        + sin(ribbonAlong * 1.16 - ribbonTime * 0.42) * 0.07;
    float3 ribbonCenter = float3(
        sin(ribbonAlong * 0.58 + ribbonTime * 0.16) * 0.82,
        ribbonAlong * 0.70,
        cos(ribbonAlong * 0.46 - ribbonTime * 0.12) * 0.62
    );
    float3 ribbonAxis = normalize(float3(
        cos(ribbonTwist),
        sin(ribbonAlong * 0.92 + ribbonTime * 0.18) * 0.08,
        sin(ribbonTwist)
    ));
    float3 ribbonPosition = ribbonCenter
        + ribbonAxis * ribbonAcross * ribbonWidth;
    float3 ribbonLift = normalize(float3(
        -sin(ribbonTwist),
        0.22,
        cos(ribbonTwist)
    ));
    ribbonPosition += ribbonLift
        * sin(ribbonAlong * 1.34 - ribbonTime * 0.72)
        * 0.025;
    float bloomAzimuth = (coverUV.x - 0.5) * 6.2831853;
    float bloomLatitude = (coverUV.y - 0.5) * 3.14159265;
    float bloomRadius = 2.15
        + sin(bloomAzimuth * 5.0 + time * 0.14) * 0.46
        + cos(bloomLatitude * 4.0 - time * 0.11) * 0.26;
    float3 bloomPosition = float3(
        bloomRadius * cos(bloomLatitude) * cos(bloomAzimuth),
        bloomRadius * sin(bloomLatitude) * 1.18,
        bloomRadius * cos(bloomLatitude) * sin(bloomAzimuth)
    );
    ribbonPosition = mix(
        ribbonPosition,
        bloomPosition,
        compositionBase
    );

    // Layered star-river lanes derived from Mineradio's wallpaper flow. The
    // field stays open and directional, so it reads as depth rather than fog.
    float galaxyLaneCoordinate = coverUV.y * 6.0;
    float galaxyLane = floor(galaxyLaneCoordinate);
    float galaxyLocal = fract(galaxyLaneCoordinate) - 0.5;
    float galaxyLaneUnit = (galaxyLane + 0.5) / 6.0;
    float galaxyAlong = (coverUV.x - 0.5) * 10.8;
    float galaxyPhase = galaxyAlong * (0.42 + galaxyLaneUnit * 0.18)
        + galaxyLane * 1.37
        - time * (0.055 + galaxyLaneUnit * 0.025);
    float galaxyBroadWave = sin(galaxyPhase);
    float galaxyFineWave = sin(galaxyPhase * 2.4 + phase) * 0.11;
    float3 galaxyPosition = float3(
        galaxyAlong + galaxyBroadWave * (0.36 + galaxyLaneUnit * 0.3),
        (galaxyLaneUnit - 0.5) * 5.7
            + galaxyBroadWave * 0.72
            + galaxyLocal * 0.48,
        (galaxyLaneUnit - 0.5) * 6.4
            + cos(galaxyPhase * 0.76) * 1.18
            + galaxyFineWave
    );
    ribbonPosition = mix(
        ribbonPosition,
        galaxyPosition,
        manualVariant
    );

    position = curtainPosition * preset.x
        + spherePosition * preset.y
        + ribbonPosition * preset.z;

    float albumReliefAmount = preset.x * manualVariant;
    artworkColor *= mix(
        1.0,
        0.90 + artworkLuma * 0.18 + artworkEdge * 0.10,
        albumReliefAmount
    );
    artworkColor = mix(
        artworkColor,
        stageReadableArtworkColor(
            artworkColor,
            artworkLuma,
            artworkEdge
        ),
        albumReliefAmount
    );

    float radius = max(length(position), 0.001);
    float3 direction = position / radius;
    float waveCoordinate = phase / 6.2831853
        + position.y * 0.075
        - time * 0.12;
    float waveform = stageWaveEnvelope(
        waveCoordinate,
        uniforms.waveformA,
        uniforms.waveformB
    );
    float waveCentered = waveform - uniforms.rhythm.w;
    float motion = dot(preset, float3(0.88, 1.18, 1.02))
        * mix(0.72, 1.18, intensity);
    float breathing = sin(time * 1.25 + phase)
        * (0.012 + low * 0.045)
        * motion;
    float ripple = sin(radius * 6.0 - time * 2.6 + phase)
        * mid
        * (0.045 + waveform * 0.075)
        * motion;
    float beatShock = beat
        * (0.15 + low * 0.17)
        * (0.58 + 0.42 * sin(phase * 2.0 + radius * 2.4));
    float waveformDepth = waveCentered
        * (0.10 + amplitude * 0.22)
        * motion;
    float3 tangent = normalize(
        cross(direction, float3(0.17, 1.0, 0.29))
            + float3(0.001, 0.0, 0.0)
    );
    float highJitter = sin(
        phase * 17.0 + time * (13.0 + high * 18.0)
    ) * high * (0.018 + onset * 0.055) * jitterGain;
    float3 reactiveDirection = normalize(mix(
        direction,
        float3(0.0, 0.0, 1.0),
        albumReliefAmount
    ));
    position += reactiveDirection * (
        breathing
            + ripple
            + beatShock
            + waveformDepth
    ) * deformationGain;
    position += tangent * highJitter * (1.0 - albumReliefAmount);

    float4 clipPosition = uniforms.viewProjection * float4(position, 1.0);
    float perspective = clamp(8.5 / max(clipPosition.w, 0.6), 0.55, 2.4);
    float pointSize = particle.positionAndSize.w
        * perspective
        * (
            2.10
                + intensity * 0.55
                + high * 1.10
                + beat * 1.18
                + onset * 0.65
        )
        * dot(preset, float3(1.0, 0.92, 1.12));
    float coverReadabilityScale = mix(1.0, 1.42, albumReliefAmount);
    pointSize *= coverReadabilityScale;

    StageParticleOut output;
    output.position = clipPosition;
    output.pointSize = clamp(pointSize, 1.45, 11.0)
        * presetMass
        * uniforms.compositing.x;
    float3 sourceColor = mix(
        particle.colorAndPhase.rgb,
        artworkColor,
        uniforms.viewportAndMotion.w
    );
    float propagationPhase = fract(
        coverUV.y * 0.72
            + coverUV.x * 0.34
            + radius * 0.065
            - time * (0.055 + coherentSpeed * 0.052)
            - waveform * 0.14
    );
    float propagationDistance = min(
        propagationPhase,
        1.0 - propagationPhase
    );
    float beatColorWave = (
        1.0 - smoothstep(0.018, 0.145, propagationDistance)
    ) * beat;
    float echoPhase = fract(propagationPhase + 0.17);
    float echoDistance = min(echoPhase, 1.0 - echoPhase);
    float echoWave = (
        1.0 - smoothstep(0.025, 0.19, echoDistance)
    ) * (beat * 0.58 + onset * 0.42);
    float spatialHue = fract(
        coverUV.x * 0.46
            + coverUV.y * 0.31
            + position.z * 0.055
            + phase * 0.014
            + sin(
                position.y * 0.82
                    + position.x * 0.31
                    - time * 0.07
            ) * 0.045
            + time * 0.014
    );
    float3 spatialPrism = stagePrismaticColor(spatialHue);
    float3 leadingPrism = stagePrismaticColor(
        spatialHue + propagationPhase * 0.72 + beat * 0.08
    );
    float3 trailingPrism = stagePrismaticColor(
        spatialHue - 0.18 + echoPhase * 0.36
    );
    float3 prismaticColor = mix(
        spatialPrism,
        leadingPrism,
        0.40 + beatColorWave * 0.50
    );
    prismaticColor = mix(
        prismaticColor,
        trailingPrism,
        0.12 + echoWave * 0.42
    );
    float3 moodTint = mix(
        uniforms.palettePrimary.rgb,
        uniforms.paletteSecondary.rgb,
        0.5 + 0.5 * sin(spatialHue * 6.2831853)
    );
    prismaticColor = mix(prismaticColor, moodTint, 0.10);
    float sourceLuma = dot(
        sourceColor,
        float3(0.2126, 0.7152, 0.0722)
    );
    float artworkDetail = mix(0.68, 1.14, sourceLuma);
    float frontAmount = clamp(
        0.5 + position.z * 0.12,
        0.0,
        presetMass * topologyAlpha
    );
    float depthLight = mix(0.58, 1.08, frontAmount);
    float audioLight = 0.92
        + amplitude * 0.16
        + beat * 0.20
        + onset * 0.12
        + beatColorWave * 0.36
        + echoWave * 0.16;
    float colorPresence = clamp(
        0.58 + intensity * 0.13 + amplitude * 0.09,
        0.58,
        0.82
    );
    colorPresence = mix(colorPresence, 0.14, albumReliefAmount);
    float galaxyAmount = preset.z * manualVariant;
    colorPresence = mix(colorPresence, 0.92, galaxyAmount);
    float3 layeredColor = mix(
        sourceColor,
        prismaticColor,
        colorPresence
    );
    float videoLayer = smoothstep(0.46, 0.76, uniforms.compositing.w);
    float particleKeep = smoothstep(
        0.68,
        0.84,
        stageHash(float2(phase, phase * 1.731 + 0.37))
    );
    float porousAmount = videoLayer
        * mix(1.0, 0.58, albumReliefAmount);
    float mainAlpha = mix(1.0, particleKeep, porousAmount);
    float artworkOccupancy = smoothstep(
        0.012,
        0.17,
        artworkLuma + artworkEdge * 0.72
    );
    float coverAlpha = mix(0.18, 1.0, artworkOccupancy);
    coverAlpha *= mix(
        0.055,
        1.0,
        uniforms.viewportAndMotion.w
    );
    mainAlpha *= mix(1.0, coverAlpha, albumReliefAmount);
    output.color = float4(
        min(
            layeredColor
                * artworkDetail
                * depthLight
                * audioLight
                * uniforms.compositing.y
                * (1.0 + uniforms.viewportAndMotion.z * 0.08),
            float3(1.34)
        ),
        mainAlpha * uniforms.layering.x
    );
    output.depth = perspective;
    float coverBloomBoost = mix(1.0, 2.65, albumReliefAmount);
    output.bloomStrength = uniforms.compositing.z
        * mix(1.0, 0.58, galaxyAmount)
        * coverBloomBoost;
    output.edgeContrast = uniforms.compositing.w;
    output.ambientShape = 0.0;
    output.ambientRotation = 0.0;
    return output;
}

vertex StageParticleOut stageAmbientParticleVertex(
    uint vertexID [[vertex_id]],
    device const StageParticleVertex *vertices [[buffer(0)]],
    constant StageUniforms &uniforms [[buffer(1)]]
) {
    StageParticleVertex particle = vertices[vertexID];
    float3 position = particle.positionAndSize.xyz;
    float phase = particle.colorAndPhase.w;
    float time = uniforms.timeAndAudio.x;
    float beat = uniforms.rhythm.x;
    float onset = uniforms.rhythm.y;
    float amplitude = uniforms.rhythm.z;
    float low = uniforms.timeAndAudio.y;
    float high = uniforms.timeAndAudio.w;
    float sizeClass = smoothstep(1.18, 2.55, particle.positionAndSize.w);
    float heroClass = smoothstep(2.75, 4.20, particle.positionAndSize.w);
    float floorClass = 1.0 - smoothstep(-2.68, -1.84, position.y);

    position.x += sin(time * 0.075 + phase * 1.37)
        * mix(0.10, 0.32, sizeClass);
    position.y += cos(time * 0.093 + phase * 0.91)
        * mix(0.07, 0.22, sizeClass);
    position.y += floorClass
        * (low * 0.16 + beat * 0.32)
        * (0.4 + 0.6 * sin(phase * 2.0));
    position.z += sin(time * 0.052 + phase * 1.71)
        * mix(0.08, 0.28, sizeClass);

    float4 clipPosition = uniforms.viewProjection * float4(position, 1.0);
    float perspective = clamp(8.5 / max(clipPosition.w, 0.7), 0.42, 2.8);
    float audioScale = 1.0
        + amplitude * 0.16
        + high * 0.24
        + beat * mix(0.12, 0.34, sizeClass)
        + onset * 0.18;
    float pointSize = particle.positionAndSize.w
        * perspective
        * audioScale
        * uniforms.compositing.x
        * mix(1.0, 3.8, heroClass);
    float spatialHue = fract(
        position.x * 0.035
            + position.z * 0.022
            + phase / 6.2831853
            - time * 0.018
    );
    float3 spectral = stagePrismaticColor(spatialHue);
    float3 mood = mix(
        uniforms.palettePrimary.rgb,
        uniforms.paletteSecondary.rgb,
        0.5 + 0.5 * sin(phase + time * 0.11)
    );
    float twinkle = pow(
        0.5 + 0.5 * sin(time * (0.42 + high * 0.8) + phase * 3.1),
        5.0
    );
    float3 color = mix(particle.colorAndPhase.rgb, spectral, 0.48);
    color = mix(color, mood, 0.22);
    color *= 0.55 + twinkle * 0.72 + beat * 0.24;

    StageParticleOut output;
    output.position = clipPosition;
    output.pointSize = clamp(pointSize, 0.75, 28.0);
    output.color = float4(
        min(color * uniforms.compositing.y, float3(1.42)),
        mix(0.26, 0.72, sizeClass)
            * (0.72 + twinkle * 0.28)
            * uniforms.layering.y
    );
    output.depth = perspective;
    output.bloomStrength = uniforms.compositing.z;
    output.edgeContrast = uniforms.compositing.w;
    output.ambientShape = max(heroClass, floorClass * 0.72);
    output.ambientRotation = phase
        + time * mix(0.035, 0.12, heroClass)
        * (0.45 + 0.55 * sin(phase * 1.7));
    return output;
}

fragment float4 stageAmbientParticleFragment(
    StageParticleOut input [[stage_in]],
    float2 pointCoordinate [[point_coord]]
) {
    float2 centered = pointCoordinate - 0.5;
    float rotationCos = cos(input.ambientRotation);
    float rotationSin = sin(input.ambientRotation);
    float2 rotated = float2(
        centered.x * rotationCos - centered.y * rotationSin,
        centered.x * rotationSin + centered.y * rotationCos
    );
    float roundDistance = length(centered);
    float squareDistance = max(abs(rotated.x), abs(rotated.y));
    float roundMask = 1.0 - smoothstep(0.10, 0.50, roundDistance);
    float squareMask = 1.0 - smoothstep(0.34, 0.50, squareDistance);
    float ambientShape = smoothstep(0.50, 0.84, input.ambientShape);
    float mask = mix(roundMask, squareMask, ambientShape);
    float core = 1.0 - smoothstep(
        0.02,
        mix(0.17, 0.34, ambientShape),
        mix(roundDistance, squareDistance, ambientShape)
    );
    float alpha = mask
        * input.color.a
        * (0.34 + core * 0.66)
        * (0.48 + input.bloomStrength * 0.52);
    float squareEdge = smoothstep(0.24, 0.46, squareDistance)
        * (1.0 - smoothstep(0.46, 0.50, squareDistance));
    float facetLight = clamp(
        0.58 + rotated.x * 0.72 - rotated.y * 0.38,
        0.42,
        1.18
    );
    float3 color = input.color.rgb
        * (0.68 + core * 0.66)
        * mix(1.0, facetLight, ambientShape * 0.48);
    color += input.color.rgb * squareEdge * ambientShape * 0.34;
    return float4(color, alpha);
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
    float3 depthColor = mix(
        input.color.rgb * 0.34,
        input.color.rgb,
        front
    );
    float3 neonColor = depthColor * (0.78 + core * 0.74);
    neonColor += input.color.rgb * core * 0.22;
    float alpha = soft * (0.42 + core * 0.58) * input.color.a;
    float luminance = dot(
        neonColor,
        float3(0.2126, 0.7152, 0.0722)
    );
    float rim = smoothstep(0.27, 0.39, distance)
        * (1.0 - smoothstep(0.40, 0.51, distance))
        * input.edgeContrast;
    float3 contrastColor = mix(
        float3(0.92, 0.97, 1.0),
        float3(0.008, 0.012, 0.022),
        smoothstep(0.42, 0.76, luminance)
    );
    neonColor = mix(neonColor, contrastColor, rim * 0.72);
    alpha = max(alpha, rim * 0.68);
    return float4(neonColor, alpha);
}

fragment float4 stageParticleBloomFragment(
    StageParticleOut input [[stage_in]],
    float2 pointCoordinate [[point_coord]]
) {
    float2 centered = pointCoordinate - 0.5;
    float distance = length(centered);
    float glow = 1.0 - smoothstep(0.03, 0.50, distance);
    glow *= glow;
    float pulse = 0.48 + input.bloomStrength * 0.52;
    float alpha = glow
        * input.bloomStrength
        * input.color.a
        * 0.54;
    return float4(input.color.rgb * pulse, alpha);
}
