Shader "GMGN/GpuLyricsGlowComposite" {
 SubShader {
  Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Transparent+99" }
  Pass {
   Blend One OneMinusSrcAlpha
   ZWrite Off ZTest Always Cull Off
   HLSLPROGRAM
   #pragma target 4.5
   #pragma vertex Vert
   #pragma fragment Frag
   #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
   Texture2D<float4> _GlowTexture;
   SamplerState sampler_GlowTexture;
   struct V {float4 position:SV_POSITION;float2 uv:TEXCOORD0;};
   V Vert(uint vertex:SV_VertexID) {
    const float2 corners[6]={float2(0,0),float2(0,1),float2(1,1),float2(0,0),float2(1,1),float2(1,0)};
    V output;output.uv=corners[vertex];
    output.position=float4(output.uv.x*2-1,(1-output.uv.y*2)*_ProjectionParams.x,0,1);return output;
   }
   half4 Frag(V input):SV_Target{return _GlowTexture.Sample(sampler_GlowTexture,input.uv);}
   ENDHLSL
  }
 }
}
