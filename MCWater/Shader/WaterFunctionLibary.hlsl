
#ifndef WATER_VOLUMETRICS_READY_INCLUDED
#define WATER_VOLUMETRICS_READY_INCLUDED

StructuredBuffer<int2> _DepthPyramidMipLevelOffsets;

// 安全的标准化函数，避免零向量导致的NaN
float3 safeNormalize(float3 v)
{
    float len = length(v);
    return len > 0.0001 ? v / len : float3(0, 1, 0);
}

float4 GetTaaFrameInfo()
{
	#if SHADER_TARGET < 45
		return float4(0,0,0,0);
	#else
		return _TaaFrameInfo;//x:Jitter,y:FrameIndex,z:FrameCount,w:FrameDeltaTime
	#endif
}

float GetDitherPixel(float2 positionCS,float baseAlpha)
{
    float frameCount = GetTaaFrameInfo().z;
    float2 coord = positionCS + float2(frameCount,frameCount);
    float2 alpha = float2(0.75487765, 0.56984026);
    float dither = fmod( (alpha.x * coord.x + alpha.y * coord.y) ,5);
    return dither/6 + baseAlpha - 0.5;
}

float R2_dither(float2 positionCS)
{
	float frameCount = GetTaaFrameInfo().z;
    float2 coord = positionCS;

	coord += (frameCount*2)%40000;
	
	float2 alpha = float2(0.75487765, 0.56984026);
	return frac(alpha.x * coord.x + alpha.y * coord.y);
}

float3 ScreenToWorldPosition(float2 screenUV)
{

#if defined(SHADERPASS) && (SHADERPASS != SHADERPASS_LIGHT_TRANSPORT)
    int2 coord = int2(screenUV * _ScreenSize.xy);
    int2 mipCoord  = coord.xy >> int(0);
    int2 mipOffset = _DepthPyramidMipLevelOffsets[int(0)];
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
    return Result.xyz + _WorldSpaceCameraPos.xyz;
}

// Blue noise sampling (simplified for Unity)
float BlueNoise(float2 screenPos, float frameCount)
{
    return frac(sin(dot(screenPos + frameCount, float2(12.9898, 78.233))) * 43758.5453);
}

//==============================================================================
// 3D Noise Functions
//==============================================================================

// Hash function for noise generation
float3 hash3(float3 p)
{
    p = float3(dot(p, float3(127.1, 311.7, 74.7)),
               dot(p, float3(269.5, 183.3, 246.1)),
               dot(p, float3(113.5, 271.9, 124.6)));
    
    return -1.0 + 2.0 * frac(sin(p) * 43758.5453123);
}

// Single hash function
float hash(float3 p)
{
    p = frac(p * 0.3183099 + 0.1);
    p *= 17.0;
    return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// Gradient noise (Perlin-like)
float gradientNoise(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    
    // Smooth interpolation
    float3 u = f * f * (3.0 - 2.0 * f);
    
    // Sample gradients at 8 corners of the cube
    return lerp(lerp(lerp(dot(hash3(i + float3(0, 0, 0)), f - float3(0, 0, 0)),
                         dot(hash3(i + float3(1, 0, 0)), f - float3(1, 0, 0)), u.x),
                    lerp(dot(hash3(i + float3(0, 1, 0)), f - float3(0, 1, 0)),
                         dot(hash3(i + float3(1, 1, 0)), f - float3(1, 1, 0)), u.x), u.y),
               lerp(lerp(dot(hash3(i + float3(0, 0, 1)), f - float3(0, 0, 1)),
                         dot(hash3(i + float3(1, 0, 1)), f - float3(1, 0, 1)), u.x),
                    lerp(dot(hash3(i + float3(0, 1, 1)), f - float3(0, 1, 1)),
                         dot(hash3(i + float3(1, 1, 1)), f - float3(1, 1, 1)), u.x), u.y), u.z);
}

// Value noise (simpler, faster)
float valueNoise(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    
    // Smooth interpolation
    float3 u = f * f * (3.0 - 2.0 * f);
    
    // Sample values at 8 corners of the cube
    return lerp(lerp(lerp(hash(i + float3(0, 0, 0)),
                         hash(i + float3(1, 0, 0)), u.x),
                    lerp(hash(i + float3(0, 1, 0)),
                         hash(i + float3(1, 1, 0)), u.x), u.y),
               lerp(lerp(hash(i + float3(0, 0, 1)),
                         hash(i + float3(1, 0, 1)), u.x),
                    lerp(hash(i + float3(0, 1, 1)),
                         hash(i + float3(1, 1, 1)), u.x), u.y), u.z);
}

// Fractal Brownian Motion (fBm) for more complex noise
float fBmNoise(float3 p, int octaves, float lacunarity, float gain)
{
    float amplitude = 0.5;
    float frequency = 1.0;
    float value = 0.0;
    float maxValue = 0.0;
    
    for (int i = 0; i < octaves; i++)
    {
        value += gradientNoise(p * frequency) * amplitude;
        maxValue += amplitude;
        amplitude *= gain;
        frequency *= lacunarity;
    }
    
    return value / maxValue;
}

// Main 3D Noise function with customizable intensity and scale
// @param position: 3D world position
// @param scale: Controls the frequency/size of noise features (smaller = larger features)
// @param intensity: Controls the strength/amplitude of the noise
// @param octaves: Number of noise layers (more = more detail, but slower)
// @param lacunarity: Frequency multiplier between octaves (typically 2.0)
// @param gain: Amplitude multiplier between octaves (typically 0.5)
// @param useGradient: true for gradient noise (smoother), false for value noise (faster)
float Noise3D(float3 position, float scale, float intensity, int octaves = 4, float lacunarity = 2.0, float gain = 0.5, bool useGradient = true)
{
    float3 scaledPos = position * scale;
    float noise;
    
    if (octaves > 1)
    {
        // Use fractal Brownian motion for complex noise
        noise = fBmNoise(scaledPos, octaves, lacunarity, gain);
    }
    else
    {
        // Use single octave noise
        if (useGradient)
        {
            noise = gradientNoise(scaledPos);
        }
        else
        {
            noise = valueNoise(scaledPos);
        }
    }
    
    return noise * intensity;
}

// Simplified 3D Noise function (most commonly used)
float Noise3DSimple(float3 position, float scale, float intensity)
{
    return Noise3D(position, scale, intensity, 4, 2.0, 0.5, true);
}

// Turbulence function (absolute value of noise for more chaotic patterns)
float Turbulence3D(float3 position, float scale, float intensity, int octaves = 4)
{
    float3 scaledPos = position * scale;
    float amplitude = intensity;
    float frequency = 1.0;
    float turbulence = 0.0;
    
    for (int i = 0; i < octaves; i++)
    {
        turbulence += abs(gradientNoise(scaledPos * frequency)) * amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    
    return turbulence;
}

#endif // WATER_VOLUMETRICS_INCLUDED 