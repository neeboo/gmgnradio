#include <metal_stdlib>
using namespace metal;

// 建造模式的格子四边。
//
// 每个实例一个 quad，位置由 vertex_id 生成、世界位置来自实例缓冲。刻意不做顶点缓冲：
// 格子数量随房间变大，实例缓冲只需要存 center/size/color 这些"每格唯一"的数据。
//
// 深度由调用方通过 pipeline 的 depth attachment 处理（复用 splat 场景的同一个深度纹理），
// 所以格子会被墙和家具正确遮挡 —— 这是"格子不浮在画面最上层"的全部实现。
struct PropSupportGridInstance {
    // xyz = 格子中心（已含抬高量），w = 边长（已扣掉缝隙）
    float4 centerSize;
    // rgba，alpha 由距离淡出决定
    float4 color;
};

struct PropSupportGridUniforms {
    float4x4 viewProjection;
};

struct PropSupportGridVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex PropSupportGridVertexOut propSupportGridVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant PropSupportGridUniforms &uniforms [[buffer(0)]],
    const device PropSupportGridInstance *instances [[buffer(1)]]
) {
    // 以中心为原点的四边角偏移，按 .triangleStrip 顺序给出。
    constexpr float2 corners[] = {
        float2(-0.5, -0.5),
        float2( 0.5, -0.5),
        float2(-0.5,  0.5),
        float2( 0.5,  0.5),
    };
    PropSupportGridInstance instance = instances[instanceID];
    float2 corner = corners[vertexID & 3];
    float halfSize = instance.centerSize.w * 0.5;
    float3 world = instance.centerSize.xyz + float3(corner.x * halfSize * 2.0, 0.0, corner.y * halfSize * 2.0);

    PropSupportGridVertexOut out;
    out.position = uniforms.viewProjection * float4(world, 1.0);
    out.color = instance.color;
    return out;
}

fragment float4 propSupportGridFragment(PropSupportGridVertexOut in [[stage_in]]) {
    // 不写深度：格子只做视觉提示，不应该把后面的物件或角色挡掉。
    // 深度测试仍然生效（会被墙/家具遮挡），只是不产生遮挡。
    return in.color;
}
