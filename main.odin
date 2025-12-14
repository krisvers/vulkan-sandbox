package main

import "core:sys/valgrind"
import "base:runtime"
import "base:intrinsics"
import "core:fmt"
import vk "vendor:vulkan"
import "vendor:sdl3"
import "vendor:directx/dxc"

import "vendor:miniaudio"
import "vendor:stb/vorbis"

import "core:c"
import "core:strings"
import "core:unicode/utf16"
import "core:math/linalg"
import "core:math"
import "core:os"

AUDIO_RENDER_BUFFER_SIZE :: 32768
AUDIO_LOCAL_BUFFER_SIZE :: 268435456 //16777216
AUDIO_OUTPUT_SAMPLE_FREQUENCY :: 44100
AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE :: 4

when ODIN_OS == .Darwin {
    @(export)
    foreign import moltenvk "MoltenVK"
}

MemoryResidentHandle :: union {
    vk.Image,
    vk.Buffer,
}

MemoryResidentID :: struct {
    handle: MemoryResidentHandle,
    is_image: bool,
}

MemoryResident :: struct {
    id: MemoryResidentID,
    size: vk.DeviceSize,
    alignment: vk.DeviceSize,
    offset: vk.DeviceSize,
}

MemoryAllocation :: struct {
    memory: vk.DeviceMemory,
    size: vk.DeviceSize,
    residents: map[MemoryResidentID]MemoryResident,
}

resize_swapchain :: proc(  
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    swapchain: ^vk.SwapchainKHR,
    swapchain_image_count: ^u32,
    swapchain_images: ^[dynamic]vk.Image,
    swapchain_image_views: ^[dynamic]vk.ImageView,
    swapchain_image_finished_semaphores: ^[dynamic]vk.Semaphore
) -> (vk.SurfaceCapabilitiesKHR, bool) {
    surface_capabilites := vk.SurfaceCapabilitiesKHR {}
    assert(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_capabilites) == .SUCCESS)

    if surface_capabilites.currentExtent.width == 0 || surface_capabilites.currentExtent.height == 0 {
        return surface_capabilites, false
    }

    old_swapchain := swapchain^
    result := vk.CreateSwapchainKHR(device, &{
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = surface,
        minImageCount = 3,
        imageFormat = .B8G8R8A8_UNORM,
        imageColorSpace = .SRGB_NONLINEAR,
        imageExtent = surface_capabilites.currentExtent,
        imageArrayLayers = 1,
        imageUsage = { .STORAGE, .TRANSFER_DST },
        imageSharingMode = .EXCLUSIVE,
        preTransform = { .IDENTITY },
        compositeAlpha = { .OPAQUE },
        presentMode = .IMMEDIATE,
        oldSwapchain = old_swapchain,
    }, nil, swapchain)
    assert(result == .SUCCESS)
    vk.DestroySwapchainKHR(device, old_swapchain, nil)

    for iv in swapchain_image_views {
        vk.DestroyImageView(device, iv, nil)
    }

    old_swapchain_image_count := swapchain_image_count^
    assert(vk.GetSwapchainImagesKHR(device, swapchain^, swapchain_image_count, nil) == .SUCCESS)

    for i in swapchain_image_count^..<old_swapchain_image_count {
        vk.DestroySemaphore(device, swapchain_image_finished_semaphores^[i], nil)
    }

    resize(swapchain_images, swapchain_image_count^)
    assert(vk.GetSwapchainImagesKHR(device, swapchain^, swapchain_image_count, &(swapchain_images^[0])) == .SUCCESS)

    resize(swapchain_image_views, swapchain_image_count^)
    resize(swapchain_image_finished_semaphores, swapchain_image_count^)
    
    for i in 0..<swapchain_image_count^ {
        assert(vk.CreateImageView(device, &{
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = swapchain_images^[i],
            viewType = .D2,
            format = .B8G8R8A8_UNORM,
            components = {
                r = .IDENTITY,
                g = .IDENTITY,
                b = .IDENTITY,
                a = .IDENTITY,
            },
            subresourceRange = {
                aspectMask = { .COLOR },
                baseMipLevel = 0,
                levelCount = 1,
                baseArrayLayer = 0,
                layerCount = 1,
            },
        }, nil, &(swapchain_image_views^[i])) == .SUCCESS)
    
        if i >= old_swapchain_image_count {
            assert(vk.CreateSemaphore(device, &{
                sType = .SEMAPHORE_CREATE_INFO,
            }, nil, &(swapchain_image_finished_semaphores^[i])) == .SUCCESS)
        }
    }

    return surface_capabilites, true
}

find_memory_type_index_single :: proc(
    physical_device: vk.PhysicalDevice,
    memory_type_bits: u32,
    memory_properties: vk.MemoryPropertyFlags
) -> u32 {
    physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(physical_device, &physical_device_memory_properties)

    for i in 0..<physical_device_memory_properties.memoryTypeCount {
        if (memory_type_bits & (1 << i)) != 0 && (physical_device_memory_properties.memoryTypes[i].propertyFlags & memory_properties) == memory_properties {
            return i
        }
    }

    return vk.MAX_MEMORY_TYPES
}

find_memory_type_index_multiple :: proc(
    physical_device: vk.PhysicalDevice,
    memory_requirementses: []vk.MemoryRequirements,
    memory_properties: vk.MemoryPropertyFlags
) -> u32 {
    physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(physical_device, &physical_device_memory_properties)

    for i in 0..<physical_device_memory_properties.memoryTypeCount {
        if (physical_device_memory_properties.memoryTypes[i].propertyFlags & memory_properties) != memory_properties {
            continue
        }

        incompatible := false
        for r in memory_requirementses {
            if (r.memoryTypeBits & (1 << i)) == 0 {
                incompatible = true
                break
            }
        }

        if !incompatible {
            return i
        }
    }

    return vk.MAX_MEMORY_TYPES
}

find_memory_type_index :: proc {
    find_memory_type_index_single,
    find_memory_type_index_multiple,
}

destroy_allocation :: proc(
    device: vk.Device,
    allocation: ^MemoryAllocation
) {
    vk.FreeMemory(device, allocation.memory, nil)
    delete(allocation.residents)
    
    allocation.memory = 0
    allocation.residents = {}
}

allocate_for_resources :: proc(
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    residents: []MemoryResidentID,
    memory_properties: vk.MemoryPropertyFlags,
    minimum_size: vk.DeviceSize = 0,
) -> (allocation: MemoryAllocation, result: vk.Result) {
    memory_type_index: u32
    memory_requirementses := make([]vk.MemoryRequirements, len(residents))
    sizes := make([]vk.DeviceSize, len(residents))
    offsets := make([]vk.DeviceSize, len(residents))
    defer delete(memory_requirementses)

    total_size := vk.DeviceSize(0)
    for i in 0..<len(residents) {
        if residents[i].is_image {
            vk.GetImageMemoryRequirements(device, residents[i].handle.(vk.Image), &memory_requirementses[i])
        } else {
            vk.GetBufferMemoryRequirements(device, residents[i].handle.(vk.Buffer), &memory_requirementses[i])
        }

        r := total_size % memory_requirementses[i].alignment
        total_size = total_size + (r == 0 ? 0 : memory_requirementses[i].alignment - r)
        offsets[i] = total_size
        sizes[i] = memory_requirementses[i].size
        total_size += sizes[i]
    }

    total_size = max(total_size, minimum_size)
    memory_type_index = find_memory_type_index(physical_device, memory_requirementses, memory_properties)
    if memory_type_index == vk.MAX_MEMORY_TYPES {
        delete(sizes)
        delete(offsets)
        return {}, .ERROR_UNKNOWN
    }

    memory: vk.DeviceMemory
    result = vk.AllocateMemory(device, &{
        sType = .MEMORY_ALLOCATE_INFO,
        allocationSize = total_size,
        memoryTypeIndex = memory_type_index,
    }, nil, &memory)

    if result != .SUCCESS {
        delete(sizes)
        delete(offsets)
        return {}, result
    }

    allocation = MemoryAllocation {
        memory = memory,
        size = total_size,
        residents = make(map[MemoryResidentID]MemoryResident),
    }

    for i in 0..<len(residents) {
        allocation.residents[residents[i]] = {
            id = residents[i],
            size = sizes[i],
            alignment = memory_requirementses[i].alignment,
            offset = offsets[i],
        }
    }

    return allocation, .SUCCESS
}

bind_resources_to_allocation_auto :: proc(
    device: vk.Device,
    allocation: ^MemoryAllocation,
) -> (result := vk.Result.SUCCESS) {
    for id, resident in allocation.residents {
        r: vk.Result
        if resident.id.is_image {
            r = vk.BindImageMemory(device, resident.id.handle.(vk.Image), allocation.memory, resident.offset)
        } else {
            r = vk.BindBufferMemory(device, resident.id.handle.(vk.Buffer), allocation.memory, resident.offset)
        }

        if r != .SUCCESS {
            result = r
        }
    }

    return
}

bind_resources_to_allocation :: proc {
    bind_resources_to_allocation_auto,
    /* bind_resources_to_allocation_manual, */ 
}

replace_resource_in_allocation :: proc(
    device: vk.Device,
    allocation: ^MemoryAllocation,
    old_resident: MemoryResidentID,
    new_resident: MemoryResidentID
) {
    if old_resident == new_resident {
        return
    }

    memory_requirements: vk.MemoryRequirements
    if new_resident.is_image {
        vk.GetImageMemoryRequirements(device, new_resident.handle.(vk.Image), &memory_requirements)
    } else {
        vk.GetBufferMemoryRequirements(device, new_resident.handle.(vk.Buffer), &memory_requirements)
    }

    allocation.residents[new_resident] = {
        id = new_resident,
        size = memory_requirements.size,
        alignment = memory_requirements.alignment,
        offset = allocation.residents[old_resident].offset,
    }

    delete_key(&allocation.residents, old_resident)
    if new_resident.is_image {
        vk.BindImageMemory(device, new_resident.handle.(vk.Image), allocation.memory, allocation.residents[new_resident].offset)
    } else {
        vk.BindBufferMemory(device, new_resident.handle.(vk.Buffer), allocation.memory, allocation.residents[new_resident].offset)
    }
}

when ODIN_OS == .Windows {
    @(private) _convert_cstring_to_wstring :: proc(s: string) -> []c.wchar_t {
        wstring := make([]c.wchar_t, len(s) + 1)
        utf16.encode_string(wstring, s)
        wstring[len(s)] = 0
        return wstring
    }
} else {
    @(private) _convert_cstring_to_wstring :: proc(s: string) -> []c.wchar_t {
        wstring := make([]c.wchar_t, len(s) + 1)
        for i in 0..<len(s) {
            wstring[i] = c.wchar_t(s[i])
        }
        wstring[len(s)] = 0
        return wstring
    }
}

compile_hlsl :: proc(
    device: vk.Device,
    dxc_utils: ^dxc.IUtils,
    dxc_compiler: ^dxc.ICompiler,
    source: cstring,
    entry_point: cstring,
    stage: vk.ShaderStageFlags
) -> (module: vk.ShaderModule, result: vk.Result) {
    dxc_blob_encoding: ^dxc.IBlobEncoding
    if dxc_utils->CreateBlob(rawptr(source), u32(len(source)), dxc.CP_UTF8, &dxc_blob_encoding) != 0 {
        return 0, .ERROR_UNKNOWN
    }
    defer dxc_blob_encoding->Release()

    wtarget := _convert_cstring_to_wstring("-T")
    wtarget_value: []c.wchar_t
    if .VERTEX in stage {
        wtarget_value = _convert_cstring_to_wstring("vs_6_0")
    } else if .FRAGMENT in stage {
        wtarget_value = _convert_cstring_to_wstring("ps_6_0")
    } else if .COMPUTE in stage {
        wtarget_value = _convert_cstring_to_wstring("cs_6_0")
    } else if .GEOMETRY in stage {
        wtarget_value = _convert_cstring_to_wstring("gs_6_0")
    } else if .TESSELLATION_CONTROL in stage {
        wtarget_value = _convert_cstring_to_wstring("hs_6_0")
    } else if .TESSELLATION_EVALUATION in stage {
        wtarget_value = _convert_cstring_to_wstring("ds_6_0")
    }

    wentry := _convert_cstring_to_wstring("-E")
    wentry_value := _convert_cstring_to_wstring(string(entry_point))

    wspirv := _convert_cstring_to_wstring("-spirv")
    wdebug := _convert_cstring_to_wstring("-Zi")

    defer {
        delete(wtarget)
        delete(wtarget_value)
        delete(wentry)
        delete(wentry_value)
        delete(wspirv)
        delete(wdebug)
    }

    dxc_arguments: [6]dxc.wstring
    dxc_arguments[0] = &wtarget[0]
    dxc_arguments[1] = &wtarget_value[0]
    dxc_arguments[2] = &wentry[0]
    dxc_arguments[3] = &wentry_value[0]
    dxc_arguments[4] = &wspirv[0]

    dxc_argument_count := u32(5)

    when ODIN_DEBUG {
        dxc_arguments[dxc_argument_count] = &wdebug[0]
        dxc_argument_count += 1
    }

    dxc_result: ^dxc.IResult
    if dxc_compiler->Compile(
        dxc_blob_encoding,
        nil,
        &wentry_value[0],
        &wtarget_value[0],
        &dxc_arguments[0],
        dxc_argument_count,
        nil,
        0,
        nil,
        (^^dxc.IOperationResult)(&dxc_result)
    ) != 0 {
        return 0, .ERROR_UNKNOWN
    }
    defer dxc_result->Release()

    handle_error_with_msg := proc(dxc_result: ^dxc.IResult) {
        blob: ^dxc.IBlobEncoding
        if dxc_result->GetErrorBuffer(&blob) != 0 {
            fmt.println("DXC compilation failed (no error message available)")
            return
        }

        known: dxc.BOOL
        encoding: u32
        if blob->GetEncoding(&known, &encoding) != 0 || !known || encoding != dxc.CP_UTF8 && encoding != dxc.CP_UTF16 {
            fmt.println("DXC compilation failed (no error message available)")
            return
        }

        switch encoding {
            case dxc.CP_UTF8: fmt.printf("DXC compilation error: %s", strings.string_from_ptr(([^]u8)(blob->GetBufferPointer()), int(blob->GetBufferSize())))
            case dxc.CP_UTF16:
                st := make([]u8, blob->GetBufferSize() / 2)
                utf16.decode_to_utf8(st, ([^]u16)(blob->GetBufferPointer())[:blob->GetBufferSize() / 2])
                fmt.printf("DXC compilation error: %s", string(st))
                delete(st)
        }
    }

    dxc_result_hresult: dxc.HRESULT
    dxc_result->GetStatus(&dxc_result_hresult)
    if dxc_result_hresult != 0 {
        handle_error_with_msg(dxc_result)
        return 0, .ERROR_UNKNOWN
    }

    dxc_blob: ^dxc.IBlob
    if dxc_result->GetResult(&dxc_blob) != 0 {
        handle_error_with_msg(dxc_result)
        return 0, .ERROR_UNKNOWN
    }

    if dxc_blob->GetBufferPointer() == nil || dxc_blob->GetBufferSize() == 0 {
        handle_error_with_msg(dxc_result)
        return 0, .ERROR_UNKNOWN
    }

    spirv_size := int(dxc_blob->GetBufferSize())
    spirv_code := ([^]u32)(dxc_blob->GetBufferPointer())

    result = vk.CreateShaderModule(device, &{
        sType = .SHADER_MODULE_CREATE_INFO,
        codeSize = spirv_size,
        pCode = spirv_code
    }, nil, &module)

    if result != .SUCCESS {
        return 0, result
    }

    return module, .SUCCESS
}

AudioUniforms :: struct #packed {
    cpu_read_ptr: u32,
    seek: u32,
    paused: b32,
    sample_frequency: u32,

    dispatch_dimensions: [3]u32,

    _padding: u32,

    sequence0: u32,
    sequence1: u32,
    sequence2: u32,
    sequence3: u32,
    sequence4: u32,
    sequence5: u32,
    sequence6: u32,
    sequence7: u32,
    sequence8: u32,
    sequence9: u32,
    sequence10: u32,
    sequence11: u32,

    counter0: u16,
    counter1: u16,
    counter2: u16,
    counter3: u16,
    counter4: u16,
    counter5: u16,
    counter6: u16,
    counter7: u16,

    input_track_count: u32,
}

AudioCPUSide :: struct {
    allocation: MemoryAllocation,
    allocation_mapped: rawptr,

    rendered_buffer: vk.Buffer,
    rendered_buffer_mapped: ^f32,

    transfer_buffer: vk.Buffer,
    transfer_buffer_mapped: ^f32,

    uniform_buffer: vk.Buffer,
    uniform_buffer_mapped: ^AudioUniforms,

    local_buffer: []f32,
}

AudioGPUSide :: struct {
    allocation: MemoryAllocation,
}

MAData :: struct {
    gpu: ^AudioGPUSide,
    cpu: ^AudioCPUSide,
}

ma_data_callback :: proc "c" (device: ^miniaudio.device, output: rawptr, input: rawptr, frame_count: u32) {
    context = runtime.default_context()
    data := (^MAData)(device.pUserData)
    assert(data != nil)

    size := frame_count * AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE * 2
    //assert(size <= AUDIO_RENDER_BUFFER_SIZE)

    //decoder := data.decoder
    fmt.println(data.cpu.uniform_buffer_mapped.seek, ' ', f32(data.cpu.uniform_buffer_mapped.seek) / f32(AUDIO_OUTPUT_SAMPLE_FREQUENCY), " (", data.cpu.uniform_buffer_mapped.counter0, ", ", data.cpu.uniform_buffer_mapped.counter1, ", ", data.cpu.uniform_buffer_mapped.counter2, ", ", data.cpu.uniform_buffer_mapped.counter3, ", ", data.cpu.uniform_buffer_mapped.counter4, ", ", data.cpu.uniform_buffer_mapped.counter5, ", ", data.cpu.uniform_buffer_mapped.counter6, ", ", data.cpu.uniform_buffer_mapped.counter7, ")", sep="")
    if !data.cpu.uniform_buffer_mapped.paused {
        intrinsics.mem_copy_non_overlapping(output, &data.cpu.local_buffer[(data.cpu.uniform_buffer_mapped.seek * 2) % (u32(len(data.cpu.local_buffer)))], size)
        //intrinsics.mem_copy_non_overlapping(output, data.cpu.rendered_buffer_mapped, size)

        data.cpu.uniform_buffer_mapped.seek += frame_count
        //miniaudio.decoder_read_pcm_frames(decoder, output, u64(frame_count), nil)
    }
}

ma_log_callback :: proc "c" (user_data: rawptr, level: u32, message: cstring) {
    context = runtime.default_context()
    fmt.println("[", miniaudio.log_level(level), "]: ", message, sep="")
}


load_tracks :: proc (paths: []string, device: vk.Device, physical_device: vk.PhysicalDevice, queue: vk.Queue, command_pool: vk.CommandPool, command_buffer: vk.CommandBuffer, transfer_buffer: vk.Buffer, transfer_size: vk.DeviceSize, transfer_buffer_mapped: rawptr) -> (MemoryAllocation, []MemoryResidentID) {
    ma_decoder_config := miniaudio.decoder_config_init(.f32, 2, AUDIO_OUTPUT_SAMPLE_FREQUENCY)

    ma_decoders := make([]miniaudio.decoder, len(paths))
    defer delete(ma_decoders)

    residents := make([]MemoryResidentID, len(paths))
    for i in 0..<len(paths) {
        assert(miniaudio.decoder_init_file(strings.unsafe_string_to_cstring(paths[i]), &ma_decoder_config, &ma_decoders[i]) == .SUCCESS)

        frame_count: u64
        assert(miniaudio.decoder_get_length_in_pcm_frames(&ma_decoders[i], &frame_count) == .SUCCESS)

        residents[i].is_image = false
        residents[i].handle = vk.Buffer(0)
        result := vk.CreateBuffer(device, &{
            sType = .BUFFER_CREATE_INFO,
            size = vk.DeviceSize(frame_count * AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE * 2),
            usage = { .TRANSFER_DST, .STORAGE_BUFFER },
        }, nil, &residents[i].handle.(vk.Buffer))
        assert(result == .SUCCESS)
    }

    defer for &d in ma_decoders {
        miniaudio.decoder_uninit(&d)
    }

    allocation, result := allocate_for_resources(device, physical_device, residents, { .DEVICE_LOCAL })
    assert(result == .SUCCESS)
    assert(bind_resources_to_allocation(device, &allocation) == .SUCCESS)

    for i in 0..<len(residents) {
        fmt.println("   ", i, "-", allocation.residents[residents[i]].size / AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE / 2, "frames or", allocation.residents[residents[i]].size, "bytes at offset", allocation.residents[residents[i]].offset)
    }

    upload_index := 0
    global_byte_index := vk.DeviceSize(0)
    for {
        /* pack data into transfer buffer */
        start_resource_index := max(int)
        start_resource_max_frame_count := vk.DeviceSize(0)
        local_byte_index := vk.DeviceSize(0)

        for i in 0..<len(residents) {
            if global_byte_index < allocation.residents[residents[i]].offset {
                global_byte_index = allocation.residents[residents[i]].offset
            }

            if global_byte_index >= allocation.residents[residents[i]].offset && global_byte_index < (allocation.residents[residents[i]].offset + allocation.residents[residents[i]].size) {
                start_resource_index = i
                local_byte_index = global_byte_index - allocation.residents[residents[i]].offset
                start_resource_max_frame_count = min(allocation.residents[residents[i]].size - local_byte_index, transfer_size) / AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE / 2
                break
            }
        }

        if start_resource_index == max(int) {
            fmt.println("failed to find goldilocks for global:", global_byte_index)
            break
        }

        fmt.println(start_resource_index, "decoding", start_resource_max_frame_count, "frames or", start_resource_max_frame_count * AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE * 2, "bytes at", local_byte_index, "global:", global_byte_index)

        assert(miniaudio.decoder_read_pcm_frames(&ma_decoders[start_resource_index], transfer_buffer_mapped, u64(start_resource_max_frame_count), nil) == .SUCCESS)

        assert(vk.ResetCommandPool(device, command_pool, {}) == .SUCCESS)
        assert(vk.BeginCommandBuffer(command_buffer, &{
            sType = .COMMAND_BUFFER_BEGIN_INFO,
        }) == .SUCCESS)

        if upload_index == 0 {
            pre_copy_buffer_memory_barriers := make([]vk.BufferMemoryBarrier, len(paths) + 1)
            pre_copy_buffer_memory_barriers[len(paths)] = {
                sType = .BUFFER_MEMORY_BARRIER,
                srcAccessMask = {},
                dstAccessMask = { .TRANSFER_READ },
                buffer = transfer_buffer,
                offset = 0,
                size = transfer_size,
            }

            i := 0
            for id, &resident in allocation.residents {
                pre_copy_buffer_memory_barriers[i] = {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = { .TRANSFER_WRITE },
                    buffer = id.handle.(vk.Buffer),
                    offset = 0,
                    size = resident.size,
                }
                i += 1
            }

            vk.CmdPipelineBarrier(
                command_buffer,
                { .TOP_OF_PIPE }, { .TRANSFER }, {},
                0, nil,
                u32(len(pre_copy_buffer_memory_barriers)), &pre_copy_buffer_memory_barriers[0],
                0, nil
            )
        }

        vk.CmdCopyBuffer(command_buffer,
            transfer_buffer, residents[start_resource_index].handle.(vk.Buffer),
            1, &vk.BufferCopy {
                srcOffset = 0,
                dstOffset = local_byte_index,
                size = vk.DeviceSize(start_resource_max_frame_count * AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE * 2),
            }
        )

        cmd_buffer := command_buffer
        assert(vk.EndCommandBuffer(command_buffer) == .SUCCESS)
        assert(vk.QueueSubmit(queue, 1, &vk.SubmitInfo {
            sType = .SUBMIT_INFO,
            waitSemaphoreCount = 0,
            pWaitSemaphores = nil,
            pWaitDstStageMask = nil,
            commandBufferCount = 1,
            pCommandBuffers = &cmd_buffer,
            signalSemaphoreCount = 0,
            pSignalSemaphores = nil,
        }, 0) == .SUCCESS)
        assert(vk.QueueWaitIdle(queue) == .SUCCESS)

        global_byte_index = allocation.residents[residents[start_resource_index]].offset + local_byte_index + start_resource_max_frame_count * AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE * 2
        upload_index += 1
    }

    return allocation, residents
}

main :: proc() {
    ma_data := MAData {}

    ma_log: miniaudio.log
    assert(miniaudio.log_init(nil, &ma_log) == .SUCCESS)
    assert(miniaudio.log_register_callback(&ma_log, {
        onLog = ma_log_callback,
    }) == .SUCCESS)
    defer miniaudio.log_uninit(&ma_log)

    ma_context_config := miniaudio.context_config_init()
    ma_context_config.pLog = &ma_log

    ma_context: miniaudio.context_type
    assert(miniaudio.context_init(nil, 0, &ma_context_config, &ma_context) == .SUCCESS)
    defer miniaudio.context_uninit(&ma_context)

    ma_device_config := miniaudio.device_config_init(.playback)
    ma_device_config.playback.format = .f32
    ma_device_config.playback.channels = 2
    ma_device_config.sampleRate = AUDIO_OUTPUT_SAMPLE_FREQUENCY
    ma_device_config.dataCallback = ma_data_callback
    ma_device_config.pUserData = &ma_data

    ma_device: miniaudio.device
    assert(miniaudio.device_init(&ma_context, &ma_device_config, &ma_device) == .SUCCESS)
    defer miniaudio.device_uninit(&ma_device)

    //ma_data.decoders = make([dynamic]miniaudio.decoder, 1, 16)
    //assert(miniaudio.decoder_init_file("sound.wav", nil, &ma_data.decoders[0]) == .SUCCESS)
    //defer miniaudio.decoder_uninit(ma_data.decoder)

    assert(sdl3.Init({ .VIDEO }))
    assert(sdl3.Vulkan_LoadLibrary(nil))

    dxc_utils: ^dxc.IUtils
    assert(dxc.CreateInstance(dxc.Utils_CLSID, dxc.IUtils_UUID, &dxc_utils) == 0)
    defer dxc_utils->Release()

    dxc_compiler: ^dxc.ICompiler
    assert(dxc.CreateInstance(dxc.Compiler_CLSID, dxc.ICompiler_UUID, &dxc_compiler) == 0)
    defer dxc_compiler->Release()

    sdl_proc_addr := sdl3.Vulkan_GetVkGetInstanceProcAddr()
    assert(sdl_proc_addr != nil)

    vk.load_proc_addresses_global(rawptr(sdl_proc_addr))
    assert(vk.CreateInstance != nil)

    sdl_extension_count: u32
    sdl_extensions := sdl3.Vulkan_GetInstanceExtensions(&sdl_extension_count)
    assert(sdl_extensions != nil)

    available_instance_extension_count: u32
    assert(vk.EnumerateInstanceExtensionProperties(nil, &available_instance_extension_count, nil) == .SUCCESS)

    available_instance_extensions := make([]vk.ExtensionProperties, available_instance_extension_count)
    if available_instance_extension_count > 0 {
        assert(vk.EnumerateInstanceExtensionProperties(nil, &available_instance_extension_count, &available_instance_extensions[0]) == .SUCCESS)
    }

    instance_extensions := make([dynamic]cstring, 0, sdl_extension_count + 1)
    for i in 0..<sdl_extension_count {
        append(&instance_extensions, sdl_extensions[i])
    }

    append(&instance_extensions, "VK_EXT_debug_utils")

    instance_flags := vk.InstanceCreateFlags {}
    when ODIN_OS == .Darwin {
        instance_flags |= { .ENUMERATE_PORTABILITY_KHR }
    }

    instance_layers := make([dynamic]cstring, 0, 1)
    when ODIN_DEBUG {
        append(&instance_layers, "VK_LAYER_KHRONOS_validation")
    }

    instance: vk.Instance
    result := vk.CreateInstance(&{
        sType = .INSTANCE_CREATE_INFO,
        flags = instance_flags,
        pApplicationInfo = &{
            pApplicationName = "vulkan",
            applicationVersion = vk.MAKE_VERSION(1, 0, 0),
            pEngineName = "vulkan",
            engineVersion = vk.MAKE_VERSION(1, 0, 0),
            apiVersion = vk.API_VERSION_1_2,
        },
        enabledLayerCount = u32(len(instance_layers)),
        ppEnabledLayerNames = len(instance_layers) == 0 ? nil : &instance_layers[0],
        enabledExtensionCount = u32(len(instance_extensions)),
        ppEnabledExtensionNames = &instance_extensions[0]
    }, nil, &instance)
    delete(instance_layers)
    delete(instance_extensions)
    delete(available_instance_extensions)
    assert(result == .SUCCESS)
    defer vk.DestroyInstance(instance, nil)

    vk.load_proc_addresses_instance(instance)
    
    debug_utils_messenger: vk.DebugUtilsMessengerEXT
    result = vk.CreateDebugUtilsMessengerEXT(instance, &{
        sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        messageSeverity = { .ERROR, .WARNING },
        messageType = { .GENERAL, .VALIDATION, .PERFORMANCE },
        pfnUserCallback = proc "system" (message_severity: vk.DebugUtilsMessageSeverityFlagsEXT, message_type: vk.DebugUtilsMessageTypeFlagsEXT, p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT, userdata: rawptr) -> b32 {
            context = runtime.default_context()
            fmt.println(message_severity, message_type, p_callback_data.pMessage)
            return false
        },
        pUserData = nil
    }, nil, &debug_utils_messenger)
    assert(result == .SUCCESS)
    defer vk.DestroyDebugUtilsMessengerEXT(instance, debug_utils_messenger, nil)

    window := sdl3.CreateWindow(strings.unsafe_string_to_cstring(os.args[1]), 1200, 900, { .VULKAN, .RESIZABLE })
    assert(window != nil)
    defer sdl3.DestroyWindow(window)

    surface: vk.SurfaceKHR
    assert(sdl3.Vulkan_CreateSurface(window, instance, nil, &surface))
    defer sdl3.Vulkan_DestroySurface(instance, surface, nil)

    physical_device_count: u32
    assert(vk.EnumeratePhysicalDevices(instance, &physical_device_count, nil) == .SUCCESS)

    physical_devices := make([]vk.PhysicalDevice, physical_device_count)
    assert(vk.EnumeratePhysicalDevices(instance, &physical_device_count, &physical_devices[0]) == .SUCCESS)

    physical_device := physical_devices[0]
    delete(physical_devices)

    available_device_extension_count: u32
    assert(vk.EnumerateDeviceExtensionProperties(physical_device, nil, &available_device_extension_count, nil) == .SUCCESS)

    available_device_extensions := make([]vk.ExtensionProperties, available_device_extension_count)
    assert(vk.EnumerateDeviceExtensionProperties(physical_device, nil, &available_device_extension_count, &available_device_extensions[0]) == .SUCCESS)
    
    device_extensions := make([dynamic]cstring, 2, 8)
    device_extensions[0] = "VK_KHR_swapchain"
    device_extensions[1] = "VK_KHR_dynamic_rendering"

    pnext := rawptr(nil)

    found_ext_memory_priority := false
    found_ext_pageable_device_local_memory := false
    found_khr_dynamic_rendering := false

    pageable_device_local_memory_features := vk.PhysicalDevicePageableDeviceLocalMemoryFeaturesEXT {
        sType = .PHYSICAL_DEVICE_PAGEABLE_DEVICE_LOCAL_MEMORY_FEATURES_EXT,
        pageableDeviceLocalMemory = true,
    }

    memory_priority_features := vk.PhysicalDeviceMemoryPriorityFeaturesEXT {
        sType = .PHYSICAL_DEVICE_MEMORY_PRIORITY_FEATURES_EXT,
        memoryPriority = true,
    }

    dynamic_rendering_features := vk.PhysicalDeviceDynamicRenderingFeaturesKHR {
        sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
        dynamicRendering = true,
    }

    for &p in available_device_extensions {
        if cstring(&p.extensionName[0]) == "VK_EXT_pageable_device_local_memory" {
            found_ext_pageable_device_local_memory = true
        } else if cstring(&p.extensionName[0]) == "VK_EXT_memory_priority" {
            found_ext_memory_priority = true
        } else if cstring(&p.extensionName[0]) == "VK_KHR_dynamic_rendering" {
            found_khr_dynamic_rendering = true
        }
    }

    if found_ext_memory_priority && found_ext_pageable_device_local_memory {
        append(&device_extensions, "VK_EXT_memory_priority")
        memory_priority_features.pNext = pnext

        append(&device_extensions, "VK_EXT_pageable_device_local_memory")
        pageable_device_local_memory_features.pNext = &memory_priority_features
        pnext = &pageable_device_local_memory_features
    }

    if found_khr_dynamic_rendering {
        append(&device_extensions, "VK_KHR_dynamic_rendering")
        dynamic_rendering_features.pNext = pnext
        pnext = &dynamic_rendering_features
    }

    descriptor_indexing_features := vk.PhysicalDeviceDescriptorIndexingFeatures {
        sType = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
        pNext = pnext,
        shaderStorageBufferArrayNonUniformIndexing = true,
        descriptorBindingStorageBufferUpdateAfterBind = true,
        descriptorBindingVariableDescriptorCount = true,
        descriptorBindingPartiallyBound = true,
    }

    pnext = &descriptor_indexing_features

    when ODIN_OS == .Darwin {
        append(&device_extensions, "VK_KHR_portability_subset")
    }

    queue_priority := f32(1.0)

    available_physical_device_features, physical_device_features := vk.PhysicalDeviceFeatures {}, vk.PhysicalDeviceFeatures {}
    vk.GetPhysicalDeviceFeatures(physical_device, &available_physical_device_features)

    device: vk.Device
    result = vk.CreateDevice(physical_device, &{
        sType = .DEVICE_CREATE_INFO,
        pNext = pnext,
        queueCreateInfoCount = 1,
        pQueueCreateInfos = &vk.DeviceQueueCreateInfo {
            sType = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = 0,
            queueCount = 1,
            pQueuePriorities = &queue_priority,
        },
        enabledExtensionCount = u32(len(device_extensions)),
        ppEnabledExtensionNames = &device_extensions[0],
        pEnabledFeatures = &physical_device_features,
    }, nil, &device)
    delete(available_device_extensions)
    delete(device_extensions)
    assert(result == .SUCCESS)
    defer vk.DestroyDevice(device, nil)

    queue: vk.Queue
    vk.GetDeviceQueue(device, 0, 0, &queue)
    
    command_pool: vk.CommandPool
    result = vk.CreateCommandPool(device, &{
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = {},
        queueFamilyIndex = 0,
    }, nil, &command_pool)
    assert(result == .SUCCESS)
    defer vk.DestroyCommandPool(device, command_pool, nil)

    command_buffer: vk.CommandBuffer
    result = vk.AllocateCommandBuffers(device, &{
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = command_pool,
        level = .PRIMARY,
        commandBufferCount = 1,
    }, &command_buffer)
    assert(result == .SUCCESS)
    defer vk.FreeCommandBuffers(device, command_pool, 1, &command_buffer)

    surface_capabilities: vk.SurfaceCapabilitiesKHR
    assert(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_capabilities) == .SUCCESS)

    swapchain: vk.SwapchainKHR
    result = vk.CreateSwapchainKHR(device, &{
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = surface,
        minImageCount = 3,
        imageFormat = .B8G8R8A8_UNORM,
        imageColorSpace = .SRGB_NONLINEAR,
        imageExtent = surface_capabilities.currentExtent,
        imageArrayLayers = 1,
        imageUsage = { .STORAGE, .TRANSFER_DST },
        imageSharingMode = .EXCLUSIVE,
        preTransform = surface_capabilities.currentTransform,
        compositeAlpha = { .OPAQUE },
        presentMode = .IMMEDIATE,
    }, nil, &swapchain)
    assert(result == .SUCCESS)
    defer vk.DestroySwapchainKHR(device, swapchain, nil)

    swapchain_image_count: u32
    assert(vk.GetSwapchainImagesKHR(device, swapchain, &swapchain_image_count, nil) == .SUCCESS)

    swapchain_images := make([dynamic]vk.Image, swapchain_image_count)
    defer delete(swapchain_images)

    assert(vk.GetSwapchainImagesKHR(device, swapchain, &swapchain_image_count, &swapchain_images[0]) == .SUCCESS)

    swapchain_image_views := make([dynamic]vk.ImageView, swapchain_image_count)
    swapchain_image_finished_semaphores := make([dynamic]vk.Semaphore, swapchain_image_count)
    for i in 0..<swapchain_image_count {
        assert(vk.CreateImageView(device, &{
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = swapchain_images[i],
            viewType = .D2,
            format = .B8G8R8A8_UNORM,
            components = {
                r = .IDENTITY,
                g = .IDENTITY,
                b = .IDENTITY,
                a = .IDENTITY,
            },
            subresourceRange = {
                aspectMask = { .COLOR },
                baseMipLevel = 0,
                levelCount = 1,
                baseArrayLayer = 0,
                layerCount = 1,
            },
        }, nil, &swapchain_image_views[i]) == .SUCCESS)

        assert(vk.CreateSemaphore(device, &{
            sType = .SEMAPHORE_CREATE_INFO,
        }, nil, &swapchain_image_finished_semaphores[i]) == .SUCCESS)
    }

    defer {
        for i in 0..<swapchain_image_count {
            vk.DestroyImageView(device, swapchain_image_views[i], nil)
            vk.DestroySemaphore(device, swapchain_image_finished_semaphores[i], nil)
        }

        delete(swapchain_image_views)
        delete(swapchain_image_finished_semaphores)
    }
    
    image_acquisition_semaphore: vk.Semaphore
    result = vk.CreateSemaphore(device, &{
        sType = .SEMAPHORE_CREATE_INFO,
    }, nil, &image_acquisition_semaphore)
    assert(result == .SUCCESS)
    defer vk.DestroySemaphore(device, image_acquisition_semaphore, nil)

    in_flight_fence: vk.Fence
    result = vk.CreateFence(device, &{
        sType = .FENCE_CREATE_INFO,
        flags = { .SIGNALED },
    }, nil, &in_flight_fence)
    assert(result == .SUCCESS)
    defer vk.DestroyFence(device, in_flight_fence, nil)

    depth_texture: vk.Image
    result = vk.CreateImage(device, &{
        sType = .IMAGE_CREATE_INFO,
        imageType = .D2,
        format = .D16_UNORM,
        extent = {
            width = surface_capabilities.currentExtent.width,
            height = surface_capabilities.currentExtent.height,
            depth = 1,
        },
        mipLevels = 1,
        arrayLayers = 1,
        samples = { ._1 },
        tiling = .OPTIMAL,
        usage = { .DEPTH_STENCIL_ATTACHMENT },
        sharingMode = .EXCLUSIVE,
        initialLayout = .UNDEFINED
    }, nil, &depth_texture)
    assert(result == .SUCCESS)

    depth_texture_memory_requirements: vk.MemoryRequirements
    vk.GetImageMemoryRequirements(device, depth_texture, &depth_texture_memory_requirements)

    gpu_screen_allocation_residents := []MemoryResidentID {
        {
            handle = depth_texture,
            is_image = true,
        }
    }

    gpu_screen_allocation, gpu_screen_allocation_result := allocate_for_resources(device, physical_device, gpu_screen_allocation_residents, { .DEVICE_LOCAL }, minimum_size = depth_texture_memory_requirements.size * 2)
    assert(gpu_screen_allocation_result == .SUCCESS)
    defer {
        vk.DestroyImage(device, depth_texture, nil)
        destroy_allocation(device, &gpu_screen_allocation)
    }

    assert(bind_resources_to_allocation(device, &gpu_screen_allocation) == .SUCCESS)

    depth_texture_view: vk.ImageView
    result = vk.CreateImageView(device, &{
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = depth_texture,
        viewType = .D2,
        format = .D16_UNORM,
        components = {
            r = .IDENTITY,
            g = .IDENTITY,
            b = .IDENTITY,
            a = .IDENTITY,
        },
        subresourceRange = {
            aspectMask = { .DEPTH },
            baseMipLevel = 0,
            levelCount = 1,
            baseArrayLayer = 0,
            layerCount = 1,
        }
    }, nil, &depth_texture_view)
    assert(result == .SUCCESS)
    defer vk.DestroyImageView(device, depth_texture_view, nil)

    /*
    ma_decoder_config := miniaudio.decoder_config_init(.f32, 2, AUDIO_OUTPUT_SAMPLE_FREQUENCY)

    ma_decoder: miniaudio.decoder
    assert(miniaudio.decoder_init_file(strings.unsafe_string_to_cstring(os.args[1]), &ma_decoder_config, &ma_decoder) == .SUCCESS)
    defer miniaudio.decoder_uninit(&ma_decoder)

    frame_count: u64
    assert(miniaudio.decoder_get_length_in_pcm_frames(&ma_decoder, &frame_count) == .SUCCESS)
    */

    audio_cpu := AudioCPUSide {}
    audio_gpu := AudioGPUSide {}

    result = vk.CreateBuffer(device, &{
        sType = .BUFFER_CREATE_INFO,
        size = AUDIO_RENDER_BUFFER_SIZE,
        usage = { .STORAGE_BUFFER },
    }, nil, &audio_cpu.rendered_buffer)
    assert(result == .SUCCESS)

    result = vk.CreateBuffer(device, &{
        sType = .BUFFER_CREATE_INFO,
        size = vk.DeviceSize(AUDIO_LOCAL_BUFFER_SIZE),
        usage = { .TRANSFER_SRC, .TRANSFER_DST },
    }, nil, &audio_cpu.transfer_buffer)
    assert(result == .SUCCESS)

    result = vk.CreateBuffer(device, &{
        sType = .BUFFER_CREATE_INFO,
        size = size_of(AudioUniforms),
        usage = { .UNIFORM_BUFFER },
    }, nil, &audio_cpu.uniform_buffer)
    assert(result == .SUCCESS)

    audio_cpu_residents := []MemoryResidentID {
        {
            handle = audio_cpu.rendered_buffer,
            is_image = false,
        },
        {
            handle = audio_cpu.transfer_buffer,
            is_image = false,
        },
        {
            handle = audio_cpu.uniform_buffer,
            is_image = false,
        }
    }

    audio_cpu.allocation, result = allocate_for_resources(device, physical_device, audio_cpu_residents, { .HOST_VISIBLE, .HOST_COHERENT })
    assert(result == .SUCCESS)
    defer {
        vk.DestroyBuffer(device, audio_cpu.uniform_buffer, nil)
        vk.DestroyBuffer(device, audio_cpu.transfer_buffer, nil)
        vk.DestroyBuffer(device, audio_cpu.rendered_buffer, nil)
        destroy_allocation(device, &audio_cpu.allocation)
    }

    assert(bind_resources_to_allocation(device, &audio_cpu.allocation) == .SUCCESS)
    assert(vk.MapMemory(device, audio_cpu.allocation.memory, 0, audio_cpu.allocation.size, {}, &audio_cpu.allocation_mapped) == .SUCCESS)
    defer vk.UnmapMemory(device, audio_cpu.allocation.memory)

    audio_cpu.rendered_buffer_mapped = (^f32)(&(([^]u8)(audio_cpu.allocation_mapped)[audio_cpu.allocation.residents[{
        handle = audio_cpu.rendered_buffer,
        is_image = false,
    }].offset]))

    audio_cpu.transfer_buffer_mapped = (^f32)(&(([^]u8)(audio_cpu.allocation_mapped)[audio_cpu.allocation.residents[{
        handle = audio_cpu.transfer_buffer,
        is_image = false,
    }].offset]))

    audio_cpu.uniform_buffer_mapped = (^AudioUniforms)(&(([^]u8)(audio_cpu.allocation_mapped)[audio_cpu.allocation.residents[{
        handle = audio_cpu.uniform_buffer,
        is_image = false,
    }].offset]))

    /*
    result = vk.CreateBuffer(device, &{
        sType = .BUFFER_CREATE_INFO,
        size = vk.DeviceSize(frame_count * AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE * 2),
        usage = { .TRANSFER_DST, .STORAGE_BUFFER },
    }, nil, &audio_gpu.sampled_buffer)
    assert(result == .SUCCESS)

    audio_gpu_residents := []MemoryResidentID {
        {
            handle = audio_gpu.sampled_buffer,
            is_image = false,
        },
    }

    audio_gpu.allocation, result = allocate_for_resources(device, physical_device, audio_gpu_residents, { .DEVICE_LOCAL })
    assert(result == .SUCCESS)
    defer {
        vk.DestroyBuffer(device, audio_gpu.sampled_buffer, nil)
        destroy_allocation(device, &audio_gpu.allocation)
    }

    assert(bind_resources_to_allocation(device, &audio_gpu.allocation) == .SUCCESS)
    */
    
    t := audio_cpu.allocation.residents[{
        handle = audio_cpu.transfer_buffer,
        is_image = false,
    }]

    input_track_allocation, input_track_order := load_tracks(os.args[2:], device, physical_device, queue, command_pool, command_buffer, audio_cpu.transfer_buffer, t.size, audio_cpu.transfer_buffer_mapped)
    defer {
        for id, &resident in input_track_allocation.residents {
            vk.DestroyBuffer(device, id.handle.(vk.Buffer), nil)
        }
        destroy_allocation(device, &input_track_allocation)
        delete(input_track_order)
    }

    /*
    assert(miniaudio.decoder_read_pcm_frames(&ma_decoder, audio_cpu.transfer_buffer_mapped, frame_count, nil) == .SUCCESS)

    assert(vk.ResetCommandPool(device, command_pool, {}) == .SUCCESS)
    assert(vk.BeginCommandBuffer(command_buffer, &{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
    }) == .SUCCESS)

    pre_copy_buffer_memory_barriers := [?]vk.BufferMemoryBarrier {
        {
            sType = .BUFFER_MEMORY_BARRIER,
            srcAccessMask = {},
            dstAccessMask = { .TRANSFER_READ },
            buffer = audio_cpu.transfer_buffer,
            offset = 0,
            size = audio_cpu.allocation.residents[{
                handle = audio_cpu.transfer_buffer,
                is_image = false
            }].size,
        },
        {
            sType = .BUFFER_MEMORY_BARRIER,
            srcAccessMask = {},
            dstAccessMask = { .TRANSFER_WRITE },
            buffer = audio_gpu.sampled_buffer,
            offset = 0,
            size = audio_gpu.allocation.residents[{
                handle = audio_gpu.sampled_buffer,
                is_image = false
            }].size,
        }
    }

    vk.CmdPipelineBarrier(
        command_buffer,
        { .TOP_OF_PIPE }, { .TRANSFER }, {},
        0, nil,
        u32(len(pre_copy_buffer_memory_barriers)), &pre_copy_buffer_memory_barriers[0],
        0, nil
    )

    vk.CmdCopyBuffer(command_buffer,
        audio_cpu.transfer_buffer, audio_gpu.sampled_buffer,
        1, &vk.BufferCopy {
            srcOffset = 0,
            dstOffset = 0,
            size = vk.DeviceSize(frame_count * AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE * 2),
        }
    )

    assert(vk.EndCommandBuffer(command_buffer) == .SUCCESS)
    assert(vk.QueueSubmit(queue, 1, &vk.SubmitInfo {
        sType = .SUBMIT_INFO,
        waitSemaphoreCount = 0,
        pWaitSemaphores = nil,
        pWaitDstStageMask = nil,
        commandBufferCount = 1,
        pCommandBuffers = &command_buffer,
        signalSemaphoreCount = 0,
        pSignalSemaphores = nil,
    }, 0) == .SUCCESS)
    assert(vk.QueueWaitIdle(queue) == .SUCCESS)
    */

    audio_cpu.local_buffer = make_slice([]f32, AUDIO_LOCAL_BUFFER_SIZE / AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE) // u32(len(audio_cpu.local_buffer)) / AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE)
    defer delete_slice(audio_cpu.local_buffer)

    audio_shader_source_hlsl := cstring(#load("audio.hlsl"))
    audio_shader_module, audio_shader_compilation_result := compile_hlsl(device, dxc_utils, dxc_compiler, audio_shader_source_hlsl, "process_audio", { .COMPUTE })
    if audio_shader_compilation_result != .SUCCESS {
        fmt.panicf("Failed to compile audio processing compute shader from audio.hlsl: %s", audio_shader_compilation_result)
    }
    defer vk.DestroyShaderModule(device, audio_shader_module, nil)

    audio_pipeline_descriptor_set_layout_bindings := [?]vk.DescriptorSetLayoutBinding {
        {
            binding = 0,
            descriptorType = .STORAGE_BUFFER,
            descriptorCount = 1,
            stageFlags = { .COMPUTE },
        },
        {
            binding = 1,
            descriptorType = .UNIFORM_BUFFER,
            descriptorCount = 1,
            stageFlags = { .COMPUTE },
        },
        {
            binding = 2,
            descriptorType = .STORAGE_IMAGE,
            descriptorCount = 1,
            stageFlags = { .COMPUTE },
        },
        {
            binding = 3,
            descriptorType = .STORAGE_BUFFER,
            descriptorCount = 4093,
            stageFlags = { .COMPUTE },
        },
    }

    audio_pipeline_descriptor_binding_flags := [?]vk.DescriptorBindingFlags {
        {},
        {},
        {},
        { .PARTIALLY_BOUND, .UPDATE_AFTER_BIND, },
    }

    audio_pipeline_descriptor_set_layout: vk.DescriptorSetLayout
    result = vk.CreateDescriptorSetLayout(device, &{
        sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        flags = { .UPDATE_AFTER_BIND_POOL },
        pNext = &vk.DescriptorSetLayoutBindingFlagsCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
            bindingCount = u32(len(audio_pipeline_descriptor_binding_flags)),
            pBindingFlags = &audio_pipeline_descriptor_binding_flags[0],
        },
        bindingCount = u32(len(audio_pipeline_descriptor_set_layout_bindings)),
        pBindings = &audio_pipeline_descriptor_set_layout_bindings[0],
    }, nil, &audio_pipeline_descriptor_set_layout)
    assert(result == .SUCCESS)
    defer vk.DestroyDescriptorSetLayout(device, audio_pipeline_descriptor_set_layout, nil)

    audio_pipeline_layout: vk.PipelineLayout
    result = vk.CreatePipelineLayout(device, &{
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        pSetLayouts = &audio_pipeline_descriptor_set_layout,
    }, nil, &audio_pipeline_layout)
    assert(result == .SUCCESS)
    defer vk.DestroyPipelineLayout(device, audio_pipeline_layout, nil)

    audio_pipeline: vk.Pipeline
    result = vk.CreateComputePipelines(device, 0, 1, &vk.ComputePipelineCreateInfo {
        sType = .COMPUTE_PIPELINE_CREATE_INFO,
        stage = {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = { .COMPUTE },
            module = audio_shader_module,
            pName = "process_audio",
        },
        layout = audio_pipeline_layout,
    }, nil, &audio_pipeline)
    assert(result == .SUCCESS)
    defer vk.DestroyPipeline(device, audio_pipeline, nil)

    audio_pipeline_descriptor_pool_sizes := [?]vk.DescriptorPoolSize {
        {
            type = .UNIFORM_BUFFER,
            descriptorCount = 1,
        },
        {
            type = .STORAGE_IMAGE,
            descriptorCount = 1,
        },
        {
            type = .STORAGE_BUFFER,
            descriptorCount = 4094,
        },
    }

    audio_pipeline_descriptor_pool: vk.DescriptorPool
    result = vk.CreateDescriptorPool(device, &{
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        flags = { .UPDATE_AFTER_BIND, },
        maxSets = 1,
        poolSizeCount = u32(len(audio_pipeline_descriptor_pool_sizes)),
        pPoolSizes = &audio_pipeline_descriptor_pool_sizes[0],
    }, nil, &audio_pipeline_descriptor_pool)
    assert(result == .SUCCESS)
    defer vk.DestroyDescriptorPool(device, audio_pipeline_descriptor_pool, nil)

    audio_pipeline_descriptor_set: vk.DescriptorSet
    result = vk.AllocateDescriptorSets(device, &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = audio_pipeline_descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &audio_pipeline_descriptor_set_layout,
    }, &audio_pipeline_descriptor_set)
    assert(result == .SUCCESS)

    shader_source_hlsl := cstring(#load("shaders.hlsl"))
    vertex_shader_module, vertex_shader_compilation_result := compile_hlsl(device, dxc_utils, dxc_compiler, shader_source_hlsl, "vertex_main", { .VERTEX })
    if vertex_shader_compilation_result != .SUCCESS {
        fmt.panicf("Failed to compile vertex shader from shaders.hlsl: %s", vertex_shader_compilation_result)
    }
    defer vk.DestroyShaderModule(device, vertex_shader_module, nil)

    fragment_shader_module, fragment_shader_compilation_result := compile_hlsl(device, dxc_utils, dxc_compiler, shader_source_hlsl, "fragment_main", { .FRAGMENT })
    if fragment_shader_compilation_result != .SUCCESS {
        fmt.panicf("Failed to compile fragment shader from shaders.hlsl: %s", fragment_shader_compilation_result)
    }
    defer vk.DestroyShaderModule(device, fragment_shader_module, nil)

    graphics_pipeline_descriptor_set_layout_bindings := [?]vk.DescriptorSetLayoutBinding {
        {
            binding = 0,
            descriptorType = .UNIFORM_BUFFER,
            descriptorCount = 1,
            stageFlags = { .VERTEX, .FRAGMENT },
        },
        /*
        {
            binding = 1,
            descriptorType = .SAMPLED_IMAGE,
            descriptorCount = 1,
            stageFlags = { .FRAGMENT },
        }
        */
    }

    graphics_pipeline_descriptor_set_layout: vk.DescriptorSetLayout
    result = vk.CreateDescriptorSetLayout(device, &{
        sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = u32(len(graphics_pipeline_descriptor_set_layout_bindings)),
        pBindings = &graphics_pipeline_descriptor_set_layout_bindings[0],
    }, nil, &graphics_pipeline_descriptor_set_layout)
    assert(result == .SUCCESS)
    defer vk.DestroyDescriptorSetLayout(device, graphics_pipeline_descriptor_set_layout, nil)

    graphics_pipeline_layout: vk.PipelineLayout
    result = vk.CreatePipelineLayout(device, &{
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        pSetLayouts = &graphics_pipeline_descriptor_set_layout,
    }, nil, &graphics_pipeline_layout)
    assert(result == .SUCCESS)
    defer vk.DestroyPipelineLayout(device, graphics_pipeline_layout, nil)

    graphics_pipeline_shader_stages := [2]vk.PipelineShaderStageCreateInfo {
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = { .VERTEX },
            module = vertex_shader_module,
            pName = "vertex_main",
        },
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = { .FRAGMENT },
            module = fragment_shader_module,
            pName = "fragment_main",
        },
    }

    graphics_pipeline_dynamic_states := [2]vk.DynamicState {
        .VIEWPORT,
        .SCISSOR,
    }

    graphics_pipeline_color_attachment_formats := [1]vk.Format {
        .B8G8R8A8_UNORM,
    }

    graphics_pipeline: vk.Pipeline
    result = vk.CreateGraphicsPipelines(device, 0, 1, &vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext = &vk.PipelineRenderingCreateInfoKHR {
            sType = .PIPELINE_RENDERING_CREATE_INFO_KHR,
            colorAttachmentCount = u32(len(graphics_pipeline_color_attachment_formats)),
            pColorAttachmentFormats = &graphics_pipeline_color_attachment_formats[0],
            depthAttachmentFormat = .D16_UNORM,
            stencilAttachmentFormat = .UNDEFINED,
        },
        stageCount = 2,
        pStages = &graphics_pipeline_shader_stages[0],
        pVertexInputState = &{
            sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            vertexBindingDescriptionCount = 0,
            pVertexBindingDescriptions = nil, /* &vk.VertexInputBindingDescription {
                binding = 0,
                stride = 3 * size_of(f32),
                inputRate = .VERTEX,
            }, */
            vertexAttributeDescriptionCount = 0,
            pVertexAttributeDescriptions = nil, /* &vk.VertexInputAttributeDescription {
                location = 0,
                binding = 0,
                format = .R32G32B32_SFLOAT,
            }, */
        },
        pInputAssemblyState = &{
            sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            topology = .TRIANGLE_LIST,
        },
        pViewportState = &{
            sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            viewportCount = 1,
            pViewports = &vk.Viewport {
                x = 0,
                y = f32(surface_capabilities.currentExtent.height),
                width = f32(surface_capabilities.currentExtent.width),
                height = -f32(surface_capabilities.currentExtent.height),
                minDepth = 0.0,
                maxDepth = 1.0,
            },
            scissorCount = 1,
            pScissors = &vk.Rect2D {
                offset = {
                    x = 0,
                    y = 0,
                },
                extent = surface_capabilities.currentExtent,
            },
        },
        pRasterizationState = &{
            sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            polygonMode = .FILL,
            cullMode = {},
            frontFace = .COUNTER_CLOCKWISE,
            lineWidth = 1.0,
        },
        pMultisampleState = &{
            sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            rasterizationSamples = { ._1 },
        },
        pDepthStencilState = &{
            sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            depthTestEnable = false,
            depthWriteEnable = false,
            depthCompareOp = .LESS,
            minDepthBounds = 0.0,
            maxDepthBounds = 1.0,
        },
        pColorBlendState = &{
            sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            attachmentCount = 1,
            pAttachments = &vk.PipelineColorBlendAttachmentState {
                blendEnable = true,
                srcColorBlendFactor = .ONE,
                dstColorBlendFactor = .ZERO,
                colorBlendOp = .ADD,
                srcAlphaBlendFactor = .ONE,
                dstAlphaBlendFactor = .ZERO,
                alphaBlendOp = .ADD,
                colorWriteMask = { .R, .G, .B, .A },
            },
            blendConstants = { 1.0, 1.0, 1.0, 1.0 },
        },
        pDynamicState = &{
            sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            dynamicStateCount = u32(len(graphics_pipeline_dynamic_states)),
            pDynamicStates = &graphics_pipeline_dynamic_states[0],
        },
        layout = graphics_pipeline_layout,
        renderPass = 0,
    }, nil, &graphics_pipeline)
    assert(result == .SUCCESS)
    defer vk.DestroyPipeline(device, graphics_pipeline, nil)

    graphics_pipeline_descriptor_pool_sizes := [?]vk.DescriptorPoolSize {
        {
            type = .UNIFORM_BUFFER,
            descriptorCount = 1,
        },
        /*
        {
            type = .SAMPLED_IMAGE,
            descriptorCount = 1,
        },
        */
    }

    graphics_pipeline_descriptor_pool: vk.DescriptorPool
    result = vk.CreateDescriptorPool(device, &{
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        maxSets = 1,
        poolSizeCount = u32(len(graphics_pipeline_descriptor_pool_sizes)),
        pPoolSizes = &graphics_pipeline_descriptor_pool_sizes[0],
    }, nil, &graphics_pipeline_descriptor_pool)
    assert(result == .SUCCESS)
    defer vk.DestroyDescriptorPool(device, graphics_pipeline_descriptor_pool, nil)

    graphics_pipeline_descriptor_set: vk.DescriptorSet
    result = vk.AllocateDescriptorSets(device, &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = graphics_pipeline_descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &graphics_pipeline_descriptor_set_layout,
    }, &graphics_pipeline_descriptor_set)
    assert(result == .SUCCESS)

    graphics_pipeline_descriptor_set_write_sets := [?]vk.WriteDescriptorSet {
        /*
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = graphics_pipeline_descriptor_set,
            dstBinding = 0,
            dstArrayElement = 0,
            descriptorCount = 1,
            descriptorType = .UNIFORM_BUFFER,
            pBufferInfo = &vk.DescriptorBufferInfo {
                buffer = uniform_buffer,
                offset = 0,
                range = size_of(UniformData),
            },
        },
        {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = graphics_pipeline_descriptor_set,
            dstBinding = 1,
            dstArrayElement = 0,
            descriptorCount = 1,
            descriptorType = .SAMPLED_IMAGE,
            pImageInfo = &vk.DescriptorImageInfo {
                imageView = voxel_texture_view,
                imageLayout = .SHADER_READ_ONLY_OPTIMAL,
                sampler = 0,
            },
        },
        */
    }

    //vk.UpdateDescriptorSets(device, u32(len(graphics_pipeline_descriptor_set_write_sets)), &graphics_pipeline_descriptor_set_write_sets[0], 0, nil)

    //uniform_data := (^UniformData)(&([^]u8)(cpu_allocation_mapped_rawptr)[cpu_allocation.residents[{ handle = uniform_buffer, is_image = false }].offset])

    audio_cpu.uniform_buffer_mapped.sequence0 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence1 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence2 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence3 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence4 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence5 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence6 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence7 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence8 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence9 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence10 = max(u32)
    audio_cpu.uniform_buffer_mapped.sequence11 = max(u32)

    audio_cpu.uniform_buffer_mapped.seek = 0
    audio_cpu.uniform_buffer_mapped.input_track_count = u32(len(input_track_allocation.residents))
    audio_cpu.uniform_buffer_mapped.sample_frequency = AUDIO_OUTPUT_SAMPLE_FREQUENCY

    ma_data.cpu = &audio_cpu
    ma_data.gpu = &audio_gpu
    miniaudio.device_start(&ma_device)

    visuals_enabled := true
    swapchain_enabled := true
    main_loop: for true {
        event: sdl3.Event
        for sdl3.PollEvent(&event) {
            if event.type == .QUIT {
                break main_loop
            } else if event.type == .KEY_DOWN {
                #partial switch event.key.scancode {
                    case .SPACE:
                        audio_cpu.uniform_buffer_mapped.paused = !audio_cpu.uniform_buffer_mapped.paused
                    case .LEFT:
                        audio_cpu.uniform_buffer_mapped.seek = u32(max(0, int(audio_cpu.uniform_buffer_mapped.seek) - AUDIO_OUTPUT_SAMPLE_FREQUENCY * 5))
                    case .RIGHT:
                        audio_cpu.uniform_buffer_mapped.seek = u32(max(0, int(audio_cpu.uniform_buffer_mapped.seek) + AUDIO_OUTPUT_SAMPLE_FREQUENCY * 5))
                    case .COMMA:
                        audio_cpu.uniform_buffer_mapped.seek = u32(max(0, int(audio_cpu.uniform_buffer_mapped.seek) - 128))
                    case .PERIOD:
                        audio_cpu.uniform_buffer_mapped.seek = u32(max(0, int(audio_cpu.uniform_buffer_mapped.seek) + 128))
                    case .RIGHTBRACKET:
                        visuals_enabled = true
                    case .LEFTBRACKET:
                        visuals_enabled = false
                    case .S:
                        ma_encoder_config := miniaudio.encoder_config_init(.wav, .f32, 2, AUDIO_OUTPUT_SAMPLE_FREQUENCY)

                        ma_encoder: miniaudio.encoder
                        ma_result := miniaudio.encoder_init_file(strings.unsafe_string_to_cstring(os.args[1]), &ma_encoder_config, &ma_encoder)
                        fmt.println(ma_result)
                        assert(ma_result == .SUCCESS)
                        assert(miniaudio.encoder_write_pcm_frames(&ma_encoder, &audio_cpu.local_buffer[0], min(u64(audio_cpu.uniform_buffer_mapped.seek), u64(len(audio_cpu.local_buffer) / 2)), nil) == .SUCCESS)
                        miniaudio.encoder_uninit(&ma_encoder)
                    case .Q:
                        if audio_cpu.uniform_buffer_mapped.sequence0 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence0 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case ._2:
                        if audio_cpu.uniform_buffer_mapped.sequence1 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence1 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case .W:
                        if audio_cpu.uniform_buffer_mapped.sequence2 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence2 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case ._3:
                        if audio_cpu.uniform_buffer_mapped.sequence3 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence3 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case .E:
                        if audio_cpu.uniform_buffer_mapped.sequence4 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence4 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case .R:
                        if audio_cpu.uniform_buffer_mapped.sequence5 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence5 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case ._5:
                        if audio_cpu.uniform_buffer_mapped.sequence6 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence6 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case .T:
                        if audio_cpu.uniform_buffer_mapped.sequence7 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence7 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case ._6:
                        if audio_cpu.uniform_buffer_mapped.sequence8 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence8 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case .Y:
                        if audio_cpu.uniform_buffer_mapped.sequence9 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence9 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case ._7:
                        if audio_cpu.uniform_buffer_mapped.sequence10 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence10 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case .U:
                        if audio_cpu.uniform_buffer_mapped.sequence11 == max(u32) {
                            audio_cpu.uniform_buffer_mapped.sequence11 = audio_cpu.uniform_buffer_mapped.seek
                        }
                    case .Z:
                        audio_cpu.uniform_buffer_mapped.counter0 += 1
                    case .X:
                        audio_cpu.uniform_buffer_mapped.counter1 += 1
                    case .C:
                        audio_cpu.uniform_buffer_mapped.counter2 += 1
                    case .V:
                        audio_cpu.uniform_buffer_mapped.counter3 += 1
                    case .B:
                        audio_cpu.uniform_buffer_mapped.counter4 += 1
                    case .N:
                        audio_cpu.uniform_buffer_mapped.counter5 += 1
                    case .SEMICOLON:
                        audio_cpu.uniform_buffer_mapped.counter6 += 1
                    case .APOSTROPHE:
                        audio_cpu.uniform_buffer_mapped.counter7 += 1
                }
            } else if event.type == .WINDOW_RESIZED {
                assert(vk.DeviceWaitIdle(device) == .SUCCESS)
                surface_capabilities, swapchain_enabled = resize_swapchain(device, physical_device, surface, &swapchain, &swapchain_image_count, &swapchain_images, &swapchain_image_views, &swapchain_image_finished_semaphores)
                
                vk.DestroyImageView(device, depth_texture_view, nil)
                vk.DestroyImage(device, depth_texture, nil)

                result = vk.CreateImage(device, &{
                    sType = .IMAGE_CREATE_INFO,
                    imageType = .D2,
                    format = .D16_UNORM,
                    extent = {
                        width = surface_capabilities.currentExtent.width,
                        height = surface_capabilities.currentExtent.height,
                        depth = 1,
                    },
                    mipLevels = 1,
                    arrayLayers = 1,
                    samples = { ._1 },
                    tiling = .OPTIMAL,
                    usage = { .DEPTH_STENCIL_ATTACHMENT },
                    sharingMode = .EXCLUSIVE,
                    initialLayout = .UNDEFINED,
                }, nil, &depth_texture)
                assert(result == .SUCCESS)

                vk.GetImageMemoryRequirements(device, depth_texture, &depth_texture_memory_requirements)
                if depth_texture_memory_requirements.size > gpu_screen_allocation.size {
                    destroy_allocation(device, &gpu_screen_allocation)

                    gpu_screen_allocation_residents = {
                        {
                            handle = depth_texture,
                            is_image = true,
                        }
                    }

                    gpu_screen_allocation, gpu_screen_allocation_result = allocate_for_resources(device, physical_device, gpu_screen_allocation_residents, { .DEVICE_LOCAL }, minimum_size = 3 * depth_texture_memory_requirements.size / 2)
                    assert(gpu_screen_allocation_result == .SUCCESS)
                    assert(bind_resources_to_allocation(device, &gpu_screen_allocation) == .SUCCESS)
                } else {
                    replace_resource_in_allocation(device, &gpu_screen_allocation, gpu_screen_allocation_residents[0], {
                        handle = depth_texture,
                        is_image = true,
                    })
                }
                
                result = vk.CreateImageView(device, &{
                    sType = .IMAGE_VIEW_CREATE_INFO,
                    image = depth_texture,
                    viewType = .D2,
                    format = .D16_UNORM,
                    components = {
                        r = .IDENTITY,
                        g = .IDENTITY,
                        b = .IDENTITY,
                        a = .IDENTITY,
                    },
                    subresourceRange = {
                        aspectMask = { .DEPTH },
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1,
                    }
                }, nil, &depth_texture_view)
                assert(result == .SUCCESS)
            } else if (event.type == .KEY_UP) {
                #partial switch event.key.scancode {
                    case .Q:
                        audio_cpu.uniform_buffer_mapped.sequence0 = max(u32)
                    case ._2:
                        audio_cpu.uniform_buffer_mapped.sequence1 = max(u32)
                    case .W:
                        audio_cpu.uniform_buffer_mapped.sequence2 = max(u32)
                    case ._3:
                        audio_cpu.uniform_buffer_mapped.sequence3 = max(u32)
                    case .E:
                        audio_cpu.uniform_buffer_mapped.sequence4 = max(u32)
                    case .R:
                        audio_cpu.uniform_buffer_mapped.sequence5 = max(u32)
                    case ._5:
                        audio_cpu.uniform_buffer_mapped.sequence6 = max(u32)
                    case .T:
                        audio_cpu.uniform_buffer_mapped.sequence7 = max(u32)
                    case ._6:
                        audio_cpu.uniform_buffer_mapped.sequence8 = max(u32)
                    case .Y:
                        audio_cpu.uniform_buffer_mapped.sequence9 = max(u32)
                    case ._7:
                        audio_cpu.uniform_buffer_mapped.sequence10 = max(u32)
                    case .U:
                        audio_cpu.uniform_buffer_mapped.sequence11 = max(u32)
                }
            }
        }

        aspect := f32(surface_capabilities.currentExtent.width) / f32(surface_capabilities.currentExtent.height);
        /*
        uniform_data^ = {
            /*
            mvp_matrix = linalg.mul(
                linalg.matrix4_perspective(1.6, f32(surface_capabilities.currentExtent.width) / f32(surface_capabilities.currentExtent.height), 0.01, 100.0, flip_z_axis = true),
                linalg.mul(
                    linalg.matrix4_translate(linalg.Vector3f32 { -camera_position[0], -camera_position[1], camera_position[2] }),
                    linalg.mul(
                        linalg.matrix4_rotate(-box_rotation[0], linalg.Vector3f32 { 1.0, 0.0, 0.0 }),
                        linalg.mul(
                            linalg.matrix4_rotate(-box_rotation[1], linalg.Vector3f32 { 0.0, 1.0, 0.0 }),
                            linalg.mul(
                                linalg.matrix4_rotate(-box_rotation[2], linalg.Vector3f32 { 0.0, 0.0, 1.0 }),
                                linalg.matrix4_translate(linalg.Vector3f32 { -0.5, -0.5, -0.5 }),
                            ),
                        ),
                    ),
                    /*linalg.mul(
                        linalg.matrix4_rotate(f32(sdl3.GetTicks()) / 1000.0, linalg.Vector3f32 { 0.0, 1.0, 0.0 }),
                        linalg.matrix4_rotate(-math.π / 4, linalg.Vector3f32 { 1.0, 0.0, 1.0 }),
                    ),*/
                ),
                //linalg.MATRIX4F32_IDENTITY,
            ),
            box_size = {
                CONTAINER_WIDTH, CONTAINER_HEIGHT, CONTAINER_DEPTH,
            },
            debug_value = debug_value,
            screen_size = {
                f32(surface_capabilities.currentExtent.width),
                f32(surface_capabilities.currentExtent.height),
            },
            camera_to_local_matrix = linalg.mul(
                linalg.matrix4_rotate(box_rotation[0], linalg.Vector3f32 { 1.0, 0.0, 0.0 }),
                linalg.mul(
                    linalg.matrix4_rotate(box_rotation[1], linalg.Vector3f32 { 0.0, 1.0, 0.0 }),
                    linalg.mul(
                        linalg.matrix4_rotate(box_rotation[2], linalg.Vector3f32 { 0.0, 0.0, 1.0 }),
                        linalg.matrix4_translate(linalg.Vector3f32 { 0.5, 0.5, 0.5 }),
                    ),
                ),
            ),
            camera_position = camera_position,
            camera_fov = 1.6,
            */
            view_matrix = linalg.matrix_ortho3d_f32(-aspect, aspect, -1.0, 1.0, 0.0, 1.0),
        }
        */

        vk.WaitForFences(device, 1, &in_flight_fence, true, max(u64))
        if swapchain_enabled {
            image_index: u32
            if visuals_enabled {
               result = vk.AcquireNextImageKHR(device, swapchain, max(u64), image_acquisition_semaphore, 0, &image_index)
            }
            if result == .ERROR_OUT_OF_DATE_KHR {
                assert(vk.DeviceWaitIdle(device) == .SUCCESS)
                surface_capabilities, swapchain_enabled = resize_swapchain(device, physical_device, surface, &swapchain, &swapchain_image_count, &swapchain_images, &swapchain_image_views, &swapchain_image_finished_semaphores)
                
                vk.DestroyImageView(device, depth_texture_view, nil)
                vk.DestroyImage(device, depth_texture, nil)

                result = vk.CreateImage(device, &{
                    sType = .IMAGE_CREATE_INFO,
                    imageType = .D2,
                    format = .D16_UNORM,
                    extent = {
                        width = surface_capabilities.currentExtent.width,
                        height = surface_capabilities.currentExtent.height,
                        depth = 1,
                    },
                    mipLevels = 1,
                    arrayLayers = 1,
                    samples = { ._1 },
                    tiling = .OPTIMAL,
                    usage = { .DEPTH_STENCIL_ATTACHMENT },
                    sharingMode = .EXCLUSIVE,
                    initialLayout = .UNDEFINED,
                }, nil, &depth_texture)
                assert(result == .SUCCESS)

                vk.GetImageMemoryRequirements(device, depth_texture, &depth_texture_memory_requirements)
                if depth_texture_memory_requirements.size > gpu_screen_allocation.size {
                    destroy_allocation(device, &gpu_screen_allocation)

                    gpu_screen_allocation_residents = {
                        {
                            handle = depth_texture,
                            is_image = true,
                        }
                    }
                    
                    gpu_screen_allocation, gpu_screen_allocation_result = allocate_for_resources(device, physical_device, gpu_screen_allocation_residents, { .DEVICE_LOCAL }, minimum_size = 3 * depth_texture_memory_requirements.size / 2)
                    assert(gpu_screen_allocation_result == .SUCCESS)
                    assert(bind_resources_to_allocation(device, &gpu_screen_allocation) == .SUCCESS)
                } else {
                    replace_resource_in_allocation(device, &gpu_screen_allocation, gpu_screen_allocation_residents[0], {
                        handle = depth_texture,
                        is_image = true,
                    })
                }
                
                result = vk.CreateImageView(device, &{
                    sType = .IMAGE_VIEW_CREATE_INFO,
                    image = depth_texture,
                    viewType = .D2,
                    format = .D16_UNORM,
                    components = {
                        r = .IDENTITY,
                        g = .IDENTITY,
                        b = .IDENTITY,
                        a = .IDENTITY,
                    },
                    subresourceRange = {
                        aspectMask = { .DEPTH },
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1,
                    }
                }, nil, &depth_texture_view)
                assert(result == .SUCCESS)
                continue
            } else if result != .SUCCESS && result != .SUBOPTIMAL_KHR {
                fmt.panicf("Failed to acquire swapchain image: %s", result)
            }

            vk.ResetFences(device, 1, &in_flight_fence)

            audio_pipeline_descriptor_buffer_infos := make([]vk.DescriptorBufferInfo, len(input_track_allocation.residents))
            defer delete(audio_pipeline_descriptor_buffer_infos)

            it_index := u32(0)
            for id in input_track_order {
                audio_pipeline_descriptor_buffer_infos[it_index] = {
                    buffer = id.handle.(vk.Buffer),
                    offset = 0,
                    range = input_track_allocation.residents[id].size,
                }

                it_index += 1
            }

            audio_pipeline_write_descriptor_sets := [?]vk.WriteDescriptorSet {
                {
                    sType = .WRITE_DESCRIPTOR_SET,
                    dstSet = audio_pipeline_descriptor_set,
                    dstBinding = 0,
                    dstArrayElement = 0,
                    descriptorCount = 1,
                    descriptorType = .STORAGE_BUFFER,
                    pBufferInfo = &{
                        buffer = audio_cpu.rendered_buffer,
                        offset = 0,
                        range = audio_cpu.allocation.residents[{
                            handle = audio_cpu.rendered_buffer,
                            is_image = false,
                        }].size,
                    },
                },
                {
                    sType = .WRITE_DESCRIPTOR_SET,
                    dstSet = audio_pipeline_descriptor_set,
                    dstBinding = 1,
                    dstArrayElement = 0,
                    descriptorCount = 1,
                    descriptorType = .UNIFORM_BUFFER,
                    pBufferInfo = &{
                        buffer = audio_cpu.uniform_buffer,
                        offset = 0,
                        range = audio_cpu.allocation.residents[{
                            handle = audio_cpu.uniform_buffer,
                            is_image = false,
                        }].size,
                    },
                },
                {
                    sType = .WRITE_DESCRIPTOR_SET,
                    dstSet = audio_pipeline_descriptor_set,
                    dstBinding = 2,
                    dstArrayElement = 0,
                    descriptorCount = 1,
                    descriptorType = .STORAGE_IMAGE,
                    pImageInfo = &{
                        sampler = 0,
                        imageView = swapchain_image_views[image_index],
                        imageLayout = .GENERAL,
                    },
                },
                {
                    sType = .WRITE_DESCRIPTOR_SET,
                    dstSet = audio_pipeline_descriptor_set,
                    dstBinding = 3,
                    dstArrayElement = 0,
                    descriptorCount = u32(len(audio_pipeline_descriptor_buffer_infos)),
                    descriptorType = .STORAGE_BUFFER,
                    pBufferInfo = &audio_pipeline_descriptor_buffer_infos[0],
                },
            }

            vk.UpdateDescriptorSets(device,
                u32(len(audio_pipeline_write_descriptor_sets)), &audio_pipeline_write_descriptor_sets[0],
                0, nil
            )

            index := (audio_cpu.uniform_buffer_mapped.seek * 2) % (u32(len(audio_cpu.local_buffer)))
            intrinsics.mem_copy_non_overlapping(&audio_cpu.local_buffer[index], audio_cpu.rendered_buffer_mapped, min(AUDIO_RENDER_BUFFER_SIZE, (u32(len(audio_cpu.local_buffer)) - index) * AUDIO_OUTPUT_SAMPLE_FORMAT_SIZE))

            audio_cpu.uniform_buffer_mapped.dispatch_dimensions[0] = AUDIO_RENDER_BUFFER_SIZE / 32 / 32 / 2
            audio_cpu.uniform_buffer_mapped.dispatch_dimensions[1] = 1
            audio_cpu.uniform_buffer_mapped.dispatch_dimensions[2] = 1

            assert(vk.ResetCommandPool(device, command_pool, {}) == .SUCCESS)
            assert(vk.BeginCommandBuffer(command_buffer, &{
                sType = .COMMAND_BUFFER_BEGIN_INFO,
                flags = { .ONE_TIME_SUBMIT },
            }) == .SUCCESS)

            vk.CmdPipelineBarrier(command_buffer,
                { .HOST }, { .COMPUTE_SHADER }, {},
                0, nil,
                1, &vk.BufferMemoryBarrier {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = { .HOST_READ },
                    dstAccessMask = { .SHADER_WRITE },
                    buffer = audio_cpu.rendered_buffer,
                    offset = 0,
                    size = audio_cpu.allocation.residents[{
                        handle = audio_cpu.rendered_buffer,
                        is_image = false,
                    }].size,
                },
                0, nil
            )

            vk.CmdPipelineBarrier(command_buffer,
                { .TRANSFER }, { .COMPUTE_SHADER }, {},
                0, nil,
                0, nil,
                1, &vk.ImageMemoryBarrier {
                    sType = .IMAGE_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = { .SHADER_WRITE },
                    oldLayout = .UNDEFINED,
                    newLayout = .GENERAL,
                    image = swapchain_images[image_index],
                    subresourceRange = {
                        aspectMask = { .COLOR },
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1,
                    }
                }
            )

            /*
            vk.CmdPipelineBarrier(command_buffer,
                { .BOTTOM_OF_PIPE }, { .EARLY_FRAGMENT_TESTS }, {},
                0, nil,
                0, nil,
                1, &vk.ImageMemoryBarrier {
                    sType = .IMAGE_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = { .DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE },
                    oldLayout = .UNDEFINED,
                    newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    image = depth_texture,
                    subresourceRange = {
                        aspectMask = { .DEPTH },
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1,
                    }
                }
            )

            vk.CmdPipelineBarrier(command_buffer,
                { .BOTTOM_OF_PIPE }, { .FRAGMENT_SHADER }, {},
                0, nil,
                0, nil,
                1, &vk.ImageMemoryBarrier {
                    sType = .IMAGE_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = { .SHADER_READ },
                    oldLayout = .UNDEFINED,
                    newLayout = .SHADER_READ_ONLY_OPTIMAL,
                    image = voxel_texture,
                    subresourceRange = {
                        aspectMask = { .COLOR },
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1,
                    }
                }
            )

            vk.CmdBeginRenderingKHR(command_buffer, &{
                sType = .RENDERING_INFO_KHR,
                renderArea = {
                    offset = {
                        x = 0,
                        y = 0,
                    },
                    extent = {
                        width = surface_capabilities.currentExtent.width,
                        height = surface_capabilities.currentExtent.height,
                    },
                },
                layerCount = 1,
                colorAttachmentCount = 1,
                pColorAttachments = &vk.RenderingAttachmentInfoKHR {
                    sType = .RENDERING_ATTACHMENT_INFO_KHR,
                    imageView = swapchain_image_views[image_index],
                    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
                    loadOp = .CLEAR,
                    storeOp = .STORE,
                    clearValue = {
                        color = {
                            float32 = { 0.3, 0.0, 0.0, 1.0 },
                        }
                    }
                },
                pDepthAttachment = &vk.RenderingAttachmentInfoKHR {
                    sType = .RENDERING_ATTACHMENT_INFO_KHR,
                    imageView = depth_texture_view,
                    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    loadOp = .CLEAR,
                    storeOp = .DONT_CARE,
                    clearValue = {
                        depthStencil = {
                            depth = 1.0,
                        }
                    }
                },
            })

            vk.CmdSetViewport(command_buffer, 0, 1, &vk.Viewport {
                x = 0,
                y = f32(surface_capabilities.currentExtent.height),
                width = f32(surface_capabilities.currentExtent.width),
                height = -f32(surface_capabilities.currentExtent.height),
                minDepth = 0.0,
                maxDepth = 1.0,
            })

            vk.CmdSetScissor(command_buffer, 0, 1, &vk.Rect2D {
                offset = {
                    x = 0,
                    y = 0,
                },
                extent = surface_capabilities.currentExtent,
            })

            vk.CmdBindPipeline(command_buffer, .GRAPHICS, graphics_pipeline)
            vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, graphics_pipeline_layout, 0, 1, &graphics_pipeline_descriptor_set, 0, nil)

            vertex_offset := vk.DeviceSize(0)
            vk.CmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffer, &vertex_offset)
            vk.CmdBindIndexBuffer(command_buffer, index_buffer, 0, .UINT32)
            vk.CmdDrawIndexed(command_buffer, u32(len(index_data)), 1, 0, 0, 0)

            vk.CmdDraw(command_buffer, 6, 1, 0, 0)

            vk.CmdEndRenderingKHR(command_buffer)
            */

            vk.CmdClearColorImage(command_buffer,
                swapchain_images[image_index], .GENERAL,
                &vk.ClearColorValue {
                    uint32 = { 0, 0, 0, 1 },
                },
                1, &vk.ImageSubresourceRange {
                    aspectMask = { .COLOR },
                    baseMipLevel = 0,
                    levelCount = 1,
                    baseArrayLayer = 0,
                    layerCount = 1,
                },
            )

            vk.CmdBindPipeline(command_buffer, .COMPUTE, audio_pipeline)
            vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, audio_pipeline_layout, 0, 1, &audio_pipeline_descriptor_set, 0, nil)
            vk.CmdDispatch(command_buffer,
                audio_cpu.uniform_buffer_mapped.dispatch_dimensions[0],
                audio_cpu.uniform_buffer_mapped.dispatch_dimensions[1],
                audio_cpu.uniform_buffer_mapped.dispatch_dimensions[2]
            )

            vk.CmdPipelineBarrier(command_buffer,
                { .COMPUTE_SHADER }, { .TRANSFER }, {},
                0, nil,
                0, nil,
                1, &vk.ImageMemoryBarrier {
                    sType = .IMAGE_MEMORY_BARRIER,
                    srcAccessMask = { .SHADER_WRITE },
                    dstAccessMask = {},
                    oldLayout = .GENERAL,
                    newLayout = .PRESENT_SRC_KHR,
                    image = swapchain_images[image_index],
                    subresourceRange = {
                        aspectMask = { .COLOR },
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1,
                    },
                }
            )

            vk.CmdPipelineBarrier(command_buffer,
                { .COMPUTE_SHADER }, { .HOST }, {},
                0, nil,
                1, &vk.BufferMemoryBarrier {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = { .SHADER_WRITE },
                    dstAccessMask = { .HOST_READ },
                    buffer = audio_cpu.rendered_buffer,
                    offset = 0,
                    size = audio_cpu.allocation.residents[{
                        handle = audio_cpu.rendered_buffer,
                        is_image = false,
                    }].size,
                },
                0, nil
            )

            assert(vk.EndCommandBuffer(command_buffer) == .SUCCESS)

            wait_stage := visuals_enabled ? vk.PipelineStageFlags { .TRANSFER } : vk.PipelineStageFlags { .COMPUTE_SHADER }
            assert(vk.QueueSubmit(queue, 1, &vk.SubmitInfo {
                sType = .SUBMIT_INFO,
                waitSemaphoreCount = visuals_enabled ? 1 : 0,
                pWaitSemaphores = visuals_enabled ? &image_acquisition_semaphore : nil,
                commandBufferCount = 1,
                pCommandBuffers = &command_buffer,
                signalSemaphoreCount = visuals_enabled ? 1 : 0,
                pSignalSemaphores = visuals_enabled ? &swapchain_image_finished_semaphores[image_index] : nil,
                pWaitDstStageMask = &wait_stage,
            }, in_flight_fence) == .SUCCESS)

            if visuals_enabled {
                present_results: vk.Result
                result = vk.QueuePresentKHR(queue, &{
                    sType = .PRESENT_INFO_KHR,
                    waitSemaphoreCount = 1,
                    pWaitSemaphores = &swapchain_image_finished_semaphores[image_index],
                    swapchainCount = 1,
                    pSwapchains = &swapchain,
                    pImageIndices = &image_index,
                    pResults = &present_results,
                })
            }

            if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
                assert(vk.DeviceWaitIdle(device) == .SUCCESS)
                surface_capabilities, swapchain_enabled = resize_swapchain(device, physical_device, surface, &swapchain, &swapchain_image_count, &swapchain_images, &swapchain_image_views, &swapchain_image_finished_semaphores)

                vk.DestroyImageView(device, depth_texture_view, nil)
                vk.DestroyImage(device, depth_texture, nil)

                result = vk.CreateImage(device, &{
                    sType = .IMAGE_CREATE_INFO,
                    imageType = .D2,
                    format = .D16_UNORM,
                    extent = {
                        width = surface_capabilities.currentExtent.width,
                        height = surface_capabilities.currentExtent.height,
                        depth = 1,
                    },
                    mipLevels = 1,
                    arrayLayers = 1,
                    samples = { ._1 },
                    tiling = .OPTIMAL,
                    usage = { .DEPTH_STENCIL_ATTACHMENT },
                    sharingMode = .EXCLUSIVE,
                    initialLayout = .UNDEFINED,
                }, nil, &depth_texture)
                assert(result == .SUCCESS)

                vk.GetImageMemoryRequirements(device, depth_texture, &depth_texture_memory_requirements)
                if depth_texture_memory_requirements.size > gpu_screen_allocation.size {
                    destroy_allocation(device, &gpu_screen_allocation)

                    gpu_screen_allocation_residents = {
                        {
                            handle = depth_texture,
                            is_image = true,
                        }
                    }
                    
                    gpu_screen_allocation, gpu_screen_allocation_result = allocate_for_resources(device, physical_device, gpu_screen_allocation_residents, { .DEVICE_LOCAL }, minimum_size = 3 * depth_texture_memory_requirements.size / 2)
                    assert(gpu_screen_allocation_result == .SUCCESS)
                    assert(bind_resources_to_allocation(device, &gpu_screen_allocation) == .SUCCESS)
                } else {
                    replace_resource_in_allocation(device, &gpu_screen_allocation, gpu_screen_allocation_residents[0], {
                        handle = depth_texture,
                        is_image = true,
                    })
                }
                
                result = vk.CreateImageView(device, &{
                    sType = .IMAGE_VIEW_CREATE_INFO,
                    image = depth_texture,
                    viewType = .D2,
                    format = .D16_UNORM,
                    components = {
                        r = .IDENTITY,
                        g = .IDENTITY,
                        b = .IDENTITY,
                        a = .IDENTITY,
                    },
                    subresourceRange = {
                        aspectMask = { .DEPTH },
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1,
                    }
                }, nil, &depth_texture_view)
                assert(result == .SUCCESS)
            } else if result != .SUCCESS {
                fmt.panicf("Failed to present: %s", result)
            }
        }
    }

    assert(vk.DeviceWaitIdle(device) == .SUCCESS)
}
