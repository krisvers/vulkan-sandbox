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
    float4x4 camera_to_local_matrix;
    float3 camera_position;
};

VertexOutput vertex_main(VertexInput vin) {
    VertexOutput vout;
    vout.position = mul(mvp_matrix, float4(vin.position, 1.0));
    vout.box_coord = vin.position * box_size - 1e-4;
    return vout;
}

struct FragmentOutput {
    float4 color : SV_TARGET0;
};

[[vk::binding(1, 0)]]
Texture3D<uint> rVoxelTexture;

FragmentOutput fragment_main(VertexOutput vout) {
    FragmentOutput fout;

    float3 local_right = mul(camera_to_local_matrix, float4(1.0, 0.0, 0.0, 0.0)).xyz;
    float3 local_up = mul(camera_to_local_matrix, float4(0.0, 1.0, 0.0, 0.0)).xyz;
    float3 local_forward = mul(camera_to_local_matrix, float4(0.0, 0.0, 1.0, 0.0)).xyz;

    int3 coord = int3(vout.box_coord);
    float2 ndcXY = vout.position.xy / screen_size;
    float2 renderXY = ndcXY * float2(2.0, -2.0) - float2(1.0, -1.0);

    float3 ray = normalize(local_forward + renderXY.x * local_right + renderXY.y * local_up);
    float3 originf = mul(camera_to_local_matrix, float4(camera_position, 1.0)).xyz;

    /* adapted from https://web.archive.org/web/20121024081332/www.xnawiki.com/index.php?title=Voxel_traversal */
    int3 origin = int3(originf - 0.5);
    int3 step = sign(ray);
    int3 cell_boundary = int3(
        origin.x + (step.x > 0 ? 1 : 0),
        origin.y + (step.y > 0 ? 1 : 0),
        origin.z + (step.z > 0 ? 1 : 0)
    );

    float3 tmax = float3(
        (cell_boundary.x - originf.x) / ray.x,
        (cell_boundary.y - originf.y) / ray.y,
        (cell_boundary.z - originf.z) / ray.z
    );

    if (isnan(tmax.x)) {
        tmax.x = 1.0 / 0.0;
    }

    if (debug_value == 0) {
        if (coord.x > box_size.x - 1 || coord.y > box_size.y - 1 || coord.z > box_size.z - 1) {
            fout.color = float4(1.0, 0.0, 1.0, 1.0);
        } else {
            uint value = rVoxelTexture.Load(int4(coord, 0), 0);
            if (value == 0) {
                discard;
            }

            float valuef = float(value) / 255.0;
            fout.color = float4(float3(valuef, valuef, valuef), 1.0);
        }
    } else if (debug_value == 1) {
        fout.color = float4(ndcXY, 0.0, 1.0);
    } else if (debug_value == 2) {
        fout.color = float4(renderXY, 0.0, 1.0);
    } else if (debug_value == 3) {
        fout.color = float4((ray + 1.0) / 2.0, 1.0);
    } else {
        fout.color = float4(float3(coord) / float3(box_size), 1.0);
    }

    return fout;
}