
#ifndef WATER_VOLUMETRICS_GRAPH_INCLUDED
#define WATER_VOLUMETRICS_GRAPH_INCLUDED

#define PHSYCL_SCATTER
#define PI 3.14159265358979323846

#define WATER_SAMPLE_COUNT 2 
#define expFactor 4


float3 safeNormalize(float3 v)
{
    float len = length(v);
    return len > 0.0001 ? v / len : float3(0, 1, 0);
}
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

void ScreenToWorldPosition_float(float2 screenUV,out float3 WorldPos)
{

#if defined(SHADERPASS) && (SHADERPASS != SHADERPASS_LIGHT_TRANSPORT)
    int2 coord = int2(screenUV * _ScreenSize.xy);
    int2 mipCoord  = coord.xy >> int(0);
    int2 mipOffset = 0;
    float rawDepth =  LOAD_TEXTURE2D_X(_CameraDepthTexture, mipOffset + mipCoord).r;
#endif
    
    // 线性化深度值
    float linearDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
    
    // 从屏幕位置重建视图空间坐标
    float2 ndcXY = screenUV * 2.0 - 1.0;
    
    #if UNITY_UV_STARTS_AT_TOP
        ndcXY.y = -ndcXY.y;
    #endif
    
    // 重建视图空间位置
    float4 viewPos = mul(UNITY_MATRIX_I_P, float4(ndcXY, rawDepth, 1.0));
    viewPos.xyz /= viewPos.w;
    
    // 转换到世界空间
    float4 Result = mul(UNITY_MATRIX_I_V, float4(viewPos.xyz, 1.0));
    WorldPos = Result.xyz + _WorldSpaceCameraPos.xyz;
}


//==============================================================================
void WaterVolume_ShaderGraph_float(
    // Input parameters
    float MaxDistance,
    float PhaseG,
    float3 StartPos,
    float3 EndPos,
    float3 WaterAbsorption,
    float3 ScatterCoefficient,
    float2 ScreenUV,    
    float3 LightDir,
    float3 LightColor,
    float3 NormalWS,
    
    
    // Output
    out float3 absorbance,
    out float3 scatteredLight
)
{    
    // Initialize variables
    absorbance = float3(1.0, 1.0, 1.0);
    scatteredLight = float3(0.0, 0.0, 0.0);
    float3 RayStart = StartPos;
    float3 RayEnd = EndPos;
    float RayLength = length(EndPos - StartPos);
    float3 RayDirection = EndPos - StartPos;
    float ScaleFactor = min(RayLength, MaxDistance) / (RayLength + 1e-8);    
    float NormalizedRayLength = RayLength * ScaleFactor;
    float3 NormalizedRayDirection = RayDirection * ScaleFactor;
    float AmbientDepth = abs(safeNormalize(NormalizedRayDirection + _WorldSpaceCameraPos.xyz).y) * NormalizedRayLength;
    float SunDepth = AmbientDepth / abs(safeNormalize(LightDir).y);

    float Dither = 0;
    float3 phaseScatter;
    float phase;

    float cosTheta = dot(safeNormalize(RayEnd - _WorldSpaceCameraPos.xyz), safeNormalize(LightDir));

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

        // Direct and indirect lighting
        float3 directLighting = LightColor * phaseScatter;
        //阴影并不会完全屏蔽掉直射光对散射的贡献，依然能从阴影的周围散射部分光量，所以加入部分来自直射光的间接光
        float3 indirectLighting = 0;
        //*ambientAbsorbance
        
        //总合成
        // 随着深度延申，米尔散射颜色的变化趋近于白色，所以需要饱和度衰减
        float scatterSaturationFactor = max(1 - saturate(RayLength/(_MaxDistance * 5)),0.75);        
        float3 totalLight = (directLighting + indirectLighting) * ScatterCoefficient;
        
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
    float cosThet = saturate(dot(NormalWS, viewDirection));
    scatteredLight *= (1 - FresnelSchlick(cosThet, float3(0.02,0.02,0.02)));
    // Return final result    
    float averageAbsorbance = dot(absorbance,float3(0.33, 0.33, 0.33));
    scatteredLight = scatteredLight * (1-averageAbsorbance);
}


float sampleH(UnityTexture2D tex2d, float2 uv)
{
    return SAMPLE_TEXTURE2D_LOD(tex2d.tex,tex2d.samplerstate, uv, 0).r;
}

void HeightToNormalCore(
    UnityTexture2D HeightTex,
    float2 UV, float2 TexelSize,
    float HeightScale, float Strength,
    float UseSobel, float FlipY,
    out float dhdu, out float dhdv)
{
    float2 ts = max(HeightScale, 1e-6.xx);

    float h00 = sampleH(HeightTex, UV);
    float h10 = sampleH(HeightTex, UV + float2(-ts.x,  0));
    float h12 = sampleH(HeightTex, UV + float2( ts.x,  0));
    float h01 = sampleH(HeightTex, UV + float2( 0,    -ts.y));
    float h21 = sampleH(HeightTex, UV + float2( 0,     ts.y));

    if (UseSobel > 0.5)
    {
        float h00 = sampleH(HeightTex, UV + float2(-ts.x, -ts.y));
        float h02 = sampleH(HeightTex, UV + float2( ts.x, -ts.y));
        float h20 = sampleH(HeightTex, UV + float2(-ts.x,  ts.y));
        float h22 = sampleH(HeightTex, UV + float2( ts.x,  ts.y));

        float sobelU = (h02 + 2*h12 + h22) - (h00 + 2*h10 + h20); // ∂h/∂u * (ts.x*8) 近似
        float sobelV = (h20 + 2*h21 + h22) - (h00 + 2*h01 + h02); // ∂h/∂v * (ts.y*8) 近似

        dhdu = (sobelU / 8.0) / ts.x;
        dhdv = (sobelV / 8.0) / ts.y;
    }
    else
    {
        dhdu = (h12 - h00) * 0.5 / ts.x;
        dhdv = (h21 - h00) * 0.5 / ts.y;
    }

    // 方向修正（若高度图 V 方向与期望相反）
    if (FlipY > 0.5) dhdv = -dhdv;

    // 把高度梯度换算到“斜率”：位移/UV → 位移/实际长度
    // HeightScale：高度值（0..1）对应的世界位移（米），Strength 为额外增益
    dhdu *= Strength;
    dhdv *= Strength;
}

void HeightToNormalHDRP_float(
    UnityTexture2D HeightTex,
    float2 UV, float2 TexelSize,
    float HeightScale, float Strength,
    float3 TangentWS, float3 BitangentWS, float3 NormalWS,
    float UseSobel, float FlipY, float OutputSpace,
    out float3 NormalOut)
{
    float dhdu, dhdv;
    HeightToNormalCore(HeightTex, UV, TexelSize, HeightScale, Strength, UseSobel, FlipY, dhdu, dhdv);

    // 切线空间法线：(-∂h/∂u, -∂h/∂v, 1)
    float3 tangent_u = float3(1,0,dhdu);
    float3 tangent_v = float3(0,1,dhdv);
    float3 N_ts = (cross(tangent_u, tangent_v));

    // 构建 TBN（单位化以避免缩放畸变）
    float3 T = normalize(TangentWS);
    float3 B = normalize(BitangentWS);
    float3 N = normalize(NormalWS);

    // 切线→世界：避免矩阵转置歧义，直接线性组合
    float3 N_ws = normalize(N_ts.x * T + N_ts.y * B + N_ts.z * N);

    NormalOut = (OutputSpace > 0.5) ? N_ws : N_ts;
}
#endif