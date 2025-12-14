struct VertexInput {};

struct VertexOutput {
    float4 position : SV_POSITION;
};

[[vk::binding(0, 0)]]
cbuffer UniformBuffer {
    float4x4 view_matrix;
};

VertexOutput vertex_main(VertexInput vin, uint vid : SV_VertexID) {
    float2 vertices[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0),
        float2(-1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
    };

    VertexOutput vout;
    vout.position = mul(view_matrix, float4(vertices[vid], 0.0, 1.0));
    return vout;
}

float f(float x) {
    return x;
}

struct FragmentOutput {
    float4 color : SV_TARGET0;
};

FragmentOutput fragment_main(VertexOutput vout) {
    FragmentOutput fout;
    fout.color = float4(0.05, 0.03, 0.02, 1.0);

    float y = f(vout.position.x);
    if (vout.position.y + 1e-3 >= y && vout.position.y - 1e-3 <= y) {
        fout.color = float4(1.0, 1.0, 1.0, 1.0);
    }
    return fout;
}
