// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

struct XWindowCompositeVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct XWindowCompositeUniforms {
    float2 viewSize;
    float2 baseSize;
    float2 glxOrigin;
    float2 glxSize;
    uint hasBase;
    uint hasGLX;
    uint crtEnabled;
    uint reserved0;
    float time;
    float scanlineIntensity;
    float phosphorMaskIntensity;
    float glowIntensity;
    float vignetteIntensity;
    float curvatureIntensity;
    float warbleIntensity;
    float reserved1;
};

static float2 clampToLayerBounds(float2 position, float2 size)
{
    float2 margin = float2(0.5f, 0.5f);
    return clamp(position, margin, max(margin, size - margin));
}

static float3 sampleCRTPixel(SwiftUI::Layer layer, float2 position, float2 size)
{
    float2 p = clampToLayerBounds(position, size);
    half4 sample = layer.sample(p);
    return float3(sample.r, sample.g, sample.b);
}

static float2 clampToTextureUV(float2 pixel, float2 size)
{
    float2 safeSize = max(size, float2(1.0f, 1.0f));
    float2 margin = float2(0.5f, 0.5f) / safeSize;
    return clamp((pixel + 0.5f) / safeSize, margin, 1.0f - margin);
}

static float3 sampleSmoothTexturePixel(texture2d<half> texture,
                                       sampler textureSampler,
                                       float2 pixel,
                                       float2 size)
{
    half4 sample = texture.sample(textureSampler, clampToTextureUV(pixel, size));
    return float3(sample.r, sample.g, sample.b);
}

static float crtSourceEdgeMask(float2 sourceUV, float2 size)
{
    float2 fade = max(float2(2.0f, 2.0f) / max(size, float2(1.0f, 1.0f)), float2(0.001f, 0.001f));
    float2 low = smoothstep(float2(0.0f, 0.0f), fade, sourceUV);
    float2 high = smoothstep(float2(0.0f, 0.0f), fade, 1.0f - sourceUV);
    return low.x * low.y * high.x * high.y;
}

static float3 applySoftCRTKernel(float3 center, float3 nearBlur, float3 farBlur, float glow)
{
    float nearMix = 0.12f + clamp(glow, 0.0f, 1.0f) * 0.10f;
    float farMix = clamp(glow, 0.0f, 1.0f) * 0.05f;
    float3 color = mix(center, nearBlur, nearMix);
    color = mix(color, farBlur, farMix);
    return clamp(color * 1.04f, 0.0f, 1.0f);
}

static float3 applySoftPhosphorMask(float3 color, float sourceX, float strength)
{
    float maskStrength = clamp(strength, 0.0f, 1.0f);
    float phase = sourceX * 2.094395102f;
    float3 triad = 0.72f + 0.28f * float3(
        0.5f + 0.5f * cos(phase),
        0.5f + 0.5f * cos(phase - 2.094395102f),
        0.5f + 0.5f * cos(phase - 4.188790205f)
    );
    return color * mix(float3(1.0f), triad, maskStrength);
}

static float softScanlineMask(float sourceY)
{
    return 0.5f + 0.5f * cos(sourceY * 2.094395102f);
}

static float3 sampleXWindowComposite(texture2d<half> baseTexture,
                                     texture2d<half> glxTexture,
                                     sampler textureSampler,
                                     float2 pixel,
                                     constant XWindowCompositeUniforms &uniforms)
{
    float3 color = float3(0.0f);

    if (uniforms.hasBase != 0 &&
        pixel.x >= 0.0f &&
        pixel.y >= 0.0f &&
        pixel.x < uniforms.baseSize.x &&
        pixel.y < uniforms.baseSize.y) {
        color = sampleSmoothTexturePixel(baseTexture, textureSampler, pixel, uniforms.baseSize);
    }

    if (uniforms.hasGLX != 0 &&
        pixel.x >= uniforms.glxOrigin.x &&
        pixel.y >= uniforms.glxOrigin.y &&
        pixel.x < uniforms.glxOrigin.x + uniforms.glxSize.x &&
        pixel.y < uniforms.glxOrigin.y + uniforms.glxSize.y) {
        float2 glxPixel = pixel - uniforms.glxOrigin;
        color = sampleSmoothTexturePixel(glxTexture, textureSampler, glxPixel, uniforms.glxSize);
    }

    return color;
}

static float4 applyCRTToComposite(texture2d<half> baseTexture,
                                  texture2d<half> glxTexture,
                                  sampler textureSampler,
                                  float2 position,
                                  constant XWindowCompositeUniforms &uniforms)
{
    float2 outputSize = max(uniforms.viewSize, float2(1.0f, 1.0f));
    float2 sourceSize = max(uniforms.baseSize, float2(1.0f, 1.0f));
    float2 uv = position / outputSize;
    float2 centered = uv * 2.0f - 1.0f;

    float curvature = clamp(uniforms.curvatureIntensity, 0.0f, 1.0f) * 0.16f;
    float radius2 = dot(centered, centered);
    float2 sourceUV = centered * (1.0f + radius2 * curvature) * 0.5f + 0.5f;

    float warble = clamp(uniforms.warbleIntensity, 0.0f, 1.0f);
    float wave =
        sin(uniforms.time * 0.7f + uv.y * 8.0f) * 0.0007f +
        sin(uniforms.time * 1.3f + uv.y * 2.0f) * 0.0009f +
        sin(uniforms.time * 0.2f) * sin(uv.y * 25.0f + uniforms.time * 3.0f) * 0.0004f;
    sourceUV.x += wave * warble * 3.0f;

    float edgeMask = crtSourceEdgeMask(sourceUV, sourceSize);
    float2 marginUV = float2(0.5f, 0.5f) / sourceSize;
    float2 sourcePosition = clamp(sourceUV, marginUV, 1.0f - marginUV) * sourceSize;
    float3 center = sampleXWindowComposite(baseTexture, glxTexture, textureSampler, sourcePosition, uniforms);
    float3 east = sampleXWindowComposite(baseTexture, glxTexture, textureSampler, sourcePosition + float2(1.0f, 0.0f), uniforms);
    float3 west = sampleXWindowComposite(baseTexture, glxTexture, textureSampler, sourcePosition + float2(-1.0f, 0.0f), uniforms);
    float3 north = sampleXWindowComposite(baseTexture, glxTexture, textureSampler, sourcePosition + float2(0.0f, -1.0f), uniforms);
    float3 south = sampleXWindowComposite(baseTexture, glxTexture, textureSampler, sourcePosition + float2(0.0f, 1.0f), uniforms);
    float3 nearBlur = (east + west + north + south) * 0.25f;
    float3 farBlur =
        sampleXWindowComposite(baseTexture, glxTexture, textureSampler, sourcePosition + float2(2.0f, 0.0f), uniforms) +
        sampleXWindowComposite(baseTexture, glxTexture, textureSampler, sourcePosition + float2(-2.0f, 0.0f), uniforms) +
        sampleXWindowComposite(baseTexture, glxTexture, textureSampler, sourcePosition + float2(0.0f, -2.0f), uniforms) +
        sampleXWindowComposite(baseTexture, glxTexture, textureSampler, sourcePosition + float2(0.0f, 2.0f), uniforms);
    farBlur *= 0.25f;

    float glow = clamp(uniforms.glowIntensity, 0.0f, 1.0f);
    float3 color = applySoftCRTKernel(center, nearBlur, farBlur, glow);

    float scanline = softScanlineMask(sourcePosition.y);
    color *= 1.0f - clamp(uniforms.scanlineIntensity, 0.0f, 1.0f) * scanline * 0.62f;

    color = applySoftPhosphorMask(color, sourcePosition.x, uniforms.phosphorMaskIntensity);

    float radius = length(centered);
    float vignette = smoothstep(0.36f, 1.18f, radius);
    color *= 1.0f - clamp(uniforms.vignetteIntensity, 0.0f, 1.0f) * vignette;

    float rollPosition = fract(uv.y - uniforms.time * 0.08f);
    float rollBand = smoothstep(0.0f, 0.05f, rollPosition) * smoothstep(0.5f, 0.45f, rollPosition);
    color *= 1.0f + rollBand * 0.025f * warble;

    color += nearBlur * glow * 0.12f;
    color += farBlur * glow * 0.08f;
    color += float3(0.012f, 0.04f, 0.016f) * glow;
    color *= edgeMask;

    return float4(clamp(color, 0.0f, 1.0f), edgeMask);
}

vertex XWindowCompositeVertexOut
xWindowCompositeVertex(uint vertexID [[vertex_id]])
{
    constexpr float2 positions[6] = {
        float2(-1.0f, 1.0f),
        float2(1.0f, 1.0f),
        float2(-1.0f, -1.0f),
        float2(1.0f, 1.0f),
        float2(1.0f, -1.0f),
        float2(-1.0f, -1.0f),
    };
    constexpr float2 uvs[6] = {
        float2(0.0f, 0.0f),
        float2(1.0f, 0.0f),
        float2(0.0f, 1.0f),
        float2(1.0f, 0.0f),
        float2(1.0f, 1.0f),
        float2(0.0f, 1.0f),
    };

    XWindowCompositeVertexOut out;
    out.position = float4(positions[vertexID], 0.0f, 1.0f);
    out.uv = uvs[vertexID];
    return out;
}

fragment half4
xWindowCompositeFragment(XWindowCompositeVertexOut in [[stage_in]],
                         texture2d<half> baseTexture [[texture(0)]],
                         texture2d<half> glxTexture [[texture(1)]],
                         sampler textureSampler [[sampler(0)]],
                         constant XWindowCompositeUniforms &uniforms [[buffer(0)]])
{
    float2 pixel = in.uv * max(uniforms.viewSize, float2(1.0f, 1.0f));
    if (uniforms.crtEnabled != 0) {
        float4 color = applyCRTToComposite(baseTexture, glxTexture, textureSampler, pixel, uniforms);
        return half4(half3(color.rgb), half(color.a));
    }

    float3 color = sampleXWindowComposite(baseTexture, glxTexture, textureSampler, pixel, uniforms);
    return half4(half3(color), 1.0h);
}

[[ stitchable ]] half4
crtWindowShader(
    float2 position,
    SwiftUI::Layer layer,
    float2 viewSize,
    float time,
    float scanlineIntensity,
    float phosphorMaskIntensity,
    float glowIntensity,
    float vignetteIntensity,
    float curvatureIntensity,
    float warbleIntensity
) {
    float2 size = max(viewSize, float2(1.0f, 1.0f));
    float2 uv = position / size;
    float2 centered = uv * 2.0f - 1.0f;

    float curvature = clamp(curvatureIntensity, 0.0f, 1.0f) * 0.16f;
    float radius2 = dot(centered, centered);
    float2 sourceUV = centered * (1.0f + radius2 * curvature) * 0.5f + 0.5f;

    float warble = clamp(warbleIntensity, 0.0f, 1.0f);
    float wave =
        sin(time * 0.7f + uv.y * 8.0f) * 0.0007f +
        sin(time * 1.3f + uv.y * 2.0f) * 0.0009f +
        sin(time * 0.2f) * sin(uv.y * 25.0f + time * 3.0f) * 0.0004f;
    sourceUV.x += wave * warble * 3.0f;

    float edgeMask = crtSourceEdgeMask(sourceUV, size);
    float2 marginUV = float2(0.5f, 0.5f) / size;
    float2 sourcePosition = clamp(sourceUV, marginUV, 1.0f - marginUV) * size;
    float3 center = sampleCRTPixel(layer, sourcePosition, size);
    float3 east = sampleCRTPixel(layer, sourcePosition + float2(1.0f, 0.0f), size);
    float3 west = sampleCRTPixel(layer, sourcePosition + float2(-1.0f, 0.0f), size);
    float3 north = sampleCRTPixel(layer, sourcePosition + float2(0.0f, -1.0f), size);
    float3 south = sampleCRTPixel(layer, sourcePosition + float2(0.0f, 1.0f), size);
    float3 nearBlur = (east + west + north + south) * 0.25f;
    float3 farBlur =
        sampleCRTPixel(layer, sourcePosition + float2(2.0f, 0.0f), size) +
        sampleCRTPixel(layer, sourcePosition + float2(-2.0f, 0.0f), size) +
        sampleCRTPixel(layer, sourcePosition + float2(0.0f, -2.0f), size) +
        sampleCRTPixel(layer, sourcePosition + float2(0.0f, 2.0f), size);
    farBlur *= 0.25f;

    float glow = clamp(glowIntensity, 0.0f, 1.0f);
    float3 color = applySoftCRTKernel(center, nearBlur, farBlur, glow);

    float scanline = softScanlineMask(sourcePosition.y);
    color *= 1.0f - clamp(scanlineIntensity, 0.0f, 1.0f) * scanline * 0.62f;

    color = applySoftPhosphorMask(color, sourcePosition.x, phosphorMaskIntensity);

    float radius = length(centered);
    float vignette = smoothstep(0.36f, 1.18f, radius);
    color *= 1.0f - clamp(vignetteIntensity, 0.0f, 1.0f) * vignette;

    float rollPosition = fract(uv.y - time * 0.08f);
    float rollBand = smoothstep(0.0f, 0.05f, rollPosition) * smoothstep(0.5f, 0.45f, rollPosition);
    color *= 1.0f + rollBand * 0.025f * warble;

    color += nearBlur * glow * 0.12f;
    color += farBlur * glow * 0.08f;
    color += float3(0.012f, 0.04f, 0.016f) * glow;
    color *= edgeMask;

    return half4(half3(clamp(color, 0.0f, 1.0f)), half(edgeMask));
}
