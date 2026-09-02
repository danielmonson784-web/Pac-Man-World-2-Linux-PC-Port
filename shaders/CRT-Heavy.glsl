// CRT Heavy - the full arcade-monitor treatment: deep scanlines, strong
// curvature, pronounced mask and a real vignette. Considerably more character
// than CRT.glsl, and considerably less subtle; best on a large display.
//
// Pitches locked to a virtual 480-line / 640-cell screen (see CRT.glsl).

float2 Curve(float2 uv)
{
	uv = (uv - 0.5) * 2.0;
	uv *= 1.030;
	uv.x *= 1.0 + pow(abs(uv.y) / 4.0, 2.0);
	uv.y *= 1.0 + pow(abs(uv.x) / 3.5, 2.0);
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

	// Wide phosphor bloom.
	float2 inv = GetInvResolution();
	float4 glow = float4(0.0, 0.0, 0.0, 0.0);
	glow += SampleLocation(uv + float2( 2.5,  0.0) * inv);
	glow += SampleLocation(uv + float2(-2.5,  0.0) * inv);
	glow += SampleLocation(uv + float2( 0.0,  2.0) * inv);
	glow += SampleLocation(uv + float2( 0.0, -2.0) * inv);
	glow += SampleLocation(uv + float2( 1.8,  1.8) * inv);
	glow += SampleLocation(uv + float2(-1.8, -1.8) * inv);
	c.rgb += (glow.rgb / 6.0) * 0.26;

	// Deep scanlines.
	float s = sin(uv.y * 480.0 * 3.14159265);
	c.rgb *= 0.72 + 0.28 * (s * s);

	// Strong aperture grille.
	float col = fract(uv.x * 640.0);
	float3 mask;
	if (col < 0.333)      mask = float3(1.14, 0.90, 0.90);
	else if (col < 0.666) mask = float3(0.90, 1.14, 0.90);
	else                  mask = float3(0.90, 0.90, 1.14);
	c.rgb *= mask;

	// Pronounced vignette.
	float2 v = uv * (1.0 - uv.yx);
	c.rgb *= pow(clamp(v.x * v.y * 22.0, 0.0, 1.0), 0.28);

	// Lift the midtones back up after all that attenuation.
	c.rgb = clamp(c.rgb * 1.30, 0.0, 1.0);
	SetOutput(float4(c.rgb, c.a));
}
