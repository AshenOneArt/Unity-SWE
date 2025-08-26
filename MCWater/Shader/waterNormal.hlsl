#ifndef WATER_NORMAL_INCLUDED
#define WATER_NORMAL_INCLUDED

#define WATER_WAVE_SPEED 1.5
#define WATER_WAVE_STRENGTH 0.5
SamplerState my_Linear_Repeat_sampler;

float getWaterHeightmap(float2 posxz, float largeWavesCurved,UnityTexture2D noiseTex,float time,float size) 
{
	float2 pos = posxz;
	float movement = time * 0.035 * WATER_WAVE_SPEED;
    largeWavesCurved = max(largeWavesCurved,0);

	float radiance = 2.39996;
	float2x2 rotationMatrix  = float2x2(float2(cos(radiance),  -sin(radiance)),  float2(sin(radiance),  cos(radiance)));

	float2 wave_size[3];
    wave_size[0] = float2(48.0,12.0);
    wave_size[1] = float2(12.0,48.0);
    wave_size[2] = float2(32.0,32.0);

	float heightSum = 0.0;
	for (int i = 0; i < 3; i++)
    {
		pos = mul(rotationMatrix, pos);
		heightSum += SAMPLE_TEXTURE2D(noiseTex.tex, my_Linear_Repeat_sampler, 
            pos / wave_size[i] + movement + largeWavesCurved * 0.5).b;
	}
	return (heightSum/4.5) * lerp(0.1, 1, largeWavesCurved);
}

float3 getWaveNormal(float3 absWorldPos, float3 playerpos,UnityTexture2D noiseTex,float size,float time
    ,float largeWaveScale,float nomralDistance,float normalDistanceSoftness)
{

    normalDistanceSoftness = max(normalDistanceSoftness,0.01);
    nomralDistance = max(nomralDistance,1);

	float largeWaves = SAMPLE_TEXTURE2D(noiseTex.tex, my_Linear_Repeat_sampler, absWorldPos.xy / largeWaveScale).b;
 	float largeWavesCurved = pow(1.0-pow(1.0-largeWaves,2.0),0.25);

	#ifdef HYPER_DETAILED_WAVES
		float deltaPos = 0.025;
 	#else
 		float deltaPos = lerp(1.0, 0.3, largeWavesCurved);
 		// reduce high frequency detail as distance increases. reduces noise on waves. why have more details than pixels?
 		float range = min(pow(length(playerpos) / (16.0 * nomralDistance),normalDistanceSoftness), 10.0);
 		deltaPos += range;
	#endif

	float2 coord = absWorldPos.xy;

    largeWavesCurved = pow(1.0-pow(1.0-largeWaves,2.0),2.5);
	float h0 = getWaterHeightmap(coord                       ,largeWavesCurved,noiseTex,time,size);
 	float h1 = getWaterHeightmap(coord + float2(deltaPos+0,0.0),largeWavesCurved,noiseTex,time,size);
 	float h3 = getWaterHeightmap(coord + float2(0.0,deltaPos+0.0),largeWavesCurved,noiseTex,time,size);

	float xDelta = (h1-h0)/deltaPos;
	float yDelta = (h3-h0)/deltaPos;

    float3 tangent_u = float3(1,0,xDelta);
    float3 tangent_v = float3(0,1,yDelta);

	float3 wave = normalize(float3(xDelta, yDelta, 1.0-pow(abs(xDelta+yDelta),2.0)));

	return wave;
}


void WaterNormal_float(
    float time,
    UnityTexture2D noiseTex,
    float largeWaveScale,
    float3 viewVector,
    float3 absPositionWS,
    float3 positionWS,
    float3 normalWS,
    float size,
    float nomralDistance,
    float normalDistanceSoftness,
    out float3 normal
    )
{
    float3 waterPos = absPositionWS * size;
    float3 flowDir = normalize(normalWS*10.0) * time * WATER_WAVE_SPEED * (2.0);

    float2 newPos = waterPos.xy + abs(flowDir.xz);
    newPos = lerp(newPos, waterPos.zy + abs(flowDir.zx), clamp(abs(normalWS.x),0.0,1.0));
    newPos = lerp(newPos, waterPos.xz, clamp(abs(normalWS.y),0.0,1.0));
    waterPos.xy = newPos;
    
    float3 bump = getWaveNormal(waterPos, positionWS,noiseTex,size,time,largeWaveScale,nomralDistance,normalDistanceSoftness);
    float bumpmult = 0.5 * (WATER_WAVE_STRENGTH);
    bump.xy = bump.xy * bumpmult;

    normal = bump;
}



#endif