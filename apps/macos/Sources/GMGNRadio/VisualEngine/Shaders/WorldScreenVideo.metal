#include <metal_stdlib>
using namespace metal;

// 世界坐标的电视视频四边形。
//
// 这份 shader 只做三件事，一件都不多做：
// 1. 把 `WorldScreenNativeVideoRegistry` 给出的**世界四角**投到裁剪空间；
// 2. 按当前深度约定翻转（与 `marbleOccluderVertex` 逐字同式：SceneKit 反向深度时
//    `z = w - z`），于是它与房间遮挡网格 / 已摆放道具 / 角色共用同一张深度缓冲；
// 3. 采样解码出来的视频纹理，并把它从 sRGB 编码转回线性 —— drawable 是
//    `bgra8Unorm_srgb`，写出时会再做一次线性→sRGB，不先转就会二次 gamma（发灰）。
//
// 深度测试与写入由管线状态给（forward=`.less`、reverse=`.greater`，都写深度）：
// 前墙/道具挡住电视；电视画完之后，身后的角色与道具被它挡住。
struct WorldScreenVideoUniforms {
    float4x4 viewProjection;
    // x = 1 时按 SceneKit 反向深度约定翻转。与 `marbleOccluderVertex` 同一判据。
    float4 depthConvention;
};

struct WorldScreenVideoInOut {
    float4 position [[position]];
    float2 uv;
};

vertex WorldScreenVideoInOut worldScreenVideoVertex(
    const device float3 *positions [[buffer(0)]],
    const device float2 *texcoords [[buffer(1)]],
    constant WorldScreenVideoUniforms &uniforms [[buffer(2)]],
    uint vertexID [[vertex_id]]
) {
    float4 clipPosition = uniforms.viewProjection
        * float4(positions[vertexID], 1.0);
    if (uniforms.depthConvention.x > 0.5) {
        clipPosition.z = clipPosition.w - clipPosition.z;
    }
    WorldScreenVideoInOut output;
    output.position = clipPosition;
    output.uv = texcoords[vertexID];
    return output;
}

fragment float4 worldScreenVideoFragment(
    WorldScreenVideoInOut input [[stage_in]],
    texture2d<float> videoTexture [[texture(0)]]
) {
    constexpr sampler videoSampler(
        filter::linear,
        address::clamp_to_edge
    );
    float3 encoded = videoTexture.sample(videoSampler, input.uv).rgb;
    float3 linear = select(
        encoded / 12.92,
        pow((encoded + 0.055) / 1.055, 2.4),
        encoded > 0.04045
    );
    return float4(linear, 1.0);
}
