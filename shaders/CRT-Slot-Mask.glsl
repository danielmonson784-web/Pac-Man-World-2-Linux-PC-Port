// CRT Slot Mask - a consumer-TV look rather than the Trinitron-style aperture
// grille in CRT.glsl. The slot mask staggers its phosphor triads every other
// row, which is what gives real shadow-mask sets their brick-like texture.
//
// All pitches are locked to a virtual 480-line / 640-cell screen so the mask
// does not get finer (and start checkerboarding) as internal resolution rises.

float2 Curve(float2 uv)
{
	uv = (uv - 0.5) * 2.0;
	uv *= 1.018;
	uv.x *= 1.0 + pow(abs(uv.y) / 6.0, 2.0);
	uv.y *= 1.0 + pow(abs(uv.x) / 5.0, 2.0);
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

	// Phosphor bleed, slightly wider than the grille version.
	float2 inv = GetInvResolution();
	float4 glow = float4(0.0, 0.0, 0.0, 0.0);
	glow += SampleLocation(uv + float2( 2.0,  0.0) * inv);
	glow += SampleLocation(uv + float2(-2.0,  0.0) * inv);
	glow += SampleLocation(uv + float2( 0.0,  1.5) * inv);
	glow += SampleLocation(uv + float2( 0.0, -1.5) * inv);
	c.rgb += (glow.rgb * 0.25) * 0.15;

	float s = sin(uv.y * 480.0 * 3.14159265);
	c.rgb *= 0.88 + 0.12 * (s * s);

	// Slot mask: triads offset by half a cell on alternate row-pairs.
	float row = floor(uv.y * 240.0);
	float stagger = mod(row, 2.0) * 0.5;
	float col = fract(uv.x * 640.0 + stagger);
	float3 mask;
	if (col < 0.333)      mask = float3(1.06, 0.97, 0.97);
	else if (col < 0.666) mask = float3(0.97, 1.06, 0.97);
	else                  mask = float3(0.97, 0.97, 1.06);

	// Horizontal gaps between the slots, the part that reads as "shadow mask".
	float slot = sin(uv.y * 240.0 * 3.14159265);
	mask *= 0.96 + 0.04 * (slot * slot);
	c.rgb *= mask;

	float2 v = uv * (1.0 - uv.yx);
	c.rgb *= pow(clamp(v.x * v.y * 36.0, 0.0, 1.0), 0.12);

	c.rgb = clamp(c.rgb * 1.09, 0.0, 1.0);
	SetOutput(float4(c.rgb, c.a));
}
