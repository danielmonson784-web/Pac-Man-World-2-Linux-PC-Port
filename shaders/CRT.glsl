// CRT - scanlines, a soft aperture-grille tint, gentle tube curvature and a
// light corner vignette.
//
// Tuning note: the post-process runs at the INTERNAL resolution, so anything
// keyed to GetResolution() gets finer as you raise internal res, and a mask
// written that way turns sprites into checkerboard. The mask and scanline
// pitch below are therefore locked to a virtual ~480-line screen instead, so
// the look stays constant from 1x to 8x.

float2 Curve(float2 uv)
{
	uv = (uv - 0.5) * 2.0;
	uv *= 1.015;
	uv.x *= 1.0 + pow(abs(uv.y) / 7.0, 2.0);
	uv.y *= 1.0 + pow(abs(uv.x) / 6.0, 2.0);
	return (uv / 2.0) + 0.5;
}

void main()
{
	float2 uv = Curve(GetCoordinates());

	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
	{
		SetOutput(float4(0.0, 0.0, 0.0, 1.0));
		return;
	}

	float4 c = SampleLocation(uv);

	// Phosphor bleed
	float2 inv = GetInvResolution();
	float4 glow = float4(0.0, 0.0, 0.0, 0.0);
	glow += SampleLocation(uv + float2( 1.5,  0.0) * inv);
	glow += SampleLocation(uv + float2(-1.5,  0.0) * inv);
	glow += SampleLocation(uv + float2( 0.0,  1.5) * inv);
	glow += SampleLocation(uv + float2( 0.0, -1.5) * inv);
	c.rgb += (glow.rgb * 0.25) * 0.12;

	// Scanlines at a fixed 480-line pitch, independent of internal resolution.
	float s = sin(uv.y * 480.0 * 3.14159265);
	c.rgb *= 0.90 + 0.10 * (s * s);

	// Aperture grille, also fixed pitch and much softer than a per-pixel mask.
	float col = fract(uv.x * 640.0);
	float3 mask;
	if (col < 0.333)      mask = float3(1.04, 0.98, 0.98);
	else if (col < 0.666) mask = float3(0.98, 1.04, 0.98);
	else                  mask = float3(0.98, 0.98, 1.04);
	c.rgb *= mask;

	// Light vignette - enough to round the corners, not enough to crush them.
	float2 v = uv * (1.0 - uv.yx);
	float vig = pow(clamp(v.x * v.y * 40.0, 0.0, 1.0), 0.10);
	c.rgb *= vig;

	c.rgb = clamp(c.rgb * 1.06, 0.0, 1.0);
	SetOutput(float4(c.rgb, c.a));
}
