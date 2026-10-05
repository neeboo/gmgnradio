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
            int _PixelSizing;
            float _StageParticleScale;
            struct Varying { float4 positionCS : SV_POSITION; float2 uv : TEXCOORD0; float4 color : COLOR;float2 shape:TEXCOORD1; };
            Varying Vert(uint vertex : SV_VertexID, uint instance : SV_InstanceID)
            {
                const float2 corners[6] = { float2(-1,-1),float2(-1,1),float2(1,1),float2(-1,-1),float2(1,1),float2(1,-1) };
                Point p = _Points[instance];
                float3 center = mul(_CloudToWorld, float4(p.position.xyz, 1)).xyz;
                float3 positionVS = TransformWorldToView(center);
                if(_PixelSizing==0)positionVS.xy += corners[vertex] * p.position.w;
                Varying o;
                o.positionCS = mul(UNITY_MATRIX_P, float4(positionVS, 1));
                if(_PixelSizing!=0){float perspective=clamp(8.5/max(o.positionCS.w,.6),p.timing.z>4.5?.42:.55,p.timing.z>4.5?2.8:2.4);float size=clamp(p.position.w*perspective,p.timing.z>4.5?.75:1.45,p.timing.z>4.5?28:11)*_StageParticleScale;o.positionCS.xy+=corners[vertex]*size/_ScreenParams.xy*o.positionCS.w;}
                o.uv = corners[vertex];
                o.color = p.color;
                o.shape=_PixelSizing!=0?float2(p.timing.x,p.timing.w):float2(0,0);
                return o;
            }
            half4 Frag(Varying i) : SV_Target
            {
                float2 rotated=float2(cos(i.shape.y)*i.uv.x-sin(i.shape.y)*i.uv.y,sin(i.shape.y)*i.uv.x+cos(i.shape.y)*i.uv.y);
                float radius=lerp(length(i.uv),abs(rotated.x)+abs(rotated.y),i.shape.x);
                float alpha = 1 - smoothstep(.65, 1, radius);
                clip(alpha - .01);
                return half4(i.color.rgb, i.color.a * alpha);
            }
            ENDHLSL
        }
    }
}
