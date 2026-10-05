Shader "GMGN/GpuLyricsGlyphDraw"
{
 SubShader {
  Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Transparent+100" "RenderType"="Transparent" }
  Pass {
   Tags { "LightMode"="SRPDefaultUnlit" }
   // Preserve coverage alpha in the transparent glow target instead of
   // multiplying it twice; RGB becomes premultiplied for the composite pass.
   Blend SrcAlpha OneMinusSrcAlpha, One OneMinusSrcAlpha
   ZWrite Off
   ZTest Always
   Cull Off
   HLSLPROGRAM
   #pragma target 4.5
   #pragma vertex Vert
   #pragma fragment Frag
   #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
   struct Glyph { float4 rectangle;float4 atlas;float4 timing;float4 color;float4 metadata;float4 transform;float4 transition;float4 motion;float4 effects; };
   struct Point {float4 position;float4 color;float4 timing;};
   StructuredBuffer<Glyph> _Glyphs;
   StructuredBuffer<Point> _Points;
   Texture2DArray<float4> _FontAtlas;
   SamplerState sampler_FontAtlas;
   float4 _Viewport;
   float4 _Accent,_Secondary,_Primary;
   int _DrawLayer;
   int _EffectTarget;
   float _Clock;
   int _Chorus;
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
   struct V {float4 position:SV_POSITION;float2 uv:TEXCOORD0;float4 color:COLOR;float4 atlas:TEXCOORD1;float4 info:TEXCOORD2;float2 size:TEXCOORD3;float4 fill:TEXCOORD4;float4 effects:TEXCOORD5;float4 phase:TEXCOORD6;};
   V Vert(uint vertex:SV_VertexID,uint instance:SV_InstanceID) {
    const float2 corners[6]={float2(-1,-1),float2(-1,1),float2(1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
    Glyph g=_Glyphs[instance];Point p=_Points[instance];float kind=p.timing.w;
    float2 dimensions=g.rectangle.zw;
    if(kind==1)dimensions.x=p.position.w;
    if(kind==2)dimensions=g.rectangle.zw*2;
    if(kind==3)dimensions=p.position.ww*2;
    float progress=saturate((_Clock-g.timing.x)/max(.01,g.timing.y-g.timing.x));
    float active=step(g.timing.x,_Clock)*step(_Clock,g.timing.y)*g.metadata.x;
    float waiting=(1-step(g.timing.x,_Clock))*g.metadata.x;
    float dynamicGlow=active*(10+sin(progress*3.14159)*8);
    float padding=kind==0 && _DrawLayer==1?2*max(g.effects.x+waiting*.55,g.effects.w):0;
    float2 padded=dimensions+padding*2;
    float2 delta=corners[vertex]*padded*.5*p.timing.y;
    if(kind==0 && g.metadata.y==8 && g.metadata.x!=0 && g.transition.w>.5)delta.x-=delta.y*.18;
    float angle=p.timing.z;
    if(g.metadata.y==3 || g.metadata.y==4 || g.metadata.y==10){delta.x*=cos(angle);delta/=max(.4,1-sin(angle)*delta.x/max(1,_Viewport.x)*.7);}
    else delta=float2(cos(angle)*delta.x-sin(angle)*delta.y,sin(angle)*delta.x+cos(angle)*delta.y);
    float2 pixel=p.position.xy+delta;
    V o;o.position=float4(pixel.x/_Viewport.x*2-1,(1-pixel.y/_Viewport.y*2)*(_EffectTarget!=0?1:_ProjectionParams.x),0,1);
    o.uv=(corners[vertex]*padded/max(float2(.001,.001),dimensions))*.5+.5;o.color=p.color;o.atlas=g.atlas;o.info=float4(max(0,g.metadata.z),kind,p.timing.x,g.metadata.w);o.size=dimensions;o.fill=g.transform;
    if(kind==7)o.fill=g.effects;
    o.effects=g.effects;o.effects.x+=waiting*.55;o.phase=float4(active,dynamicGlow,g.motion.x,g.motion.y);return o;
   }
   float Coverage(float2 uv,V i){
    if(any(uv<0)||any(uv>1))return 0;
    float2 glyphUV=float2(uv.x,_EffectTarget==0 && _ProjectionParams.x<0?1-uv.y:uv.y);
    float sdf=_FontAtlas.Sample(sampler_FontAtlas,float3(i.atlas.xy+glyphUV*i.atlas.zw,i.info.x)).a;
    return smoothstep(.5-max(fwidth(sdf),.002),.5+max(fwidth(sdf),.002),sdf);
   }
   float SoftCoverage(V i,float radius){
    if(radius<.01)return Coverage(i.uv,i);
    // Fixed Gaussian quadrature, bounded per pixel; never reads pixels on CPU.
    float2 offset=radius/max(float2(1,1),i.size);
    float coverage=Coverage(i.uv,i)*.24;
    const float2 taps[8]={float2(1,0),float2(-1,0),float2(0,1),float2(0,-1),float2(.707,.707),float2(-.707,.707),float2(.707,-.707),float2(-.707,-.707)};
    [unroll]for(int n=0;n<8;n++)coverage+=Coverage(i.uv+taps[n]*offset,i)*.095;
    return coverage;
   }
   half4 Frag(V i):SV_Target {
    // Separate bubble background and glyph submissions preserve Swift's
    // .background layering independently of GPU instance raster ordering.
    bool background=abs(i.info.y-4)<.1 || abs(i.info.y-7)<.1;
    if((_DrawLayer==0 && !background)||(_DrawLayer==1 && background)||(_DrawLayer==2 && i.info.y>.1))discard;
    float alpha=0;float3 rgb=i.color.rgb;
    if(i.info.y<.5){
     if(_DrawLayer==2){
      if(i.effects.z==0 && i.phase.x==0)discard;
      float glowAlpha=max(i.effects.z,i.phase.x*.7)*Coverage(i.uv,i)*i.color.a;
      clip(glowAlpha-.004);
      float3 glowColor=_Chorus!=0?_Secondary.rgb:_Accent.rgb;
      return half4(glowColor,glowAlpha);
     }
     alpha=SoftCoverage(i,i.effects.x);
     float shadow=i.effects.w>.01?SoftCoverage(i,i.effects.w)*(i.effects.w<4?.78:.9):0;
     float combined=alpha+shadow*(1-alpha);
     rgb*=alpha/max(combined,1e-6);alpha=combined;
    }else if(i.info.y<1.5){
     float t=saturate(i.uv.y);
     rgb=lerp(_Accent.rgb,_Secondary.rgb,saturate(t*2));
     alpha=t<.5?lerp(.9,.4,t*2):lerp(.4,0,(t-.5)*2);
     return half4(rgb,alpha);
    }
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
    }else if(i.info.y<6.5){
     float distance=VoiceDistance((i.uv-.5)*2,i.info.w);
     float halfStroke=1.25/max(1,min(i.size.x,i.size.y));float aa=max(fwidth(distance),.002);
     alpha=1-smoothstep(halfStroke-aa*.5,halfStroke+aa*.5,distance);
    }else{
     float2 halfSize=i.size*.5;float radius=min(i.phase.z,min(halfSize.x,halfSize.y));
     float2 q=abs((i.uv-.5)*i.size)-halfSize+radius;
     float distance=length(max(q,0))+min(max(q.x,q.y),0)-radius;
     float aa=max(fwidth(distance),.001);
     float fillAlpha=(1-smoothstep(-.5,.5,distance))*i.fill.a;
     float border=(1-smoothstep(i.phase.w*.5-aa*.5,i.phase.w*.5+aa*.5,abs(distance)))*i.color.a;
     float t=saturate((i.uv.x+i.uv.y)*.5);
     float3 borderColor=i.color.rgb;
     if(i.info.w<.5){borderColor=t<.5?lerp(_Accent.rgb,_Secondary.rgb,t*2):lerp(_Secondary.rgb,_Primary.rgb,(t-.5)*2);border*=t<.5?lerp(1,.48,t*2):lerp(.48,.76,(t-.5)*2);}
     float combined=fillAlpha+border*(1-fillAlpha);
     clip(combined-.004);
     return half4((i.fill.rgb*fillAlpha+borderColor*border*(1-fillAlpha))/max(combined,1e-6),combined);
    }
    alpha*=i.color.a;clip(alpha-.004);return half4(rgb,saturate(alpha));
   }
   ENDHLSL
  }
 }
}
