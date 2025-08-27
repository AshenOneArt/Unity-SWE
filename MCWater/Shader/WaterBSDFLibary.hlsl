struct WaterLightLoopData
{
    float3 StartPos;
    float3 EndPos;
    float3 NormalizedRayDirection;
    float NormalizedRayLength;
    float NormalizedAmbientDepth;
    float NormalizedSunDepth;
    float RayLength;
    float3 RayDirection;
    float Dither;
    float3 WaterAbsorption;
    float3 ScatterCoefficient;
};
#include "WaterVolumetrics.hlsl"
#include "WaterFunctionLibary.hlsl"

void WaterPostEvaluateBSDF(WaterLightLoopData waterLightLoopData,LightLoopContext lightLoopContext,
    float3 V, PositionInputs posInput,
    PreLightData preLightData, BSDFData bsdfData, BuiltinData builtinData, AggregateLighting lighting,
    out LightLoopOutput lightLoopOutput)
{
    AmbientOcclusionFactor aoFactor;
    // Use GTAOMultiBounce approximation for ambient occlusion (allow to get a tint from the baseColor)
#if 0
    GetScreenSpaceAmbientOcclusion(posInput.positionSS, preLightData.NdotV, bsdfData.perceptualRoughness, bsdfData.ambientOcclusion, bsdfData.specularOcclusion, aoFactor);
#else
    GetScreenSpaceAmbientOcclusionMultibounce(posInput.positionSS, preLightData.NdotV, bsdfData.perceptualRoughness, bsdfData.ambientOcclusion, bsdfData.specularOcclusion, bsdfData.diffuseColor, bsdfData.fresnel0, aoFactor);
#endif

    ApplyAmbientOcclusionFactor(aoFactor, builtinData, lighting);

    // Subsurface scattering mode
    float3 modifiedDiffuseColor = GetModifiedDiffuseColorForSSS(bsdfData);

    // Apply the albedo to the direct diffuse lighting (only once). The indirect (baked)
    // diffuse lighting has already multiply the albedo in ModifyBakedDiffuseLighting().
    // Note: In deferred bakeDiffuseLighting also contain emissive and in this case emissiveColor is 0
    float3 TotalIndirectLighting = 0;
    float3 absorbance = 1;

    for (int count = 0; count < WATER_SAMPLE_COUNT; count++)
    {
        float d = (pow(expFactor, float(count+waterLightLoopData.Dither*0.1)/float(WATER_SAMPLE_COUNT))/expFactor - 1.0/expFactor)/(1-1.0/expFactor);
        float dd = pow(expFactor, float(count+waterLightLoopData.Dither*0.1)/float(WATER_SAMPLE_COUNT)) * log(expFactor) / float(WATER_SAMPLE_COUNT)/(expFactor-1.0);
        
        float3 ambientAbsorbance = exp(-waterLightLoopData.WaterAbsorption * (waterLightLoopData.NormalizedAmbientDepth * d));
        float3 indirectLighting = builtinData.bakeDiffuseLighting * ambientAbsorbance * _AmbientLC.rgb * 0.8;//贡献一半的间接光照
        float3 volumeCoeff = exp(-waterLightLoopData.WaterAbsorption * dd * waterLightLoopData.NormalizedRayLength);        
        TotalIndirectLighting += (indirectLighting - indirectLighting * volumeCoeff)/waterLightLoopData.WaterAbsorption * absorbance;
        absorbance *= volumeCoeff;
    }

    TotalIndirectLighting = TotalIndirectLighting * (1 - absorbance);

    lightLoopOutput.diffuseLighting = modifiedDiffuseColor * lighting.direct.diffuse + TotalIndirectLighting + builtinData.emissiveColor;
    //lightLoopOutput.diffuseLighting = modifiedDiffuseColor * lighting.direct.diffuse + builtinData.emissiveColor;

    // If refraction is enable we use the transmittanceMask to lerp between current diffuse lighting and refraction value
    // Physically speaking, transmittanceMask should be 1, but for artistic reasons, we let the value vary
    //
    // Note we also transfer the refracted light (lighting.indirect.specularTransmitted) into diffuseLighting
    // since we know it won't be further processed: it is called at the end of the LightLoop(), but doing this
    // enables opacity to affect it (in ApplyBlendMode()) while the rest of specularLighting escapes it.
#if HAS_REFRACTION
    lightLoopOutput.diffuseLighting = lerp(lightLoopOutput.diffuseLighting, lighting.indirect.specularTransmitted, bsdfData.transmittanceMask * _EnableSSRefraction);
#endif

    lightLoopOutput.specularLighting = lighting.direct.specular + lighting.indirect.specularReflected;
    // Rescale the GGX to account for the multiple scattering.
    lightLoopOutput.specularLighting *= 1.0 + bsdfData.fresnel0 * preLightData.energyCompensation;

#ifdef DEBUG_DISPLAY
    PostEvaluateBSDFDebugDisplay(aoFactor, builtinData, lighting, bsdfData.diffuseColor, lightLoopOutput);
#endif
}

CBSDF WaterEvaluateBSDF(WaterLightLoopData waterLightLoopData,uint featureFlags,float3 V, float3 L,float3 LightColor, PreLightData preLightData, BSDFData bsdfData,
    PositionInputs posInput,LightLoopContext lightLoopContext,DirectionalLightData light,BuiltinData builtinData)
{
    CBSDF cbsdf;
    ZERO_INITIALIZE(CBSDF, cbsdf);

    float3 N = bsdfData.normalWS;

    float NdotV = preLightData.NdotV;
    float NdotL = dot(N, L);
    float clampedNdotV = ClampNdotV(NdotV);
    float clampedNdotL = saturate(NdotL);
    float flippedNdotL = ComputeWrappedDiffuseLighting(-NdotL, TRANSMISSION_WRAP_LIGHT);

    float LdotV, NdotH, LdotH, invLenLV;
    GetBSDFAngle(V, L, NdotL, NdotV, LdotV, NdotH, LdotH, invLenLV);

    float3 F = F_Schlick(bsdfData.fresnel0, LdotH);
    // Remark: Fresnel must be use with LdotH angle. But Fresnel for iridescence is expensive to compute at each light.
    // Instead we use the incorrect angle NdotV as an approximation for LdotH for Fresnel evaluation.
    // The Fresnel with iridescence and NDotV angle is precomputed ahead and here we jsut reuse the result.
    // Thus why we shouldn't apply a second time Fresnel on the value if iridescence is enabled.
    if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_IRIDESCENCE))
    {
        F = lerp(F, bsdfData.fresnel0, bsdfData.iridescenceMask);
    }

    float DV;
    if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_ANISOTROPY))
    {
        float3 H = (L + V) * invLenLV;

        // For anisotropy we must not saturate these values
        float TdotH = dot(bsdfData.tangentWS, H);
        float TdotL = dot(bsdfData.tangentWS, L);
        float BdotH = dot(bsdfData.bitangentWS, H);
        float BdotL = dot(bsdfData.bitangentWS, L);

        // TODO: Do comparison between this correct version and the one from isotropic and see if there is any visual difference
        // We use abs(NdotL) to handle the none case of double sided
        DV = DV_SmithJointGGXAniso(TdotH, BdotH, NdotH, clampedNdotV, TdotL, BdotL, abs(NdotL),
                                   bsdfData.roughnessT, bsdfData.roughnessB, preLightData.partLambdaV);
    }
    else
    {
        // We use abs(NdotL) to handle the none case of double sided
        DV = DV_SmithJointGGX(NdotH, abs(NdotL), clampedNdotV, bsdfData.roughnessT, preLightData.partLambdaV);
    }

    float3 specTerm = F * DV;

#if defined(_SURFACE_TYPE_TRANSPARENT) && defined(SHADERPASS) && (SHADERPASS != SHADERPASS_LIGHT_TRANSPORT) && (SHADERPASS != SHADERPASS_PATH_TRACING) && (SHADERPASS != SHADERPASS_RAYTRACING_VISIBILITY) && (SHADERPASS != SHADERPASS_RAYTRACING_FORWARD)
    float3 sceneColor = SampleCameraColor(posInput.positionNDC.xy, 0).xyz;
#else
    float3 sceneColor = 0;
#endif
    float3 absorbance = 1;
    float4 waterScatterColor =  WaterVolumetrics(
                                waterLightLoopData,
                                featureFlags,
                                _MaxDistance,
                                _PhaseG,
                                _AmbientLC.rgb/GetCurrentExposureMultiplier(), 
                                posInput.positionNDC.xy,                                
                                L,LightColor,                                
                                posInput,lightLoopContext,light,builtinData,bsdfData,//添加额外的采样阴影数据
                                absorbance);
        

    cbsdf.diffR = sceneColor * absorbance * 0.1;
    cbsdf.diffT = waterScatterColor.rgb;
    //由diffR来定义吸收，diffT来定义散射

    // Probably worth branching here for perf reasons.
    // This branch will be optimized away if there's no transmission.
    if (NdotL > 0)
    {
        cbsdf.specR = specTerm * clampedNdotL;
    }

    // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
    return cbsdf;
}


DirectLighting WaterSurface_Infinitesimal(WaterLightLoopData waterLightLoopData,uint featureFlags,PreLightData preLightData, BSDFData bsdfData,
    float3 V, float3 L, float3 lightColor,float diffuseDimmer,
    float specularDimmer,PositionInputs posInput,
    LightLoopContext lightLoopContext,DirectionalLightData light,BuiltinData builtinData)//添加额外的采样阴影数据
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    //if (Max3(lightColor.r, lightColor.g, lightColor.b) > 0)
    {
        CBSDF cbsdf = WaterEvaluateBSDF(waterLightLoopData,featureFlags,V, L, lightColor, preLightData, bsdfData,posInput,lightLoopContext,light,builtinData);

    #if defined(MATERIAL_INCLUDE_TRANSMISSION) || defined(MATERIAL_INCLUDE_PRECOMPUTED_TRANSMISSION)
        float3 transmittance = bsdfData.transmittance;
    #else
        float3 transmittance = float3(0.0, 0.0, 0.0);
    #endif
        transmittance = float3(1.0, 1.0, 1.0);
        // If transmittance or the CBSDF's transmission components are known to be 0,
        // the optimization pass of the compiler will remove all of the associated code.
        // However, this will take a lot more CPU time than doing the same thing using
        // the preprocessor.
        //由于散射部分需要光照颜色来计算，不能在这里再次乘光照颜色，而吸收则可以放到这里来乘
        lighting.diffuse  = (cbsdf.diffR/GetCurrentExposureMultiplier()*10 + cbsdf.diffT * transmittance) * diffuseDimmer;
        lighting.specular = (cbsdf.specR + cbsdf.specT * transmittance) * lightColor * specularDimmer;
    }

#ifdef DEBUG_DISPLAY
    if (_DebugLightingMode == DEBUGLIGHTINGMODE_LUX_METER)
    {
        // Only lighting, no BSDF.
        lighting.diffuse = lightColor * saturate(dot(bsdfData.normalWS, L));
    }
#endif

    return lighting;
}


DirectLighting WaterSurface_Directional(WaterLightLoopData waterLightLoopData,uint featureFlags,LightLoopContext lightLoopContext,
                                        PositionInputs posInput, BuiltinData builtinData,
                                        PreLightData preLightData, DirectionalLightData light,
                                        BSDFData bsdfData, float3 V)
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    float3 L = -light.forward;

    // Is it worth evaluating the light?
    if ((light.lightDimmer > 0))
    {
        float4 lightColor = EvaluateLight_Directional(lightLoopContext, posInput, light);
        lightColor.rgb *= lightColor.a; // Composite

#ifdef MATERIAL_INCLUDE_TRANSMISSION
        if (ShouldEvaluateThickObjectTransmission(V, L, preLightData, bsdfData, 0))
        {
            // Transmission through thick objects does not support shadowing
            // from directional lights. It will use the 'baked' transmittance value.
            lightColor *= _DirectionalTransmissionMultiplier;
        }
        else
#endif
        {
            SHADOW_TYPE shadow = EvaluateShadow_Directional(lightLoopContext, posInput, light, builtinData, GetNormalForShadowBias(bsdfData));
            float NdotL  = dot(bsdfData.normalWS, L); // No microshadowing when facing away from light (use for thin transmission as well)
            shadow *= NdotL >= 0.0 ? ComputeMicroShadowing(GetAmbientOcclusionForMicroShadowing(bsdfData), NdotL, _MicroShadowOpacity) : 1.0;            
            lightColor.rgb *= ComputeShadowColor(shadow, light.shadowTint, light.penumbraTint);

#ifdef LIGHT_EVALUATION_SPLINE_SHADOW_VISIBILITY_SAMPLE
            if ((light.shadowIndex >= 0))
            {
                bsdfData.splineVisibility = lightLoopContext.splineVisibility;
            }
            else
            {
                bsdfData.splineVisibility = -1;
            }
#endif
        }

        // Simulate a sphere/disk light with this hack.
        // Note that it is not correct with our precomputation of PartLambdaV
        // (means if we disable the optimization it will not have the
        // same result) but we don't care as it is a hack anyway.
        ClampRoughness(preLightData, bsdfData, light.minRoughness);

        lighting = WaterSurface_Infinitesimal(waterLightLoopData,featureFlags,preLightData, bsdfData, V, L, lightColor.rgb,
                                              light.diffuseDimmer, light.specularDimmer,posInput,
                                              lightLoopContext,light,builtinData);
    }

    return lighting;
}


DirectLighting WaterEvaluateBSDF_Directional(WaterLightLoopData waterLightLoopData,uint featureFlags,LightLoopContext lightLoopContext,
    float3 V, PositionInputs posInput,
    PreLightData preLightData, DirectionalLightData lightData,
    BSDFData bsdfData, BuiltinData builtinData)
{
    return WaterSurface_Directional(waterLightLoopData,featureFlags,lightLoopContext, posInput, builtinData, preLightData, lightData, bsdfData, V);
}