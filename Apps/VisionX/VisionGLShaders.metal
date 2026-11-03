// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

struct VisionGLVertexIn {
    float4 position;
    float4 color;
    float4 normal;
};

struct VisionGLLight {
    float4 position;
    float4 ambient;
    float4 diffuse;
};

struct VisionGLUniforms {
    float4 modelView0;
    float4 modelView1;
    float4 modelView2;
    float4 modelView3;
    float4 projection0;
    float4 projection1;
    float4 projection2;
    float4 projection3;
    float4 materialAmbient;
    float4 materialDiffuse;
    float4 materialEmission;
    VisionGLLight light0;
    VisionGLLight light1;
    VisionGLLight light2;
    VisionGLLight light3;
    VisionGLLight light4;
    VisionGLLight light5;
    VisionGLLight light6;
    VisionGLLight light7;
    uint lightingEnabled;
    uint lightCount;
    uint _pad0;
    uint _pad1;
};

struct VisionGLVertexOut {
    float4 position [[position]];
    float4 color;
};

static inline VisionGLLight visionGLLightAt(constant VisionGLUniforms &uniforms, uint index) {
    switch (index) {
    case 0: return uniforms.light0;
    case 1: return uniforms.light1;
    case 2: return uniforms.light2;
    case 3: return uniforms.light3;
    case 4: return uniforms.light4;
    case 5: return uniforms.light5;
    case 6: return uniforms.light6;
    default: return uniforms.light7;
    }
}

vertex VisionGLVertexOut visionGLVertex(
    uint vertexID [[vertex_id]],
    const device VisionGLVertexIn *vertices [[buffer(0)]],
    constant VisionGLUniforms &uniforms [[buffer(1)]]
) {
    const VisionGLVertexIn inVertex = vertices[vertexID];
    const float4x4 modelView = float4x4(
        uniforms.modelView0,
        uniforms.modelView1,
        uniforms.modelView2,
        uniforms.modelView3
    );
    const float4x4 projection = float4x4(
        uniforms.projection0,
        uniforms.projection1,
        uniforms.projection2,
        uniforms.projection3
    );

    const float4 eyePosition = modelView * inVertex.position;
    const float4 glClip = projection * eyePosition;

    VisionGLVertexOut out;
    out.position = float4(glClip.x, glClip.y, (glClip.z + glClip.w) * 0.5, glClip.w);
    out.color = inVertex.color;

    if (uniforms.lightingEnabled != 0) {
        float3 normal = normalize((modelView * float4(inVertex.normal.xyz, 0.0)).xyz);
        float3 rgb = uniforms.materialEmission.rgb;
        rgb += uniforms.materialAmbient.rgb * 0.2;

        const uint lightCount = min(uniforms.lightCount, 8u);
        for (uint index = 0; index < lightCount; index++) {
            const VisionGLLight light = visionGLLightAt(uniforms, index);
            float3 lightVector;
            if (light.position.w == 0.0) {
                lightVector = normalize(light.position.xyz);
            } else {
                lightVector = normalize(light.position.xyz - eyePosition.xyz);
            }

            const float diffuseFactor = max(0.0, dot(normal, lightVector));
            rgb += uniforms.materialAmbient.rgb * light.ambient.rgb;
            rgb += uniforms.materialDiffuse.rgb * light.diffuse.rgb * diffuseFactor;
        }

        out.color = float4(clamp(rgb, 0.0, 1.0), uniforms.materialDiffuse.a);
    }

    return out;
}

fragment half4 visionGLFragment(VisionGLVertexOut in [[stage_in]]) {
    return half4(in.color);
}
