// SPDX-License-Identifier: MIT
// Adapted from UnityGaussianSplatting GaussianComposite.shader.
// Copyright (c) Aras Pranckevicius; see package LICENSE.md.
// GMGN modification: transparent and nonfinite splat pixels never divide by zero.
Shader "Hidden/GMGN/GaussianCompositeGuarded"
{
    SubShader {
        Pass {
            ZWrite Off
            ZTest Always
            Cull Off
            Blend SrcAlpha OneMinusSrcAlpha
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma require compute
            #pragma use_dxc
            #include "UnityCG.cginc"
            struct v2f { float4 vertex : SV_POSITION; };
            v2f vert(uint vtxID : SV_VertexID) {
                v2f o;
                float2 quadPos = float2(vtxID & 1, (vtxID >> 1) & 1) * 4.0 - 1.0;
                o.vertex = float4(quadPos, 1, 1);
                return o;
            }
            Texture2D _GaussianSplatRT;
            float4 frag(v2f i) : SV_Target {
                float4 col = _GaussianSplatRT.Load(int3(i.vertex.xy, 0));
                // Clear pixels are (0,0,0,0); 0/0 contaminated HDR cubemap
                // pixels even under SrcAlpha blending (NaN * 0 is NaN).
                if (!(col.a > 1e-6) || !all(isfinite(col))) return 0;
                float3 straight = max(col.rgb / col.a, 0);
                float3 linearColor = GammaToLinearSpace(straight);
                if (!all(isfinite(linearColor))) return 0;
                // Gaussian URP intermediate targets use half-float HDR.
                // Keep finite float32 results representable after storage.
                return float4(min(linearColor, 65504.0), saturate(col.a));
            }
            ENDCG
        }
    }
}
