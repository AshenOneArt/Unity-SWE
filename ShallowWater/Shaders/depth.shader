Shader "Hidden/DepthCopy"
{
    Properties
    {
        // Not used, but required for the Blit command.
        _MainTex("Texture", 2D) = "white" {}
    }
    SubShader
    {
        Tags { "RenderPipeline"="HighDefinitionRenderPipeline" }
        Pass
        {
            ZWrite Off
            Cull Off
            ZTest Always

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"

            // The depth texture is passed here by HDRP
            TEXTURE2D_X(_InputDepthTexture);
            SAMPLER(sampler_InputDepthTexture);
            float _SimulationPixelSize;
            float _SceneDepthRTSize;

            struct Attributes
            {
                uint vertexID : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            Varyings Vert(Attributes input)
            {
                Varyings o;
                o.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID);
                o.uv = GetFullScreenTriangleTexCoord(input.vertexID);
                return o;
            }

            float Frag(Varyings input) : SV_Target
            {      
                float depth = LOAD_TEXTURE2D_X(_InputDepthTexture, input.positionCS.xy * (_SceneDepthRTSize/_SimulationPixelSize)).r;
                return  max(0, _WorldSpaceCameraPos.y - ((1 - depth) * (_ProjectionParams.z - _ProjectionParams.y)));
            }
            ENDHLSL
        }
    }
}