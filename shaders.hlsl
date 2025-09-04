struct VertexInput {
    [[vk::location(0)]]
    float3 position : POSITION;
};

struct VertexOutput {
    float4 position : SV_POSITION;
};

VertexOutput vertex_main(VertexInput vin) {
    VertexOutput vout;
    vout.position = float4(vin.position, 1.0);
    return vout;
}

struct FragmentOutput {
    float4 color : SV_TARGET0;
};

FragmentOutput fragment_main(VertexOutput vout) {
    FragmentOutput fout;
    fout.color = float4(0.0, 1.0, 0.0, 1.0);
    return fout;
}