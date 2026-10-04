Shader "GMGN/GpuLyricsDraw"
{
 SubShader {
  Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Transparent+100" "RenderType"="Transparent" }
  Pass {
   Tags { "LightMode"="SRPDefaultUnlit" }
   Blend SrcAlpha OneMinusSrcAlpha
   ZWrite Off
   ZTest Always
   Cull Off
   HLSLPROGRAM
   #pragma target 4.5
   #pragma vertex Vert
   #pragma fragment Frag
   #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
   struct Point {float4 position;float4 color;float4 timing;};
   StructuredBuffer<Point> _Points;
   float4 _Viewport;
   struct V {float4 position:SV_POSITION;float2 uv:TEXCOORD0;float4 color:COLOR;float glow:TEXCOORD1;};
   V Vert(uint vertex:SV_VertexID,uint instance:SV_InstanceID) {
    const float2 corners[6]={float2(-1,-1),float2(-1,1),float2(1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
    Point p=_Points[instance];
    float2 pixel=p.position.xy+corners[vertex]*p.position.w*(1+p.timing.x*2);
    V o;o.position=float4(pixel.x/_Viewport.x*2-1,1-pixel.y/_Viewport.y*2,0,1);o.uv=corners[vertex];o.color=p.color;o.glow=p.timing.x;return o;
   }
   half4 Frag(V i):SV_Target {float distance=length(i.uv)*(1+i.glow*2);float alpha=1-smoothstep(.65,1,distance);alpha+=exp(-distance*distance*.55)*i.glow*.065;clip(i.color.a*alpha-.005);return half4(i.color.rgb,i.color.a*saturate(alpha));}
   ENDHLSL
  }
 }
}
