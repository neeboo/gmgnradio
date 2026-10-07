Shader "GMGN/BreathingOrb" {
 Properties { _Accent("Accent", Color) = (.16,.62,1,1) _Flow("Flow",Range(0,1))=.82 }
 SubShader { Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Transparent" "RenderType"="Transparent" }
  Pass { Blend One OneMinusSrcAlpha ZWrite Off Cull Off
   HLSLPROGRAM
   #pragma vertex vert
   #pragma fragment frag
   #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
   struct A {float4 positionOS:POSITION;float2 uv:TEXCOORD0;};
   struct V {float4 positionCS:SV_POSITION;float2 uv:TEXCOORD0;};
   CBUFFER_START(UnityPerMaterial)
   float4 _Accent;float _Flow;
   CBUFFER_END
   V vert(A a){V o;o.positionCS=TransformObjectToHClip(a.positionOS.xyz);o.uv=a.uv;return o;}
   half4 frag(V i):SV_Target {
    float2 p=i.uv*2-1;float t=_Time.y;float angle=atan2(p.y,p.x);float r=length(p);
    float sr=.68+sin(t*.72)*.026+sin(angle*5+t*.55)*.014+sin(angle*9-t*.36)*.007;
    float d=r-sr;float body=1-smoothstep(-.01,.025,d);
    float rim=(1-smoothstep(0,.18,abs(d)))*smoothstep(.50,.93,r/max(sr,.001));
    float glow=exp(-max(d,0)*15)*(1-smoothstep(-.02,.20,d));
    float z=sqrt(max(1-pow(r/sr,2),0));
    float wave=.5+.5*sin(p.x*4.1+p.y*2.2+sin(p.y*3.4-t*.22)*.52-t*.48);
    float waveB=.5+.5*sin(p.x*-2.8+p.y*4.6+t*.34);
    float band=saturate(smoothstep(.68,.98,wave)+smoothstep(.78,1,waveB)*.55)*_Flow;
    float3 white=float3(.96,.985,1),soft=lerp(white,_Accent.rgb,.58);
    float3 color=lerp(white,soft,.20+band*.42);
    color=lerp(color,_Accent.rgb*.42,smoothstep(.86,1.35,band)*.18);
    color+=soft*pow(saturate(.28+z*.72),2.2)*(.16+band*.44)*.24;
    color*=.82+z*.24;color=lerp(color,_Accent.rgb,rim*.48);
    color+=pow(saturate(dot(normalize(float3(p/sr,z)),normalize(float3(-.38,.44,.82)))),14)*.26;
    color+=soft*glow*.38;
    float alpha=saturate(body*.84+glow*.34);return half4(color*alpha,alpha);
   }
   ENDHLSL
  }
 }
}
