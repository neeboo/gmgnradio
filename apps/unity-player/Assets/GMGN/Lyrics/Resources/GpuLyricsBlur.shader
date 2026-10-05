Shader "GMGN/GpuLyricsBlur" {
 Properties { _MainTex("Mask",2D)="black"{} }
 SubShader {
  Tags { "RenderPipeline"="UniversalPipeline" }
  HLSLINCLUDE
  #include "UnityCG.cginc"
  sampler2D _MainTex;
  float4 _MainTex_TexelSize;
  float _Radius;
  half4 Blur(v2f_img input,float2 axis) {
   float sigma=max(.5,_Radius*.5);
   float2 stride=axis*_MainTex_TexelSize.xy*max(1,_Radius/12);
   float sum=0;half4 color=0;
   [unroll]for(int n=-12;n<=12;n++) {
    float distance=n*max(1,_Radius/12);
    float weight=exp(-distance*distance/(2*sigma*sigma));
    color+=tex2D(_MainTex,input.uv+stride*n)*weight;sum+=weight;
   }
   return color/max(sum,.0001);
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
