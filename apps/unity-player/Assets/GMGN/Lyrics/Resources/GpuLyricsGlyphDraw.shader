Shader "GMGN/GpuLyricsGlyphDraw"
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
   struct Glyph { float4 rectangle;float4 atlas;float4 timing;float4 color;float4 metadata;float4 transform;float4 transition;float4 motion; };
   struct Point {float4 position;float4 color;float4 timing;};
   StructuredBuffer<Glyph> _Glyphs;
   StructuredBuffer<Point> _Points;
   Texture2DArray<float4> _FontAtlas;
   SamplerState sampler_FontAtlas;
   float4 _Viewport;
   float4 _Accent,_Secondary;
   int _DrawLayer;
   float SegmentDistance(float2 p,float2 a,float2 b){float2 q=p-a;float2 segment=b-a;return length(q-segment*saturate(dot(q,segment)/dot(segment,segment)));}
   float VoiceDistance(float2 p,float voice){
    float distance=10;
    if(voice<.5){
     distance=min(SegmentDistance(p,float2(-.6,-.35),float2(-.6,.35)),SegmentDistance(p,float2(-.2,-.8),float2(-.2,.8)));
     distance=min(distance,SegmentDistance(p,float2(.2,-1),float2(.2,1)));distance=min(distance,SegmentDistance(p,float2(.6,-.45),float2(.6,.45)));
    }else if(voice<1.5){
     distance=min(SegmentDistance(p,float2(.35,-.7),float2(.35,.4)),SegmentDistance(p,float2(.35,-.7),float2(-.08,-.58)));
     distance=min(distance,abs(length((p-float2(.04,.43))/float2(.3,.19))-1)*.19);
    }else if(voice<2.5){
     distance=abs(length((p-float2(0,-.35))/float2(.23,.43))-1)*.23;
     float support=abs(length(p-float2(0,-.08))-.45);if(p.y<-.08)support=10;
     distance=min(distance,support);distance=min(distance,SegmentDistance(p,float2(0,.42),float2(0,.82)));distance=min(distance,SegmentDistance(p,float2(-.28,.82),float2(.28,.82)));
    }else{
     distance=abs(length(p-float2(0,-.55))-.2);
     distance=min(distance,abs(length(p-float2(-.58,-.35))-.14));distance=min(distance,abs(length(p-float2(.58,-.35))-.14));
     distance=min(distance,SegmentDistance(p,float2(-.35,.65),float2(-.35,.2)));distance=min(distance,SegmentDistance(p,float2(.35,.65),float2(.35,.2)));
     float central=abs(length(p-float2(0,.22))-.35);if(p.y>.22)central=10;distance=min(distance,central);
     distance=min(distance,SegmentDistance(p,float2(-.84,.6),float2(-.84,.1)));distance=min(distance,SegmentDistance(p,float2(.84,.6),float2(.84,.1)));
    }
    return distance;
   }
   struct V {float4 position:SV_POSITION;float2 uv:TEXCOORD0;float4 color:COLOR;float4 atlas:TEXCOORD1;float4 info:TEXCOORD2;float2 size:TEXCOORD3;float4 fill:TEXCOORD4;};
   V Vert(uint vertex:SV_VertexID,uint instance:SV_InstanceID) {
    const float2 corners[6]={float2(-1,-1),float2(-1,1),float2(1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
    Glyph g=_Glyphs[instance];Point p=_Points[instance];float kind=p.timing.w;
    float2 dimensions=g.rectangle.zw;
    if(kind==2)dimensions=g.rectangle.zw*2;
    if(kind==3)dimensions=p.position.ww*2;
    float2 delta=corners[vertex]*dimensions*.5*p.timing.y;
    float angle=p.timing.z;
    if(g.metadata.y==3 || g.metadata.y==4 || g.metadata.y==10){delta.x*=cos(angle);delta/=max(.4,1-sin(angle)*delta.x/max(1,_Viewport.x)*.7);}
    else delta=float2(cos(angle)*delta.x-sin(angle)*delta.y,sin(angle)*delta.x+cos(angle)*delta.y);
    float2 pixel=p.position.xy+delta;
    V o;o.position=float4(pixel.x/_Viewport.x*2-1,(1-pixel.y/_Viewport.y*2)*_ProjectionParams.x,0,1);
    o.uv=corners[vertex]*.5+.5;o.color=p.color;o.atlas=g.atlas;o.info=float4(max(0,g.metadata.z),kind,p.timing.x,g.metadata.w);o.size=dimensions;o.fill=g.transform;return o;
   }
   half4 Frag(V i):SV_Target {
    // Separate bubble background and glyph submissions preserve Swift's
    // .background layering independently of GPU instance raster ordering.
    if((_DrawLayer==0 && abs(i.info.y-4)>.1)||(_DrawLayer==1 && abs(i.info.y-4)<.1))discard;
    float alpha=0;float3 rgb=i.color.rgb;
    if(i.info.y<.5){
     float2 glyphUV=float2(i.uv.x,_ProjectionParams.x<0?1-i.uv.y:i.uv.y);
     float sdf=_FontAtlas.Sample(sampler_FontAtlas,float3(i.atlas.xy+glyphUV*i.atlas.zw,i.info.x)).a;
     float edge=max(fwidth(sdf),.002);
     float coverage=smoothstep(.5-edge,.5+edge,sdf);
     float outline=smoothstep(.43-edge,.43+edge,sdf);
     float halo=smoothstep(.34,.5,sdf)*i.info.z*.09;
     alpha=max(coverage,outline*.65)+halo;
     rgb=lerp(float3(0,0,0),rgb,coverage);
    }else if(i.info.y<1.5){alpha=1-i.uv.y;}
    else if(i.info.y<2.5){float2 d=(i.uv-.5)*2;float radial=length(d);alpha=(1-smoothstep(.008,.02,abs(radial-.97)))*step(0,d.x);}
    else if(i.info.y<3.5){alpha=1-smoothstep(.5,1,length((i.uv-.5)*2));}
    else if(i.info.y<4.5){
     float2 halfSize=i.size*.5;float radius=i.info.w>.5?halfSize.y:(i.uv.x<.5&&i.uv.y<.5?8:30);radius=min(radius,min(halfSize.x,halfSize.y));
     float2 q=abs((i.uv-.5)*i.size)-halfSize+radius;
     float distance=length(max(q,0))+min(max(q.x,q.y),0)-radius;
     float fillAlpha=(1-smoothstep(-.5,.5,distance))*i.fill.a;
     // Logical-pixel coverage; fwidth tracks Retina backing scale.
     float aa=max(fwidth(distance),.001);float halfStroke=i.info.w>.5?.4:.5;
     float strokeAlpha=(1-smoothstep(halfStroke-aa*.5,halfStroke+aa*.5,abs(distance)))*i.color.a;
     float combined=fillAlpha+strokeAlpha*(1-fillAlpha);
     clip(combined-.004);
     float3 combinedRgb=(i.fill.rgb*fillAlpha+i.color.rgb*strokeAlpha*(1-fillAlpha))/max(combined,1e-6);
     return half4(combinedRgb,combined);
    }else if(i.info.y<5.5){
     alpha=1-smoothstep(.97,1,length((i.uv-.5)*2));
     if(i.info.w>.5)rgb=lerp(_Accent.rgb,_Secondary.rgb,(i.uv.x+i.uv.y)*.5);
    }else{
     float distance=VoiceDistance((i.uv-.5)*2,i.info.w);
     float halfStroke=1.25/max(1,min(i.size.x,i.size.y));float aa=max(fwidth(distance),.002);
     alpha=1-smoothstep(halfStroke-aa*.5,halfStroke+aa*.5,distance);
    }
    alpha*=i.color.a;clip(alpha-.004);return half4(rgb,saturate(alpha));
   }
   ENDHLSL
  }
 }
}
