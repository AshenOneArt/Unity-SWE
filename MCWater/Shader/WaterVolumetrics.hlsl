
#ifndef WATER_VOLUMETRICS_INCLUDED
#define WATER_VOLUMETRICS_INCLUDED
#define PHSYCL_SCATTER


#define PI 3.14159265358979323846
// Include HDRP common functions
#include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
#include "WaterFunctionLibary.hlsl"

#define WATER_SAMPLE_COUNT 2
#define expFactor 2.5

// Utility functions
float LinearizeDepthFast(float depth, float near, float far) 
{
    return (near * far) / (depth * (near - far) + far);
}

float FogPhase(float lightPoint)
{
	float slinear = clamp(-lightPoint*0.5+0.5,0.0,1.0);
	float linear2 = 1.0 - clamp(lightPoint,0.0,1.0);

	float exponential = exp2(pow(slinear,0.3) * -15.0 ) * 1.5;
	exponential += sqrt(exp2(sqrt(slinear) * -12.5));

	// float exponential = 1.0 / (linear * 10.0 + 0.05);

	return exponential;
}
float HenyeyPhase(float cos_theta,float PhaseG)
{
    //PhaseG = max(PhaseG,0.00001f);
    const float result = (1 - PhaseG*PhaseG)/pow(abs(1 + PhaseG*PhaseG - 2 * PhaseG * cos_theta),1.5f);
    return  result;
}

float3 Saturation(float3 In, float Saturation)
{
    float luma = dot(In, float3(0.2126729, 0.7151522, 0.0721750));
    return  luma.xxx + Saturation.xxx * (In - luma.xxx);
}

float3 FresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

//==============================================================================
float4 WaterVolumetrics(
    // Input parameters
    WaterLightLoopData waterLightLoopData,
    uint featureFlags,
    float MaxDistance,
    float PhaseG,
    float3 AmbientLight,
    float2 ScreenUV,    
    float3 LightDir,
    float3 LightColor,
    PositionInputs posInput,
    LightLoopContext lightLoopContext,
    DirectionalLightData light,
    BuiltinData builtinData,
    BSDFData bsdfData,
    
    // Output
    out float3 absorbance

)
{    
    // Initialize variables
    absorbance = float3(1.0, 1.0, 1.0);
    float3 scatteredLight = float3(0.0, 0.0, 0.0);
    float3 RayStart = waterLightLoopData.StartPos;
    float3 RayEnd = waterLightLoopData.EndPos;
    float RayLength = waterLightLoopData.RayLength;
    float3 RayDirection = waterLightLoopData.RayDirection;
    float NormalizedRayLength = waterLightLoopData.NormalizedRayLength;
    float3 NormalizedRayDirection = waterLightLoopData.NormalizedRayDirection;
    float AmbientDepth = waterLightLoopData.NormalizedAmbientDepth;
    float SunDepth = waterLightLoopData.NormalizedSunDepth;
    float3 WaterAbsorption = waterLightLoopData.WaterAbsorption;
    float3 ScatterCoefficient = waterLightLoopData.ScatterCoefficient;

    float Dither = waterLightLoopData.Dither;
    float3 phaseScatter;
    float phase;

    float4 indirectLightColor = EvaluateLight_Directional(lightLoopContext, posInput, light);
    float cosTheta = dot(safeNormalize(RayEnd), safeNormalize(LightDir));

    // Phase function calculation
#if defined(PHSYCL_SCATTER)
    //瑞丽散射占比5%，米氏散射占比95%
    static const float3 betaRayleigh = float3(5.8e-6, 13.5e-6, 33.1e-6); // ∝ 1/λ⁴        
    // Rayleigh phase function: (3 / (16π)) * (1 + cos²θ) ≈ simplified to just (1 + cos²θ)
    float rayleighPhase = (1.0 + cosTheta * cosTheta) * (3 / (16 * PI));
    float3 rayleighScatter = betaRayleigh * rayleighPhase * 1e5;

    float g2 = PhaseG * PhaseG;
    float denom = 1.0 + g2 - 2.0 * PhaseG * cosTheta;
    float mieScatter = (1.0 - g2) / pow(denom, 1.5);
    phaseScatter = rayleighScatter * 0.05 + float3(mieScatter,mieScatter,mieScatter) * 0.95;
#else
    float VdotL = dot(safeNormalize(RayEnd), safeNormalize(LightDir));
    phase = FogPhase(VdotL) * 5;
    phaseScatter = phase;
#endif

    // Depth-based ambient attenuation
    float verticalFactor = -safeNormalize(NormalizedRayDirection + _WorldSpaceCameraPos.xyz).y;
    verticalFactor = clamp(verticalFactor - 0.333, 0.0, 1.0);
    verticalFactor = pow(1.0 - pow(1.0 - verticalFactor, 2.0), 2.0);
    verticalFactor *= 15.0;
    float3 shadowValue = float3(0.0, 0.0, 0.0);

    // Ray marching loop
    for (int i = 0; i < WATER_SAMPLE_COUNT; i++)
    {
        // Exponential sampling distribution
        float d = (pow(expFactor, float(i+Dither)/float(WATER_SAMPLE_COUNT))/expFactor - 1.0/expFactor)/(1-1.0/expFactor);
		float dd = pow(expFactor, float(i+Dither)/float(WATER_SAMPLE_COUNT)) * log(expFactor) / float(WATER_SAMPLE_COUNT)/(expFactor-1.0);
        
        // Calculate light attenuation due to water absorption
        float3 sunAbsorbance = exp(-WaterAbsorption * SunDepth * d);
        float3 ambientAbsorbance = exp(-WaterAbsorption * (AmbientDepth * d + verticalFactor));

        float shadowStep = (pow(expFactor, float(i+Dither)/float(WATER_SAMPLE_COUNT))/expFactor - 1.0/expFactor)/(1-1.0/expFactor);
        float3 samplePos = RayStart + NormalizedRayDirection * shadowStep ;  


        if (featureFlags & LIGHTFEATUREFLAGS_DIRECTIONAL)
        {
            if (_DirectionalShadowIndex >= 0)
            {
                DirectionalLightData light = _DirectionalLightDatas[_DirectionalShadowIndex];
#if defined(SCREEN_SPACE_SHADOWS_ON) && !defined(_SURFACE_TYPE_TRANSPARENT)
                if (UseScreenSpaceShadow(light, bsdfData.normalWS))
                {
                    shadowValue = GetScreenSpaceColorShadow(posInput, light.screenSpaceShadowIndex).SHADOW_TYPE_SWIZZLE;
                }
                else
#endif                
                {
                
                    // TODO: this will cause us to load from the normal buffer first. Does this cause a performance problem?
                    float3 L = -light.forward;

                    // Is it worth sampling the shadow map?
                    if ((light.lightDimmer > 0) && (light.shadowDimmer > 0))
                    {
                        float3 positionWS = samplePos;

#ifdef LIGHT_EVALUATION_SPLINE_SHADOW_BIAS
                        positionWS += L * GetSplineOffsetForShadowBias(bsdfData);
#endif
                        shadowValue = GetDirectionalShadowAttenuation(lightLoopContext.shadowContext,
                                                                        posInput.positionSS, positionWS, GetNormalForShadowBias(bsdfData),
                                                                        light.shadowIndex, L);

#ifdef LIGHT_EVALUATION_SPLINE_SHADOW_VISIBILITY_SAMPLE
                // Tap the shadow a second time for strand visibility term.
                        lightLoopContext.splineVisibility = GetDirectionalShadowAttenuation(lightLoopContext.shadowContext,
                                                                            posInput.positionSS, positionWS, GetNormalForShadowBias(bsdfData),
                                                                            light.shadowIndex, L);
#endif
                    }
                }
            }
        }
    
    
        
        
        // Direct and indirect lighting
        float3 directLighting = LightColor * phaseScatter * shadowValue;
        //阴影并不会完全屏蔽掉直射光对散射的贡献，依然能从阴影的周围散射部分光量，所以加入部分来自直射光的间接光
        float3 indirectLighting = indirectLightColor.rgb * ambientAbsorbance * 0.25;
        //*ambientAbsorbance
        
        //总合成
        // 随着深度延申，米尔散射颜色的变化趋近于白色，所以需要饱和度衰减
        float scatterSaturationFactor = max(1 - saturate(RayLength/(_MaxDistance * 5)),0.75);        
        float3 totalLight = (directLighting + indirectLighting) * Saturation(ScatterCoefficient,scatterSaturationFactor);

        float shallowdepth = saturate(NormalizedRayLength / _MaxDistance);
        totalLight *= lerp(0.6,1,shallowdepth);
        
        // Volume coefficient for this step
        float3 volumeCoeff = exp(-WaterAbsorption * dd * NormalizedRayLength);
        
        // Accumulate scattered light using Beer-Lambert law
        scatteredLight += (totalLight - totalLight * volumeCoeff) / (WaterAbsorption) * absorbance;
        
        // Update absorbance
        absorbance *= volumeCoeff;
    }
    // Calculate view direction from surface to camera
    float3 viewDirection = normalize(_WorldSpaceCameraPos.xyz - RayEnd);
    // Fresnel effect: higher reflection at grazing angles
    float cosThet = saturate(dot(bsdfData.normalWS, viewDirection));
    scatteredLight *= (1 - FresnelSchlick(cosThet, float3(0.02,0.02,0.02)));
    // Return final result    
    float averageAbsorbance = dot(absorbance,float3(0.33, 0.33, 0.33));
    return float4(scatteredLight, averageAbsorbance) * (1-averageAbsorbance);
    //VolumetricResult = float4(phaseScatter,1);
}


#endif // WATER_VOLUMETRICS_INCLUDED saturate(dot(bsdfData.normalWS - _WorldSpaceCameraPos.xyz,safeNormalize(RayEnd)))