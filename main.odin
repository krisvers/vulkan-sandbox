package main

import "base:runtime"
import "base:intrinsics"
import "core:fmt"
import vk "vendor:vulkan"
import "vendor:sdl3"
import "vendor:directx/dxc"
import "core:c"
import "core:strings"
import "core:unicode/utf16"

when ODIN_OS == .Darwin {
    @(export)
    foreign import moltenvk "MoltenVK"
}

resize_swapchain :: proc(  
    vk_device: vk.Device,
    vk_physical_device: vk.PhysicalDevice,
    vk_surface: vk.SurfaceKHR,
    vk_swapchain: ^vk.SwapchainKHR,
    vk_swapchain_image_count: ^u32,
    vk_swapchain_images: ^[dynamic]vk.Image,
    vk_swapchain_image_views: ^[dynamic]vk.ImageView,
    vk_swapchain_image_finished_semaphores: ^[dynamic]vk.Semaphore
) -> (vk.SurfaceCapabilitiesKHR, bool) {
    assert(vk.DeviceWaitIdle(vk_device) == .SUCCESS)
    vk_surface_capabilites := vk.SurfaceCapabilitiesKHR {}
    assert(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vk_physical_device, vk_surface, &vk_surface_capabilites) == .SUCCESS)

    if vk_surface_capabilites.currentExtent.width == 0 || vk_surface_capabilites.currentExtent.height == 0 {
        return vk_surface_capabilites, false
    }

    vk_old_swapchain := vk_swapchain^
    vk_result := vk.CreateSwapchainKHR(vk_device, &{
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = vk_surface,
        minImageCount = 3,
        imageFormat = .B8G8R8A8_UNORM,
        imageColorSpace = .SRGB_NONLINEAR,
        imageExtent = vk_surface_capabilites.currentExtent,
        imageArrayLayers = 1,
        imageUsage = { .COLOR_ATTACHMENT },
        imageSharingMode = .EXCLUSIVE,
        preTransform = { .IDENTITY },
        compositeAlpha = { .OPAQUE },
        presentMode = .FIFO,
        oldSwapchain = vk_old_swapchain,
    }, nil, vk_swapchain)
    assert(vk_result == .SUCCESS)
    vk.DestroySwapchainKHR(vk_device, vk_old_swapchain, nil)

    for iv in vk_swapchain_image_views {
        vk.DestroyImageView(vk_device, iv, nil)
    }

    vk_old_swapchain_image_count := vk_swapchain_image_count^
    assert(vk.GetSwapchainImagesKHR(vk_device, vk_swapchain^, vk_swapchain_image_count, nil) == .SUCCESS)

    for i in vk_swapchain_image_count^..<vk_old_swapchain_image_count {
        vk.DestroySemaphore(vk_device, vk_swapchain_image_finished_semaphores^[i], nil)
    }

    resize(vk_swapchain_images, vk_swapchain_image_count^)
    assert(vk.GetSwapchainImagesKHR(vk_device, vk_swapchain^, vk_swapchain_image_count, &(vk_swapchain_images^[0])) == .SUCCESS)

    resize(vk_swapchain_image_views, vk_swapchain_image_count^)
    resize(vk_swapchain_image_finished_semaphores, vk_swapchain_image_count^)
    
    for i in 0..<vk_swapchain_image_count^ {
        assert(vk.CreateImageView(vk_device, &{
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = vk_swapchain_images^[i],
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
        }, nil, &(vk_swapchain_image_views^[i])) == .SUCCESS)
    
        if i >= vk_old_swapchain_image_count {
            assert(vk.CreateSemaphore(vk_device, &{
                sType = .SEMAPHORE_CREATE_INFO,
            }, nil, &(vk_swapchain_image_finished_semaphores^[i])) == .SUCCESS)
        }
    }

    return vk_surface_capabilites, true
}

find_memory_type_index_single :: proc(
    vk_physical_device: vk.PhysicalDevice,
    vk_memory_type_bits: u32,
    vk_memory_properties: vk.MemoryPropertyFlags
) -> u32 {
    vk_physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(vk_physical_device, &vk_physical_device_memory_properties)

    for i in 0..<vk_physical_device_memory_properties.memoryTypeCount {
        if (vk_memory_type_bits & (1 << i)) != 0 && (vk_physical_device_memory_properties.memoryTypes[i].propertyFlags & vk_memory_properties) == vk_memory_properties {
            return i
        }
    }

    return vk.MAX_MEMORY_TYPES
}

find_memory_type_index_multiple :: proc(
    vk_physical_device: vk.PhysicalDevice,
    vk_memory_requirementses: []vk.MemoryRequirements,
    vk_memory_properties: vk.MemoryPropertyFlags
) -> u32 {
    vk_physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(vk_physical_device, &vk_physical_device_memory_properties)

    for i in 0..<vk_physical_device_memory_properties.memoryTypeCount {
        if (vk_physical_device_memory_properties.memoryTypes[i].propertyFlags & vk_memory_properties) != vk_memory_properties {
            continue
        }

        incompatible := false
        for r in vk_memory_requirementses {
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

allocate_for_resources :: proc(
    vk_device: vk.Device,
    vk_physical_device: vk.PhysicalDevice,
    vk_images: []vk.Image,
    vk_buffers: []vk.Buffer,
    vk_memory_properties: vk.MemoryPropertyFlags
) -> (memory: vk.DeviceMemory, sizes: []vk.DeviceSize, offsets: []vk.DeviceSize, result: vk.Result) {
    vk_memory_type_index: u32
    vk_memory_requirementses := make([]vk.MemoryRequirements, len(vk_images) + len(vk_buffers))
    sizes = make([]vk.DeviceSize, len(vk_images) + len(vk_buffers))
    offsets = make([]vk.DeviceSize, len(vk_images) + len(vk_buffers))
    defer delete(vk_memory_requirementses)

    total_size: vk.DeviceSize
    for i in 0..<len(vk_images) {
        vk.GetImageMemoryRequirements(vk_device, vk_images[i], &vk_memory_requirementses[i])

        r := total_size % vk_memory_requirementses[i].alignment
        total_size = total_size + (r == 0 ? 0 : vk_memory_requirementses[i].alignment - r)
        offsets[i] = total_size
        sizes[i] = vk_memory_requirementses[i].size
        total_size += sizes[i]
    }

    for i in 0..<len(vk_buffers) {
        vk.GetBufferMemoryRequirements(vk_device, vk_buffers[i], &vk_memory_requirementses[i + len(vk_images)])
        
        r := total_size % vk_memory_requirementses[i + len(vk_images)].alignment
        total_size = total_size + (r == 0 ? 0 : vk_memory_requirementses[i + len(vk_images)].alignment - r)
        offsets[i + len(vk_images)] = total_size
        sizes[i + len(vk_images)] = vk_memory_requirementses[i + len(vk_images)].size
        total_size += sizes[i + len(vk_images)]
    }

    vk_memory_type_index = find_memory_type_index(vk_physical_device, vk_memory_requirementses, vk_memory_properties)
    if vk_memory_type_index == vk.MAX_MEMORY_TYPES {
        delete(sizes)
        delete(offsets)
        return 0, {}, {}, .ERROR_UNKNOWN
    }

    result = vk.AllocateMemory(vk_device, &{
        sType = .MEMORY_ALLOCATE_INFO,
        allocationSize = total_size,
        memoryTypeIndex = vk_memory_type_index,
    }, nil, &memory)

    if result != .SUCCESS {
        delete(sizes)
        delete(offsets)
        return 0, {}, {}, result
    }

    return
}

bind_resources_to_allocation :: proc(
    vk_device: vk.Device,
    vk_memory: vk.DeviceMemory,
    vk_images: []vk.Image,
    vk_buffers: []vk.Buffer,
    offsets: []vk.DeviceSize
) -> (result := vk.Result.SUCCESS) {
    for i in 0..<len(vk_images) {
        r := vk.BindImageMemory(vk_device, vk_images[i], vk_memory, offsets[i])
        if r != .SUCCESS {
            result = r
        }
    }

    for i in 0..<len(vk_buffers) {
        r := vk.BindBufferMemory(vk_device, vk_buffers[i], vk_memory, offsets[i + len(vk_images)])
        if r != .SUCCESS {
            result = r
        }
    }

    return
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
    vk_device: vk.Device,
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

    result = vk.CreateShaderModule(vk_device, &{
        sType = .SHADER_MODULE_CREATE_INFO,
        codeSize = spirv_size,
        pCode = spirv_code
    }, nil, &module)

    if result != .SUCCESS {
        return 0, result
    }

    return module, .SUCCESS
}

main :: proc() {
    assert(sdl3.Init({ .VIDEO }))
    assert(sdl3.Vulkan_LoadLibrary(nil))

    dxc_utils: ^dxc.IUtils
    assert(dxc.CreateInstance(dxc.Utils_CLSID, dxc.IUtils_UUID, &dxc_utils) == 0)
    defer dxc_utils->Release()

    dxc_compiler: ^dxc.ICompiler
    assert(dxc.CreateInstance(dxc.Compiler_CLSID, dxc.ICompiler_UUID, &dxc_compiler) == 0)
    defer dxc_compiler->Release()

    sdl_vk_proc_addr := sdl3.Vulkan_GetVkGetInstanceProcAddr()
    assert(sdl_vk_proc_addr != nil)

    vk.load_proc_addresses_global(rawptr(sdl_vk_proc_addr))
    assert(vk.CreateInstance != nil)

    sdl_extension_count: u32
    sdl_extensions := sdl3.Vulkan_GetInstanceExtensions(&sdl_extension_count)
    assert(sdl_extensions != nil)

    vk_available_instance_extension_count: u32
    assert(vk.EnumerateInstanceExtensionProperties(nil, &vk_available_instance_extension_count, nil) == .SUCCESS)

    vk_available_instance_extensions := []vk.ExtensionProperties {}
    if vk_available_instance_extension_count > 0 {
        vk_available_instance_extensions = make([]vk.ExtensionProperties, vk_available_instance_extension_count)
        assert(vk.EnumerateInstanceExtensionProperties(nil, &vk_available_instance_extension_count, &vk_available_instance_extensions[0]) == .SUCCESS)
    }

    vk_instance_extensions := make([dynamic]cstring, 0, sdl_extension_count + 1)
    for i in 0..<sdl_extension_count {
        append(&vk_instance_extensions, sdl_extensions[i])
    }

    append(&vk_instance_extensions, "VK_EXT_debug_utils")

    vk_instance_flags := vk.InstanceCreateFlags {}
    when ODIN_OS == .Darwin {
        vk_instance_flags |= { .ENUMERATE_PORTABILITY_KHR }
    }

    vk_instance_layers := make([dynamic]cstring, 0, 1)
    when ODIN_DEBUG {
        append(&vk_instance_layers, "VK_LAYER_KHRONOS_validation")
    }

    vk_instance: vk.Instance
    vk_result := vk.CreateInstance(&{
        sType = .INSTANCE_CREATE_INFO,
        flags = vk_instance_flags,
        pApplicationInfo = &{
            pApplicationName = "vulkan",
            applicationVersion = vk.MAKE_VERSION(1, 0, 0),
            pEngineName = "vulkan",
            engineVersion = vk.MAKE_VERSION(1, 0, 0),
            apiVersion = vk.API_VERSION_1_2,
        },
        enabledLayerCount = u32(len(vk_instance_layers)),
        ppEnabledLayerNames = len(vk_instance_layers) == 0 ? nil : &vk_instance_layers[0],
        enabledExtensionCount = u32(len(vk_instance_extensions)),
        ppEnabledExtensionNames = &vk_instance_extensions[0]
    }, nil, &vk_instance)
    delete(vk_instance_extensions)
    delete(vk_available_instance_extensions)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyInstance(vk_instance, nil)

    vk.load_proc_addresses_instance(vk_instance)
    
    vk_debug_utils_messenger: vk.DebugUtilsMessengerEXT
    vk_result = vk.CreateDebugUtilsMessengerEXT(vk_instance, &{
        sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        messageSeverity = { .ERROR, .WARNING },
        messageType = { .GENERAL, .VALIDATION, .PERFORMANCE },
        pfnUserCallback = proc "system" (message_severity: vk.DebugUtilsMessageSeverityFlagsEXT, message_type: vk.DebugUtilsMessageTypeFlagsEXT, p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT, userdata: rawptr) -> b32 {
            context = runtime.default_context()
            fmt.println(message_severity, message_type, p_callback_data.pMessage)
            return false
        },
        pUserData = nil
    }, nil, &vk_debug_utils_messenger)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyDebugUtilsMessengerEXT(vk_instance, vk_debug_utils_messenger, nil)

    window := sdl3.CreateWindow("voxels", 1200, 900, { .VULKAN, .RESIZABLE })
    assert(window != nil)
    defer sdl3.DestroyWindow(window)

    vk_surface: vk.SurfaceKHR
    assert(sdl3.Vulkan_CreateSurface(window, vk_instance, nil, &vk_surface))
    defer sdl3.Vulkan_DestroySurface(vk_instance, vk_surface, nil)

    vk_physical_device_count: u32
    assert(vk.EnumeratePhysicalDevices(vk_instance, &vk_physical_device_count, nil) == .SUCCESS)

    vk_physical_devices := make([]vk.PhysicalDevice, vk_physical_device_count)
    assert(vk.EnumeratePhysicalDevices(vk_instance, &vk_physical_device_count, &vk_physical_devices[0]) == .SUCCESS)

    vk_physical_device := vk_physical_devices[0]
    delete(vk_physical_devices)

    vk_available_device_extension_count: u32
    assert(vk.EnumerateDeviceExtensionProperties(vk_physical_device, nil, &vk_available_device_extension_count, nil) == .SUCCESS)

    vk_available_device_extensions := make([]vk.ExtensionProperties, vk_available_device_extension_count)
    assert(vk.EnumerateDeviceExtensionProperties(vk_physical_device, nil, &vk_available_device_extension_count, &vk_available_device_extensions[0]) == .SUCCESS)
    
    vk_device_extensions := make([dynamic]cstring, 2, 8)
    vk_device_extensions[0] = "VK_KHR_swapchain"
    vk_device_extensions[1] = "VK_KHR_dynamic_rendering"

    vk_pnext := rawptr(nil)

    found_vk_ext_memory_priority := false
    found_vk_ext_pageable_device_local_memory := false
    found_vk_khr_dynamic_rendering := false

    vk_pageable_device_local_memory_features := vk.PhysicalDevicePageableDeviceLocalMemoryFeaturesEXT {
        sType = .PHYSICAL_DEVICE_PAGEABLE_DEVICE_LOCAL_MEMORY_FEATURES_EXT,
        pageableDeviceLocalMemory = true,
    }

    vk_memory_priority_features := vk.PhysicalDeviceMemoryPriorityFeaturesEXT {
        sType = .PHYSICAL_DEVICE_MEMORY_PRIORITY_FEATURES_EXT,
        memoryPriority = true,
    }

    vk_dynamic_rendering_features := vk.PhysicalDeviceDynamicRenderingFeaturesKHR {
        sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
        dynamicRendering = true,
    }

    for &p in vk_available_device_extensions {
        if cstring(&p.extensionName[0]) == "VK_EXT_pageable_device_local_memory" {
            found_vk_ext_pageable_device_local_memory = true
        } else if cstring(&p.extensionName[0]) == "VK_EXT_memory_priority" {
            found_vk_ext_memory_priority = true
        } else if cstring(&p.extensionName[0]) == "VK_KHR_dynamic_rendering" {
            found_vk_khr_dynamic_rendering = true
        }
    }

    if found_vk_ext_memory_priority && found_vk_ext_pageable_device_local_memory {
        append(&vk_device_extensions, "VK_EXT_memory_priority")
        vk_memory_priority_features.pNext = vk_pnext

        append(&vk_device_extensions, "VK_EXT_pageable_device_local_memory")
        vk_pageable_device_local_memory_features.pNext = &vk_memory_priority_features
        vk_pnext = &vk_pageable_device_local_memory_features
    }

    if found_vk_khr_dynamic_rendering {
        append(&vk_device_extensions, "VK_KHR_dynamic_rendering")
        vk_dynamic_rendering_features.pNext = vk_pnext
        vk_pnext = &vk_dynamic_rendering_features
    }

    when ODIN_OS == .Darwin {
        append(&vk_device_extensions, "VK_KHR_portability_subset")
    }

    queue_priority := f32(1.0)

    vk_available_physical_device_features, vk_physical_device_features := vk.PhysicalDeviceFeatures {}, vk.PhysicalDeviceFeatures {}
    vk.GetPhysicalDeviceFeatures(vk_physical_device, &vk_available_physical_device_features)

    vk_device: vk.Device
    vk_result = vk.CreateDevice(vk_physical_device, &{
        sType = .DEVICE_CREATE_INFO,
        pNext = vk_pnext,
        queueCreateInfoCount = 1,
        pQueueCreateInfos = &vk.DeviceQueueCreateInfo {
            sType = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = 0,
            queueCount = 1,
            pQueuePriorities = &queue_priority,
        },
        enabledExtensionCount = u32(len(vk_device_extensions)),
        ppEnabledExtensionNames = &vk_device_extensions[0],
        pEnabledFeatures = &vk_physical_device_features,
    }, nil, &vk_device)
    delete(vk_device_extensions)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyDevice(vk_device, nil)

    vk_queue: vk.Queue
    vk.GetDeviceQueue(vk_device, 0, 0, &vk_queue)
    
    vk_command_pool: vk.CommandPool
    vk_result = vk.CreateCommandPool(vk_device, &{
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = {},
        queueFamilyIndex = 0,
    }, nil, &vk_command_pool)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyCommandPool(vk_device, vk_command_pool, nil)

    vk_command_buffer: vk.CommandBuffer
    vk_result = vk.AllocateCommandBuffers(vk_device, &{
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = vk_command_pool,
        level = .PRIMARY,
        commandBufferCount = 1,
    }, &vk_command_buffer)
    assert(vk_result == .SUCCESS)
    defer vk.FreeCommandBuffers(vk_device, vk_command_pool, 1, &vk_command_buffer)

    vk_surface_capabilities: vk.SurfaceCapabilitiesKHR
    assert(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vk_physical_device, vk_surface, &vk_surface_capabilities) == .SUCCESS)

    vk_swapchain: vk.SwapchainKHR
    vk_result = vk.CreateSwapchainKHR(vk_device, &{
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = vk_surface,
        minImageCount = 3,
        imageFormat = .B8G8R8A8_UNORM,
        imageColorSpace = .SRGB_NONLINEAR,
        imageExtent = vk_surface_capabilities.currentExtent,
        imageArrayLayers = 1,
        imageUsage = { .COLOR_ATTACHMENT },
        imageSharingMode = .EXCLUSIVE,
        preTransform = vk_surface_capabilities.currentTransform,
        compositeAlpha = { .OPAQUE },
        presentMode = .FIFO,
    }, nil, &vk_swapchain)
    assert(vk_result == .SUCCESS)
    defer vk.DestroySwapchainKHR(vk_device, vk_swapchain, nil)

    vk_swapchain_image_count: u32
    assert(vk.GetSwapchainImagesKHR(vk_device, vk_swapchain, &vk_swapchain_image_count, nil) == .SUCCESS)

    vk_swapchain_images := make([dynamic]vk.Image, vk_swapchain_image_count)
    assert(vk.GetSwapchainImagesKHR(vk_device, vk_swapchain, &vk_swapchain_image_count, &vk_swapchain_images[0]) == .SUCCESS)

    vk_swapchain_image_views := make([dynamic]vk.ImageView, vk_swapchain_image_count)
    vk_swapchain_image_finished_semaphores := make([dynamic]vk.Semaphore, vk_swapchain_image_count)
    for i in 0..<vk_swapchain_image_count {
        assert(vk.CreateImageView(vk_device, &{
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = vk_swapchain_images[i],
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
        }, nil, &vk_swapchain_image_views[i]) == .SUCCESS)

        assert(vk.CreateSemaphore(vk_device, &{
            sType = .SEMAPHORE_CREATE_INFO,
        }, nil, &vk_swapchain_image_finished_semaphores[i]) == .SUCCESS)
    }

    defer {
        for i in 0..<vk_swapchain_image_count {
            vk.DestroyImageView(vk_device, vk_swapchain_image_views[i], nil)
            vk.DestroySemaphore(vk_device, vk_swapchain_image_finished_semaphores[i], nil)
        }

        delete(vk_swapchain_image_views)
        delete(vk_swapchain_image_finished_semaphores)
    }
    
    vk_image_acquisition_semaphore: vk.Semaphore
    vk_result = vk.CreateSemaphore(vk_device, &{
        sType = .SEMAPHORE_CREATE_INFO,
    }, nil, &vk_image_acquisition_semaphore)
    assert(vk_result == .SUCCESS)
    defer vk.DestroySemaphore(vk_device, vk_image_acquisition_semaphore, nil)

    vk_in_flight_fence: vk.Fence
    vk_result = vk.CreateFence(vk_device, &{
        sType = .FENCE_CREATE_INFO,
        flags = { .SIGNALED },
    }, nil, &vk_in_flight_fence)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyFence(vk_device, vk_in_flight_fence, nil)

    vk_voxel_texture: vk.Image
    vk_result = vk.CreateImage(vk_device, &{
        sType = .IMAGE_CREATE_INFO,
        imageType = .D3,
        format = .R8_UINT,
        extent = {
            width = 4,
            height = 4,
            depth = 4,
        },
        mipLevels = 3,
        arrayLayers = 1,
        samples = { ._1 },
        tiling = .OPTIMAL,
        usage = { .STORAGE },
        sharingMode = .EXCLUSIVE,
        initialLayout = .UNDEFINED,
    }, nil, &vk_voxel_texture)
    assert(vk_result == .SUCCESS)

    vk_depth_texture: vk.Image
    vk_result = vk.CreateImage(vk_device, &{
        sType = .IMAGE_CREATE_INFO,
        imageType = .D2,
        format = .D16_UNORM,
        extent = {
            width = vk_surface_capabilities.currentExtent.width,
            height = vk_surface_capabilities.currentExtent.height,
            depth = 1,
        },
        mipLevels = 1,
        arrayLayers = 1,
        samples = { ._1 },
        tiling = .OPTIMAL,
        usage = { .DEPTH_STENCIL_ATTACHMENT },
        sharingMode = .EXCLUSIVE,
        initialLayout = .UNDEFINED
    }, nil, &vk_depth_texture)
    assert(vk_result == .SUCCESS)

    vertex_data := [24]f32 {
        0, 0, 0,
        0, 0, 1,
        0, 1, 0,
        0, 1, 1,
        1, 0, 0,
        1, 0, 1,
        1, 1, 0,
        1, 1, 1,
    }

    index_data := [36]u32 {
        0, 1, 2,
        1, 3, 2,
        5, 4, 7,
        4, 6, 7,
        4, 0, 6,
        0, 2, 6,
        1, 5, 3,
        5, 7, 3,
        2, 3, 6,
        3, 7, 6,
        4, 5, 0,
        5, 1, 0,
    }

    vk_vertex_index_buffer: vk.Buffer
    vk_result = vk.CreateBuffer(vk_device, &{
        sType = .BUFFER_CREATE_INFO,
        size = size_of(vertex_data) + size_of(index_data),
        usage = { .VERTEX_BUFFER, .INDEX_BUFFER, .TRANSFER_DST },
    }, nil, &vk_vertex_index_buffer)

    vk_gpu_memory, vk_gpu_memory_sizes, vk_gpu_memory_offsets, vk_gpu_allocation_result := allocate_for_resources(vk_device, vk_physical_device, { vk_voxel_texture, vk_depth_texture }, { vk_vertex_index_buffer }, { .DEVICE_LOCAL })
    assert(vk_gpu_allocation_result == .SUCCESS)
    defer {
        vk.DestroyBuffer(vk_device, vk_vertex_index_buffer, nil)
        vk.DestroyImage(vk_device, vk_depth_texture, nil)
        vk.DestroyImage(vk_device, vk_voxel_texture, nil)
        vk.FreeMemory(vk_device, vk_gpu_memory, nil)
    }

    vk_voxel_texture_size := vk_gpu_memory_sizes[0]
    vk_voxel_texture_offset := vk_gpu_memory_offsets[0]
    vk_depth_texture_size := vk_gpu_memory_sizes[1]
    vk_depth_texture_offset := vk_gpu_memory_offsets[1]
    vk_vertex_index_buffer_size := vk_gpu_memory_sizes[2]
    vk_vertex_index_buffer_offset := vk_gpu_memory_offsets[2]

    assert(bind_resources_to_allocation(vk_device, vk_gpu_memory, { vk_voxel_texture, vk_depth_texture }, { vk_vertex_index_buffer }, vk_gpu_memory_offsets) == .SUCCESS)
    delete(vk_gpu_memory_sizes)
    delete(vk_gpu_memory_offsets)

    vk_voxel_texture_view: vk.ImageView
    vk_result = vk.CreateImageView(vk_device, &{
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = vk_voxel_texture,
        viewType = .D3,
        format = .R8_UINT,
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
        }
    }, nil, &vk_voxel_texture_view)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyImageView(vk_device, vk_voxel_texture_view, nil)

    vk_depth_texture_view: vk.ImageView
    vk_result = vk.CreateImageView(vk_device, &{
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = vk_depth_texture,
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
    }, nil, &vk_depth_texture_view)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyImageView(vk_device, vk_depth_texture_view, nil)

    vk_upload_buffer: vk.Buffer
    vk_result = vk.CreateBuffer(vk_device, &{
        sType = .BUFFER_CREATE_INFO,
        size = size_of(vertex_data) + size_of(index_data),
        usage = { .TRANSFER_SRC },
    }, nil, &vk_upload_buffer)
    
    vk_upload_memory, vk_upload_memory_sizes, vk_upload_memory_offsets, vk_upload_allocation_result := allocate_for_resources(vk_device, vk_physical_device, {}, { vk_upload_buffer }, { .HOST_VISIBLE, .HOST_COHERENT })
    assert(vk_upload_allocation_result == .SUCCESS)
    defer {
        vk.DestroyBuffer(vk_device, vk_upload_buffer, nil)
        vk.FreeMemory(vk_device, vk_upload_memory, nil)
    }

    vk_upload_buffer_size := vk_upload_memory_sizes[0]
    vk_upload_buffer_offset := vk_upload_memory_offsets[0]

    assert(bind_resources_to_allocation(vk_device, vk_upload_memory, {}, { vk_upload_buffer }, vk_upload_memory_offsets) == .SUCCESS)
    delete(vk_upload_memory_sizes)
    delete(vk_upload_memory_offsets)

    vk_upload_buffer_mapped_rawptr: rawptr
    assert(vk.MapMemory(vk_device, vk_upload_memory, vk_upload_buffer_offset, vk_upload_buffer_size, {}, &vk_upload_buffer_mapped_rawptr) == .SUCCESS)

    vk_upload_buffer_mapped := ([^]u8)(vk_upload_buffer_mapped_rawptr)
    intrinsics.mem_copy_non_overlapping(&vk_upload_buffer_mapped[0], &vertex_data[0], size_of(vertex_data))
    intrinsics.mem_copy_non_overlapping(&vk_upload_buffer_mapped[size_of(vertex_data)], &index_data[0], size_of(index_data))

    vk.UnmapMemory(vk_device, vk_upload_memory)

    assert(vk.ResetCommandPool(vk_device, vk_command_pool, {}) == .SUCCESS)
    assert(vk.BeginCommandBuffer(vk_command_buffer, &{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
    }) == .SUCCESS)

    vk.CmdCopyBuffer(vk_command_buffer,
        vk_upload_buffer, vk_vertex_index_buffer,
        1, &vk.BufferCopy {
            srcOffset = 0,
            dstOffset = 0,
            size = vk_upload_buffer_size,
        }
    )

    assert(vk.EndCommandBuffer(vk_command_buffer) == .SUCCESS)
    assert(vk.QueueSubmit(vk_queue, 1, &vk.SubmitInfo {
        sType = .SUBMIT_INFO,
        waitSemaphoreCount = 0,
        pWaitSemaphores = nil,
        pWaitDstStageMask = nil,
        commandBufferCount = 1,
        pCommandBuffers = &vk_command_buffer,
        signalSemaphoreCount = 0,
        pSignalSemaphores = nil,
    }, 0) == .SUCCESS)

    assert(vk.QueueWaitIdle(vk_queue) == .SUCCESS)

    shader_source_hlsl := cstring(#load("shaders.hlsl"))
    vk_vertex_shader_module, vk_vertex_shader_compilation_result := compile_hlsl(vk_device, dxc_utils, dxc_compiler, shader_source_hlsl, "vertex_main", { .VERTEX })
    if vk_vertex_shader_compilation_result != .SUCCESS {
        fmt.panicf("Failed to compile vertex shader from shaders.hlsl: %s", vk_vertex_shader_compilation_result)
    }
    defer vk.DestroyShaderModule(vk_device, vk_vertex_shader_module, nil)

    vk_fragment_shader_module, vk_fragment_shader_compilation_result := compile_hlsl(vk_device, dxc_utils, dxc_compiler, shader_source_hlsl, "fragment_main", { .FRAGMENT })
    if vk_fragment_shader_compilation_result != .SUCCESS {
        fmt.panicf("Failed to compile fragment shader from shaders.hlsl: %s", vk_fragment_shader_compilation_result)
    }
    defer vk.DestroyShaderModule(vk_device, vk_fragment_shader_module, nil)

    vk_graphics_pipeline_descriptor_set_layout: vk.DescriptorSetLayout
    vk_result = vk.CreateDescriptorSetLayout(vk_device, &{
        sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = 1,
        pBindings = &vk.DescriptorSetLayoutBinding {
            binding = 0,
            descriptorType = .STORAGE_IMAGE,
            descriptorCount = 1,
            stageFlags = { .FRAGMENT },
        }
    }, nil, &vk_graphics_pipeline_descriptor_set_layout)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyDescriptorSetLayout(vk_device, vk_graphics_pipeline_descriptor_set_layout, nil)

    vk_graphics_pipeline_layout: vk.PipelineLayout
    vk_result = vk.CreatePipelineLayout(vk_device, &{
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        pSetLayouts = &vk_graphics_pipeline_descriptor_set_layout,
    }, nil, &vk_graphics_pipeline_layout)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyPipelineLayout(vk_device, vk_graphics_pipeline_layout, nil)

    vk_graphics_pipeline_shader_stages := [2]vk.PipelineShaderStageCreateInfo {
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = { .VERTEX },
            module = vk_vertex_shader_module,
            pName = "vertex_main",
        },
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = { .FRAGMENT },
            module = vk_fragment_shader_module,
            pName = "fragment_main",
        },
    }

    vk_graphics_pipeline_dynamic_states := [2]vk.DynamicState {
        .VIEWPORT,
        .SCISSOR,
    }

    vk_graphics_pipeline_color_attachment_formats := [1]vk.Format {
        .B8G8R8A8_UNORM,
    }

    vk_graphics_pipeline: vk.Pipeline
    vk_result = vk.CreateGraphicsPipelines(vk_device, 0, 1, &vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext = &vk.PipelineRenderingCreateInfoKHR {
            sType = .PIPELINE_RENDERING_CREATE_INFO_KHR,
            colorAttachmentCount = u32(len(vk_graphics_pipeline_color_attachment_formats)),
            pColorAttachmentFormats = &vk_graphics_pipeline_color_attachment_formats[0],
            depthAttachmentFormat = .D16_UNORM,
            stencilAttachmentFormat = .UNDEFINED,
        },
        stageCount = 2,
        pStages = &vk_graphics_pipeline_shader_stages[0],
        pVertexInputState = &{
            sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            vertexBindingDescriptionCount = 1,
            pVertexBindingDescriptions = &vk.VertexInputBindingDescription {
                binding = 0,
                stride = 3 * size_of(f32),
                inputRate = .VERTEX,
            },
            vertexAttributeDescriptionCount = 1,
            pVertexAttributeDescriptions = &vk.VertexInputAttributeDescription {
                location = 0,
                binding = 0,
                format = .R32G32B32_SFLOAT,
            },
        },
        pInputAssemblyState = &{
            sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            topology = .TRIANGLE_LIST,
        },
        pViewportState = &{
            sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            viewportCount = 1,
            scissorCount = 1,
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
            depthCompareOp = .LESS_OR_EQUAL,
            minDepthBounds = 0.0,
            maxDepthBounds = 1.0,
        },
        pColorBlendState = &{
            sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            attachmentCount = 1,
            pAttachments = &vk.PipelineColorBlendAttachmentState {
                blendEnable = false,
            },
            blendConstants = { 1.0, 1.0, 1.0, 1.0 },
        },
        pDynamicState = &{
            sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            dynamicStateCount = u32(len(vk_graphics_pipeline_dynamic_states)),
            pDynamicStates = &vk_graphics_pipeline_dynamic_states[0],
        },
        layout = vk_graphics_pipeline_layout,
        renderPass = 0,
    }, nil, &vk_graphics_pipeline)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyPipeline(vk_device, vk_graphics_pipeline, nil)

    vk_graphics_pipeline_descriptor_pool: vk.DescriptorPool
    vk_result = vk.CreateDescriptorPool(vk_device, &{
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        maxSets = 1,
        poolSizeCount = 1,
        pPoolSizes = &vk.DescriptorPoolSize {
            type = .STORAGE_IMAGE,
            descriptorCount = 1,
        },
    }, nil, &vk_graphics_pipeline_descriptor_pool)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyDescriptorPool(vk_device, vk_graphics_pipeline_descriptor_pool, nil)

    vk_graphics_pipeline_descriptor_set: vk.DescriptorSet
    vk_result = vk.AllocateDescriptorSets(vk_device, &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = vk_graphics_pipeline_descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &vk_graphics_pipeline_descriptor_set_layout,
    }, &vk_graphics_pipeline_descriptor_set)
    assert(vk_result == .SUCCESS)
    
    vk.UpdateDescriptorSets(vk_device, 1, &vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = vk_graphics_pipeline_descriptor_set,
        dstBinding = 0,
        dstArrayElement = 0,
        descriptorCount = 1,
        descriptorType = .STORAGE_IMAGE,
        pImageInfo = &{
            imageView = vk_voxel_texture_view,
            imageLayout = .GENERAL,
        },
    }, 0, nil)

    vk_swapchain_enabled := true
    main_loop: for true {
        event: sdl3.Event
        for sdl3.PollEvent(&event) {
            if event.type == .QUIT {
                break main_loop
            } else if event.type == .WINDOW_RESIZED {
                vk_surface_capabilities, vk_swapchain_enabled = resize_swapchain(vk_device, vk_physical_device, vk_surface, &vk_swapchain, &vk_swapchain_image_count, &vk_swapchain_images, &vk_swapchain_image_views, &vk_swapchain_image_finished_semaphores)
            }
        }

        if vk_swapchain_enabled {
            vk.WaitForFences(vk_device, 1, &vk_in_flight_fence, true, max(u64))

            vk_image_index: u32
            vk_result = vk.AcquireNextImageKHR(vk_device, vk_swapchain, max(u64), vk_image_acquisition_semaphore, 0, &vk_image_index)
            if vk_result == .ERROR_OUT_OF_DATE_KHR {
                vk_surface_capabilities, vk_swapchain_enabled = resize_swapchain(vk_device, vk_physical_device, vk_surface, &vk_swapchain, &vk_swapchain_image_count, &vk_swapchain_images, &vk_swapchain_image_views, &vk_swapchain_image_finished_semaphores)
                continue
            } else if vk_result != .SUCCESS && vk_result != .SUBOPTIMAL_KHR {
                fmt.panicf("Failed to acquire swapchain image: %s", vk_result)
            }

            vk.ResetFences(vk_device, 1, &vk_in_flight_fence)

            assert(vk.ResetCommandPool(vk_device, vk_command_pool, {}) == .SUCCESS)
            assert(vk.BeginCommandBuffer(vk_command_buffer, &{
                sType = .COMMAND_BUFFER_BEGIN_INFO,
                flags = { .ONE_TIME_SUBMIT },
            }) == .SUCCESS)

            vk.CmdPipelineBarrier(vk_command_buffer,
                { .TRANSFER }, { .COLOR_ATTACHMENT_OUTPUT }, {},
                0, nil,
                0, nil,
                1, &vk.ImageMemoryBarrier {
                    sType = .IMAGE_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = { .COLOR_ATTACHMENT_WRITE },
                    oldLayout = .UNDEFINED,
                    newLayout = .COLOR_ATTACHMENT_OPTIMAL,
                    image = vk_swapchain_images[vk_image_index],
                    subresourceRange = {
                        aspectMask = { .COLOR },
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1,
                    }
                }
            )

            vk.CmdPipelineBarrier(vk_command_buffer,
                { .BOTTOM_OF_PIPE }, { .EARLY_FRAGMENT_TESTS }, {},
                0, nil,
                0, nil,
                1, &vk.ImageMemoryBarrier {
                    sType = .IMAGE_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = { .DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE },
                    oldLayout = .UNDEFINED,
                    newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    image = vk_depth_texture,
                    subresourceRange = {
                        aspectMask = { .DEPTH },
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1,
                    }
                }
            )

            vk.CmdPipelineBarrier(vk_command_buffer,
                { .BOTTOM_OF_PIPE }, { .FRAGMENT_SHADER }, {},
                0, nil,
                0, nil,
                1, &vk.ImageMemoryBarrier {
                    sType = .IMAGE_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = { .SHADER_READ },
                    oldLayout = .UNDEFINED,
                    newLayout = .GENERAL,
                    image = vk_voxel_texture,
                    subresourceRange = {
                        aspectMask = { .COLOR },
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1,
                    }
                }
            )

            vk.CmdBeginRenderingKHR(vk_command_buffer, &{
                sType = .RENDERING_INFO_KHR,
                renderArea = {
                    offset = {
                        x = 0,
                        y = 0,
                    },
                    extent = {
                        width = vk_surface_capabilities.currentExtent.width,
                        height = vk_surface_capabilities.currentExtent.height,
                    },
                },
                layerCount = 1,
                viewMask = 0,
                colorAttachmentCount = 1,
                pColorAttachments = &vk.RenderingAttachmentInfoKHR {
                    sType = .RENDERING_ATTACHMENT_INFO_KHR,
                    imageView = vk_swapchain_image_views[vk_image_index],
                    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
                    loadOp = .CLEAR,
                    storeOp = .STORE,
                    clearValue = {
                        color = {
                            float32 = { 0.0, 0.3, 0.0, 1.0 },
                        }
                    }
                },
                pDepthAttachment = &vk.RenderingAttachmentInfoKHR {
                    sType = .RENDERING_ATTACHMENT_INFO_KHR,
                    imageView = vk_depth_texture_view,
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

            vk.CmdBindPipeline(vk_command_buffer, .GRAPHICS, vk_graphics_pipeline)
            vk.CmdBindDescriptorSets(vk_command_buffer, .GRAPHICS, vk_graphics_pipeline_layout, 0, 1, &vk_graphics_pipeline_descriptor_set, 0, nil)

            vk.CmdSetViewport(vk_command_buffer, 0, 1, &vk.Viewport {
                x = 0,
                y = 0,
                width = f32(vk_surface_capabilities.currentExtent.width),
                height = f32(vk_surface_capabilities.currentExtent.height),
                minDepth = 0.0,
                maxDepth = 1.0,
            })

            vk.CmdSetScissor(vk_command_buffer, 0, 1, &vk.Rect2D {
                offset = {
                    x = 0,
                    y = 0,
                },
                extent = vk_surface_capabilities.currentExtent,
            })

            vk_vertex_offset := vk.DeviceSize(0)
            vk.CmdBindVertexBuffers(vk_command_buffer, 0, 1, &vk_vertex_index_buffer, &vk_vertex_offset)
            vk.CmdBindIndexBuffer(vk_command_buffer, vk_vertex_index_buffer, vk.DeviceSize(len(index_data)), .UINT32)
            vk.CmdDrawIndexed(vk_command_buffer, u32(len(index_data)), 1, 0, 0, 0)

            vk.CmdEndRenderingKHR(vk_command_buffer)

            vk.CmdPipelineBarrier(vk_command_buffer,
                { .COLOR_ATTACHMENT_OUTPUT }, { .TRANSFER }, {},
                0, nil, 0, nil, 1, & vk.ImageMemoryBarrier {
                sType = .IMAGE_MEMORY_BARRIER,
                srcAccessMask = {},
                dstAccessMask = {},
                oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
                newLayout = .PRESENT_SRC_KHR,
                image = vk_swapchain_images[vk_image_index],
                subresourceRange = {
                    aspectMask = { .COLOR },
                    baseMipLevel = 0,
                    levelCount = 1,
                    baseArrayLayer = 0,
                    layerCount = 1,
                },
            })
            assert(vk.EndCommandBuffer(vk_command_buffer) == .SUCCESS)

            wait_stage := vk.PipelineStageFlags { .COLOR_ATTACHMENT_OUTPUT }
            assert(vk.QueueSubmit(vk_queue, 1, &vk.SubmitInfo {
                sType = .SUBMIT_INFO,
                waitSemaphoreCount = 1,
                pWaitSemaphores = &vk_image_acquisition_semaphore,
                commandBufferCount = 1,
                pCommandBuffers = &vk_command_buffer,
                signalSemaphoreCount = 1,
                pSignalSemaphores = &vk_swapchain_image_finished_semaphores[vk_image_index],
                pWaitDstStageMask = &wait_stage,
            }, vk_in_flight_fence) == .SUCCESS)

            vk_present_results: vk.Result
            vk_result = vk.QueuePresentKHR(vk_queue, &{
                sType = .PRESENT_INFO_KHR,
                waitSemaphoreCount = 1,
                pWaitSemaphores = &vk_swapchain_image_finished_semaphores[vk_image_index],
                swapchainCount = 1,
                pSwapchains = &vk_swapchain,
                pImageIndices = &vk_image_index,
                pResults = &vk_present_results,
            })

            if vk_result == .ERROR_OUT_OF_DATE_KHR || vk_result == .SUBOPTIMAL_KHR {
                vk_surface_capabilities, vk_swapchain_enabled = resize_swapchain(vk_device, vk_physical_device, vk_surface, &vk_swapchain, &vk_swapchain_image_count, &vk_swapchain_images, &vk_swapchain_image_views, &vk_swapchain_image_finished_semaphores)
            } else if vk_result != .SUCCESS {
                fmt.panicf("Failed to present: %s", vk_result)
            }
        }
    }

    assert(vk.DeviceWaitIdle(vk_device) == .SUCCESS)
}
