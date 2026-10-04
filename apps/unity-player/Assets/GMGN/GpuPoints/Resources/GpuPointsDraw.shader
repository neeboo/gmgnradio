Shader "GMGN/GpuPointsDraw"
{
    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Transparent" "RenderType"="Transparent" }
        Pass
        {
            Tags { "LightMode"="SRPDefaultUnlit" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            Cull Off
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment Frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            struct Point { float4 position; float4 color; float4 timing; };
            StructuredBuffer<Point> _Points;
            float4x4 _CloudToWorld;
            struct Varying { float4 positionCS : SV_POSITION; float2 uv : TEXCOORD0; float4 color : COLOR; };
            Varying Vert(uint vertex : SV_VertexID, uint instance : SV_InstanceID)
            {
                const float2 corners[6] = { float2(-1,-1),float2(-1,1),float2(1,1),float2(-1,-1),float2(1,1),float2(1,-1) };
                Point p = _Points[instance];
                float3 center = mul(_CloudToWorld, float4(p.position.xyz, 1)).xyz;
                float3 positionVS = TransformWorldToView(center);
                positionVS.xy += corners[vertex] * p.position.w;
                Varying o;
                o.positionCS = mul(UNITY_MATRIX_P, float4(positionVS, 1));
                o.uv = corners[vertex];
                o.color = p.color;
                return o;
            }
            half4 Frag(Varying i) : SV_Target
            {
                float alpha = 1 - smoothstep(.65, 1, length(i.uv));
                clip(alpha - .01);
                return half4(i.color.rgb, i.color.a * alpha);
            }
            ENDHLSL
        }
    }
}
