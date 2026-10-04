Shader "GMGN/Characters/PMX Stage Lit"
{
    Properties
    {
        _BaseMap("PMX texture", 2D) = "white" {}
        _BaseColor("PMX tint", Color) = (1,1,1,1)
        [HideInInspector] _Cull("Cull", Float) = 0
        [HideInInspector] _SrcBlend("Source blend", Float) = 1
        [HideInInspector] _DstBlend("Destination blend", Float) = 0
        [HideInInspector] _ZWrite("Depth write", Float) = 1
    }
    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "RenderType"="Opaque" }
        Pass
        {
            Tags { "LightMode"="UniversalForward" }
            Cull [_Cull]
            Blend [_SrcBlend] [_DstBlend]
            ZWrite [_ZWrite]
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                half4 _BaseColor;
            CBUFFER_END
            struct Attributes { float4 positionOS : POSITION; float3 normalOS : NORMAL; float2 uv : TEXCOORD0; };
            struct Varyings { float4 positionCS : SV_POSITION; float3 normalWS : TEXCOORD0; float3 positionWS : TEXCOORD1; float2 uv : TEXCOORD2; };
            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.positionWS = TransformObjectToWorld(input.positionOS.xyz);
                output.positionCS = TransformWorldToHClip(output.positionWS);
                output.normalWS = TransformObjectToWorldNormal(input.normalOS);
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                return output;
            }
            half4 Frag(Varyings input, bool frontFace : SV_IsFrontFace) : SV_Target
            {
                half4 base = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv) * _BaseColor;
                half3 normal = normalize(input.normalWS) * (frontFace ? 1 : -1);
                Light light = GetMainLight();
                half diffuse = saturate(dot(normal, light.direction));
                half3 ambient = max(SampleSH(normal), half3(0.22, 0.22, 0.22));
                half3 view = normalize(GetWorldSpaceViewDir(input.positionWS));
                half specular = pow(saturate(dot(normal, normalize(view + light.direction))), 24) * 0.0324;
                return half4(base.rgb * (ambient + light.color * diffuse) + light.color * specular, base.a);
            }
            ENDHLSL
        }
    }
}
