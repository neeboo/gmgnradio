Shader "GMGN/GpuLyricsBlur" {
 Properties { _MainTex("Mask",2D)="black"{} }
 SubShader {
  Tags { "RenderPipeline"="UniversalPipeline" }
  HLSLINCLUDE
  #include "UnityCG.cginc"
  sampler2D _MainTex;
  float4 _MainTex_TexelSize;
  float _GaussianWeights[7];
  float _GaussianOffsets[7];
  float _GaussianDirectWeights[13];
  float _GaussianStride;
  int _GaussianPaired;
  half4 Blur(v2f_img input,float2 axis) {
   float2 stride=axis*_MainTex_TexelSize.xy;
   if(_GaussianPaired==0){
    half4 direct=tex2D(_MainTex,input.uv)*_GaussianDirectWeights[0];
    [unroll]for(int n=1;n<=12;n++){
     float2 offset=stride*(n*_GaussianStride);
     direct+=(tex2D(_MainTex,input.uv+offset)+tex2D(_MainTex,input.uv-offset))*_GaussianDirectWeights[n];
    }
    return direct;
   }
   half4 color=tex2D(_MainTex,input.uv)*_GaussianWeights[0];
   [unroll]for(int pair=1;pair<=6;pair++) {
    float2 offset=stride*_GaussianOffsets[pair];
    color+=(tex2D(_MainTex,input.uv+offset)+tex2D(_MainTex,input.uv-offset))*_GaussianWeights[pair];
   }
   return color;
  }
  half4 Horizontal(v2f_img input):SV_Target{return Blur(input,float2(1,0));}
  half4 Vertical(v2f_img input):SV_Target{return Blur(input,float2(0,1));}
  ENDHLSL
  Pass {
   ZTest Always ZWrite Off Cull Off
   HLSLPROGRAM
   #pragma vertex vert_img
   #pragma fragment Horizontal
   ENDHLSL
  }
  Pass {
   ZTest Always ZWrite Off Cull Off
   HLSLPROGRAM
   #pragma vertex vert_img
   #pragma fragment Vertical
   ENDHLSL
  }
 }
}
