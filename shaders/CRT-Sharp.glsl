// CRT Sharp - scanlines only. No curvature, no mask, no vignette.
// The subtle option: keeps the image crisp and geometrically flat, and just
// adds the horizontal line structure. Good at high internal resolutions and
// on small windows where a mask would just look like noise.
//
// Pitch is locked to a virtual 480-line screen so the look is identical from
// 1x to 8x internal resolution (see CRT.glsl for why that matters).

void main()
{
	float2 uv = GetCoordinates();
	float4 c = Sample();

	float s = sin(uv.y * 480.0 * 3.14159265);
	c.rgb *= 0.86 + 0.14 * (s * s);

	// Recover the brightness the scanlines cost.
	c.rgb = clamp(c.rgb * 1.08, 0.0, 1.0);
	SetOutput(float4(c.rgb, c.a));
}
