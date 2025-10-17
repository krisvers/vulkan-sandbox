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
    float4 camera_info; // .xyz = position, .w = fov
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

    float3 camera_position = camera_info.xyz;
    float camera_fov = camera_info.w;
    float aspect_ratio = screen_size.x / screen_size.y;

    float3 local_right = mul(float4(-1.0, 0.0, 0.0, 0.0), camera_to_local_matrix).xyz;
    float3 local_up = mul(float4(0.0, -1.0, 0.0, 0.0), camera_to_local_matrix).xyz;
    float3 local_forward = mul(float4(0.0, 0.0, 1.0, 0.0), camera_to_local_matrix).xyz;

    int3 coord = int3(vout.box_coord);
    float2 ndc_xy = vout.position.xy / screen_size;
    float2 render_xy = ndc_xy * float2(2.0, -2.0) - float2(1.0, -1.0);

    float half_height = tan(camera_fov * 0.5);
    float half_width = half_height * aspect_ratio;
    float2 p = render_xy * float2(half_width, half_height);

    float3 local_camera_position = mul(float4(camera_position, 1.0), camera_to_local_matrix).xyz;
    float3 ray = normalize(local_forward + p.x * local_right + p.y * local_up);

    /* adapted from https://web.archive.org/web/20121024081332/www.xnawiki.com/index.php?title=Voxel_traversal */
    //int3 origin = int3(originf - 0.5);
    //int3 xyz = origin;
    int3 origin = int3(local_camera_position - 0.5);
    int3 xyz = origin;

    int3 step = sign(ray);
    int3 cell_boundary = int3(
        origin.x + (step.x > 0 ? 1 : 0),
        origin.y + (step.y > 0 ? 1 : 0),
        origin.z + (step.z > 0 ? 1 : 0)
    );

    float3 tmax = float3(
        (cell_boundary.x - local_camera_position.x) / ray.x,
        (cell_boundary.y - local_camera_position.y) / ray.y,
        (cell_boundary.z - local_camera_position.z) / ray.z
    );

    if (isnan(tmax.x)) {
        tmax.x = 1e100;
    }

    if (isnan(tmax.y)) {
        tmax.y = 1e100;
    }

    if (isnan(tmax.z)) {
        tmax.z = 1e100;
    }

    float3 tdelta = float3(
        step.x / ray.x,
        step.y / ray.y,
        step.z / ray.z
    );

    if (isnan(tdelta.x)) {
        tdelta.x = 1e100;
    }

    if (isnan(tdelta.y)) {
        tdelta.y = 1e100;
    }

    if (isnan(tdelta.z)) {
        tdelta.z = 1e100;
    }

    if (debug_value == 0) {
        while (true) {
            if (xyz.x < 0 || xyz.y < 0 || xyz.z < 0 ||
                xyz.x >= box_size.x || xyz.y >= box_size.y || xyz.z >= box_size.z) {
                break;
            }

            if (tmax.x < tmax.y && tmax.x < tmax.z) {
                xyz.x += step.x;
                tmax.x += tdelta.x;
            } else if (tmax.y < tmax.z) {
                xyz.y += step.y;
                tmax.y += tdelta.y;
            } else {
                xyz.z += step.z;
                tmax.z += tdelta.z;
            }

            if (xyz.x < 0 || xyz.y < 0 || xyz.z < 0 ||
                xyz.x >= box_size.x || xyz.y >= box_size.y || xyz.z >= box_size.z) {
                break;
            }

            uint value = rVoxelTexture.Load(int4(xyz, 0), 0);
            float valuef = float(value) / 255.0;
            fout.color = float4(float3(0.0, valuef, 0.0), 1.0);
            return fout;
        }
        
        fout.color = float4(float3(1.0, 0.0, 1.0), 1.0);
        return fout;
    } else if (debug_value == 1) {
        fout.color = float4(ndc_xy, 0.0, 1.0);
    } else if (debug_value == 2) {
        fout.color = float4(p, 0.0, 1.0);
    } else if (debug_value == 3) {
        fout.color = float4((ray + 1.0) / 2.0, 1.0);
    } else if (debug_value == 4) {
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
    } else if (debug_value == 5) {
        fout.color = float4(local_camera_position, 1.0);
    } else {
        fout.color = float4(float3(coord) / float3(box_size), 1.0);
    }

    return fout;
}