struct VertexInput {
    [[vk::location(0)]]
    float3 position : POSITION;
};

struct VertexOutput {
    float4 position : SV_POSITION;
    float3 box_coord : TEXCOORD0;
};

[[vk::binding(0, 0)]]
cbuffer UniformBuffer {
    float4x4 mvp_matrix;
    uint3 box_size;
    uint debug_value;
    float2 screen_size;
};

VertexOutput vertex_main(VertexInput vin) {
    VertexOutput vout;
    vout.position = mul(mvp_matrix, float4(vin.position, 1.0));
    vout.box_coord = vin.position;
    return vout;
}

struct FragmentOutput {
    float4 color : SV_TARGET0;
};

[[vk::binding(1, 0)]]
Texture3D<uint> rVoxelTexture;

FragmentOutput fragment_main(VertexOutput vout) {
    FragmentOutput fout;

    int3 coord = int3(vout.box_coord * box_size);
    float2 ndcXY = vout.position.xy / screen_size;
    float2 renderXY = ndcXY * float2(2.0, -2.0) - float2(1.0, -1.0);
    //float3 ray = 

    if (debug_value == 0) {
        uint value = rVoxelTexture.Load(int4(0, 0, 0, 0), 0);
        fout.color = float4(float3(value, value, value), 1.0);
    } else if (debug_value == 1) {
        fout.color = float4(ndcXY, 0.0, 1.0);
    } else if (debug_value == 2) {
        fout.color = float4(renderXY, 0.0, 1.0);
    } else {
        fout.color = float4(float3(coord) / box_size, 1.0);
    }

    return fout;
}