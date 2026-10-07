Shader "GMGN/PlacementGrid"
{
    Properties { _Color ("Color", Color) = (0.1,0.8,0.6,0.45) }
    SubShader {
        Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Transparent" "RenderType"="Transparent" }
        Pass {
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Off
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            struct Attributes { float4 positionOS : POSITION; float2 uv : TEXCOORD0; };
            struct Varyings { float4 positionCS : SV_POSITION; float2 uv : TEXCOORD0; };
            float4 _Color;
            Varyings vert(Attributes v) { Varyings o; o.positionCS=TransformObjectToHClip(v.positionOS.xyz); o.uv=v.uv; return o; }
            half4 frag(Varyings i) : SV_Target {
                float edge=min(min(i.uv.x,1-i.uv.x),min(i.uv.y,1-i.uv.y));
                float smoothing=max(fwidth(edge),0.001);
                float gridLine=1-smoothstep(0.035-smoothing,0.035+smoothing,edge);
                return half4(_Color.rgb,_Color.a * lerp(0.18,1,gridLine));
            }
            ENDHLSL
        }
    }
}
