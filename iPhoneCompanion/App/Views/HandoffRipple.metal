#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Second Chair's hand-over ripple (23 November 2026): a band of light and a
// gentle ripple travelling through the whole screen from `origin`, the
// Dynamic Island. `direction` 1 runs outwards, as both hand-overs do; -1
// would run back into the top. `progress` goes from 0 to 1 over the animation.
[[ stitchable ]] half4 handoffRipple(float2 position, SwiftUI::Layer layer, float2 size,
                                     float2 origin, float progress, float direction) {
    // Far enough to pass the furthest corner.
    float reach = length(float2(max(origin.x, size.x - origin.x), size.y - origin.y)) + 120.0;
    float travelled = direction > 0 ? progress : 1.0 - progress;
    float front = travelled * reach;

    float2 delta = position - origin;
    float distance = length(delta);
    float2 outwards = distance > 0.001 ? delta / distance : float2(0.0, 1.0);

    // Signed distance from the wave front, and a soft band around it.
    float band = distance - front;
    float width = 90.0;
    float envelope = exp(-(band * band) / (2.0 * width * width));
    // In at the start, out at the end.
    float strength = sin(progress * M_PI_F);

    // Ripples behind the front push the picture along the wave.
    float ripple = sin(band / 22.0) * envelope;
    float2 sample = position - outwards * ripple * 16.0 * strength;
    half4 colour = layer.sample(sample);

    // A band of light riding the front, brightest near the top.
    float nearTop = 1.0 - clamp(distance / reach, 0.0, 1.0) * 0.6;
    float light = envelope * strength * 0.38 * nearTop;
    colour.rgb = min(colour.rgb + half3(light, light * 0.97, light * 0.93) * colour.a, half3(1.0));
    return colour;
}
