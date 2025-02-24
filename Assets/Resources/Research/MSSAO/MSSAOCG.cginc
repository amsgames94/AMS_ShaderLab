#ifndef MSSAO_CG_INCLUDED
#define MSSAO_CG_INCLUDED
	
	uniform sampler2D _MainTex;
	uniform float4 _MainTex_TexelSize;

	sampler2D _CameraDepthTexture;
	sampler2D _CameraDepthNormalsTexture;

	uniform float _maxDist;
	uniform float _maxKernelSize;
	uniform float _r;
	uniform float _Radius;

	uniform sampler2D _AOFar;
	uniform float4 _AOFar_TexelSize;

	sampler2D _normTex;
	sampler2D _posTex;
	sampler2D _lowResNormTex;
	sampler2D _lowResPosTex;

	uniform float _PoissonDisks[32];

	// Boundary check for depth sampler
	// (returns a very large value if it lies out of bounds)
	float CheckBounds(float2 uv, float d)
	{
		float ob = any(uv < 0) + any(uv > 1);
	#if defined(UNITY_REVERSED_Z)
		ob += (d <= 0.00001);
	#else
		ob += (d >= 0.99999);
	#endif
		return ob * 1e8;
	}

	void SampleDepthNormal(float2 uv, out float3 normal, out float depth)
	{
		float d = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);
		depth = LinearEyeDepth(d) + CheckBounds(uv, d);

		float4 cdn = tex2D(_CameraDepthNormalsTexture, uv);
		normal = DecodeViewNormalStereo(cdn) * float3(1, 1, -1);
	}

	void SampleDepth(float2 uv, out float depth)
	{
		float d = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);
		depth = LinearEyeDepth(d) + CheckBounds(uv, d);
	}

	// Reconstruct view-space position from UV and depth.
	// p11_22 = (unity_CameraProjection._11, unity_CameraProjection._22)
	// p13_31 = (unity_CameraProjection._13, unity_CameraProjection._23)
	float3 ReconstructViewPos(float2 uv, float depth, float2 p11_22, float2 p13_31)
	{
		return float3((uv * 2 - 1 - p13_31) / p11_22, 1) * depth;
	}

	float3 SamplePosition(sampler2D posTex, float2 sampleUV) {
		// Parameters used in coordinate conversion
		float3x3 proj = (float3x3)unity_CameraProjection;
		float2 p11_22 = float2(unity_CameraProjection._11, unity_CameraProjection._22);
		float2 p13_23 = float2(unity_CameraProjection._13, unity_CameraProjection._23);

		return tex2D(posTex, sampleUV) - ReconstructViewPos(float2(0, 0), _ScreenParams.z, p11_22, p13_23);
	}

	// Computes the occlusion value based on the distance to the center sample and the dot product
	// of the center sample's normal and the vector going from the center to the sample (in world space).
	float ComputeOcclusion(float2 sampleUV, float3 centerPos, float3 centerNorm) {
		float3 sampleNorm = tex2D(_normTex, sampleUV);
		sampleNorm = (sampleNorm - 0.5f);
		sampleNorm *= 2;
		float3 samplePos = SamplePosition(_posTex, sampleUV);

		float d = distance(centerPos, samplePos);
		float t = 1 - min(1, (d * d) / (_maxDist * _maxDist));

		float3 diff = normalize(samplePos - centerPos);
		float cosTheta = max(dot(centerNorm, diff), 0);

		return t * cosTheta;
	}

	// Upsamples the smaller resolution AO texture weighting the result based on the normal and depth values to
	// prevent downsampling artifacts.
	float3 Upsample(sampler2D downsampledTexture, float4 texelSize, float2 sampleUV, float3 centerNorm, float centerDepth)
	{
		float2 lowResSamples[4];

		lowResSamples[0] = sampleUV + float2(-1.0, 1.0) * texelSize.xy;
		lowResSamples[1] = sampleUV + float2(1.0, 1.0) * texelSize.xy;
		lowResSamples[2] = sampleUV + float2(-1.0, -1.0) * texelSize.xy;
		lowResSamples[3] = sampleUV + float2(1.0, -1.0) * texelSize.xy;

		float3 lowResAO[4];
		float3 lowResNorm[4];
		float lowResDepth[4];

		for (int i = 0; i < 4; ++i)
		{
			lowResNorm[i] = tex2D(_lowResNormTex, lowResSamples[i]).xyz;
			lowResNorm[i] = (lowResNorm[i] - 0.5f);
			lowResNorm[i] *= 2;
			lowResDepth[i] = SamplePosition(_lowResPosTex, lowResSamples[i]).z;
			lowResAO[i] = tex2D(downsampledTexture, lowResSamples[i]).xyz;
		}

		float normWeight[4];
		for (int i = 0; i < 4; ++i)
		{
			normWeight[i] = (dot(lowResNorm[i], centerNorm) + 1.1) / 2.1;
			normWeight[i] = pow(normWeight[i], 8.0);
		}

		float depthWeight[4];
		for (int i = 0; i < 4; ++i)
		{
			depthWeight[i] = 1.0 / (1.0 + abs(centerDepth - lowResDepth[i]) * 0.2);
			depthWeight[i] = pow(depthWeight[i], 16.0);
		}

		float totalWeight = 0.0;
		float3 combinedAO = float3(0, 0, 0);
		for (int i = 0; i < 4; ++i)
		{
			float weight = normWeight[i] * depthWeight[i] * (9.0 / 16.0) /
				(abs((sampleUV.x - lowResSamples[i].x * 2.0) * (sampleUV.y - lowResSamples[i].y * 2.0)) * 4.0);
			totalWeight += weight;
			combinedAO += lowResAO[i] * weight;
		}
		combinedAO /= totalWeight;
		return combinedAO;
	}

	float4 fragNorm(v2f_img i) : COLOR
	{
		float2 sample0UV = i.uv;
		float2 sample1UV = i.uv + float2(1, 0) * _MainTex_TexelSize.xy;
		float2 sample2UV = i.uv + float2(0, 1) * _MainTex_TexelSize.xy;
		float2 sample3UV = i.uv + float2(1, 1) * _MainTex_TexelSize.xy;

		float3 normal[4];
		float depth[4];

		SampleDepthNormal(sample0UV, normal[0], depth[0]);
		SampleDepthNormal(sample1UV, normal[1], depth[1]);
		SampleDepthNormal(sample2UV, normal[2], depth[2]);
		SampleDepthNormal(sample3UV, normal[3], depth[3]);

		int depth0Index = 0;
		int depth1Index = 0;
		int depth2Index = 0;
		int depth3Index = 0;
		for (uint i = 1; i < 4; i++)
		{
			if (min(depth[depth0Index], depth[i]) == depth[i]) depth0Index = i;
			if (max(depth[depth3Index], depth[i]) == depth[i]) depth3Index = i;
		}

		int candidate = -1;
		for (int i = 0; i < 4; i++)
		{
			if (depth[i] != depth[depth0Index] && depth[i] != depth[depth3Index]) {
				if (candidate == -1) candidate = i;
				else {
					if (min(depth[candidate], depth[i]) == depth[i]) { depth1Index = i; depth2Index = candidate; }
					else { depth1Index = candidate; depth2Index = i; }
				}
			}
		}

		float3 finalNormal;

		//1 = dThreshold
		if (depth[depth3Index] - depth[depth0Index] <= 1) {
			finalNormal = (normal[depth1Index] + normal[depth2Index]) / 2;
		}
		else {
			finalNormal = normal[depth1Index];
		}

		return float4(finalNormal * 0.5f + 0.5f, 1);
	}

	float4 fragPos(v2f_img i) : COLOR
	{
		float2 sample0UV = i.uv;
		float2 sample1UV = i.uv + float2(1, 0) * _MainTex_TexelSize.xy;
		float2 sample2UV = i.uv + float2(0, 1) * _MainTex_TexelSize.xy;
		float2 sample3UV = i.uv + float2(1, 1) * _MainTex_TexelSize.xy;

		float depth[4];

		SampleDepth(sample0UV, depth[0]);
		SampleDepth(sample1UV, depth[1]);
		SampleDepth(sample2UV, depth[2]);
		SampleDepth(sample3UV, depth[3]);

		// Parameters used in coordinate conversion
		float3x3 proj = (float3x3)unity_CameraProjection;
		float2 p11_22 = float2(unity_CameraProjection._11, unity_CameraProjection._22);
		float2 p13_31 = float2(unity_CameraProjection._13, unity_CameraProjection._23);

		float3 pos[4];

		// Reconstruct the view-space position.
		pos[0] = ReconstructViewPos(sample0UV, depth[0], p11_22, p13_31);
		pos[1] = ReconstructViewPos(sample1UV, depth[1], p11_22, p13_31);
		pos[2] = ReconstructViewPos(sample2UV, depth[2], p11_22, p13_31);
		pos[3] = ReconstructViewPos(sample3UV, depth[3], p11_22, p13_31);

		int depth0Index = 0;
		int depth1Index = 0;
		int depth2Index = 0;
		int depth3Index = 0;
		for (uint i = 1; i < 4; i++)
		{
			if (min(depth[depth0Index], depth[i]) == depth[i]) depth0Index = i;
			if (max(depth[depth3Index], depth[i]) == depth[i]) depth3Index = i;
		}

		int candidate = -1;
		for (int i = 0; i < 4; i++)
		{
			if (depth[i] != depth[depth0Index] && depth[i] != depth[depth3Index]) {
				if (candidate == -1) candidate = i;
				else {
					if (min(depth[candidate], depth[i]) == depth[i]) { depth1Index = i; depth2Index = candidate; }
					else { depth1Index = candidate; depth2Index = i; }
				}
			}
		}

		float3 finalPos;

		//1 = dThreshold
		if (depth[depth3Index] - depth[depth0Index] <= 1) {
			finalPos = (pos[depth1Index] + pos[depth2Index]) / 2;

		}
		else {
			finalPos = pos[depth1Index];
		}

		finalPos += ReconstructViewPos(float2(1,1), _ScreenParams.z, p11_22, p13_31);

		if (_ProjectionParams.z - (1.0 / 65025.0) * _ProjectionParams.z <= depth[0]) finalPos = float3(0,0,0);

		return float4(finalPos, 1);
	}

	float4 fragAOFirst(v2f_img i) : COLOR
	{
		// Pixel's viewspace normal and depth
		float3 centerNorm = tex2D(_normTex, i.uv);
		centerNorm = (centerNorm - 0.5f);
		centerNorm *= 2;
		float3 centerPos = SamplePosition(_posTex, i.uv);

		float AONear = 0;
		float AOSamples = 0.0001;

		float rangeMax = min(_r / abs(centerPos.z), _maxKernelSize);

		// Adjust to rangeMax
		[unroll(8)]
		for (float k = -rangeMax; k <= rangeMax; k += 2)
		{
			[unroll(8)]
			for (float q = -rangeMax; q <= rangeMax; q += 2)
			{
				AONear += ComputeOcclusion(i.uv + float2(floor(1.0001 * q), floor(1.0001 * k)) * _MainTex_TexelSize * _Radius, centerPos, centerNorm);
				AOSamples++;
			}
		}

		return float4(AONear / AOSamples, AONear, AOSamples, 1);
	}

	float4 fragAO(v2f_img i) : COLOR
	{
		// Pixel's viewspace normal and depth
		float3 centerNorm = tex2D(_normTex, i.uv);
		centerNorm = (centerNorm - 0.5f);
		centerNorm *= 2;
		float3 centerPos = SamplePosition(_posTex, i.uv);

		float AONear = 0;
		float AOSamples = 0.0001;

		float rangeMax = min(_r / abs(centerPos.z), _maxKernelSize);

		// Adjust to rangeMax
		[unroll(8)]
		for (float k = -rangeMax; k <= rangeMax; k += 2)
		{
			[unroll(8)]
			for (float q = -rangeMax; q <= rangeMax; q += 2)
			{
				AONear += ComputeOcclusion(i.uv + float2(floor(1.0001 * q), floor(1.0001 * k)) * _MainTex_TexelSize * _Radius, centerPos, centerNorm);
				AOSamples++;
			}
		}

		float3 upsample = Upsample(_AOFar, _AOFar_TexelSize, i.uv, centerNorm, centerPos.z);

		return float4(max(upsample.x, AONear / AOSamples), upsample.y + AONear, upsample.z + AOSamples, 1);
	}

	float4 fragAOLast(v2f_img i) : COLOR
	{
		// Pixel's viewspace normal and depth
		float3 centerNorm = tex2D(_normTex, i.uv);
		centerNorm = (centerNorm - 0.5f);
		centerNorm *= 2;
		float3 centerPos = SamplePosition(_posTex, i.uv);

		float AONear = 0;
		float AOSamples = 0;

		float rangeMax = min(_r / abs(centerPos.z), _maxKernelSize);

		// Adjust to rangeMax
		[unroll(16)]
		for (float x = 0; x < 32; x += 2)
		{
			float2 sampleUV = i.uv + float2(_PoissonDisks[x], _PoissonDisks[x + 1]) * _maxKernelSize * _MainTex_TexelSize.xy * _Radius;
			AONear += ComputeOcclusion(sampleUV, centerPos, centerNorm);
			AOSamples++;
		}

		float3 upsample = Upsample(_AOFar, _AOFar_TexelSize, i.uv, centerNorm, centerPos.z);
		float aoMax = max(upsample.x, AONear / AOSamples);
		float aoAverage = (upsample.y + AONear) / (upsample.z + AOSamples);

		float currentFrameAO = (1.0 - aoMax) * (1.0 - aoAverage);

		// We could implement some reprojection temporal filter to avoid jittering between frames.

		return currentFrameAO;
	}

#endif // MSSAO_CG_INCLUDED
