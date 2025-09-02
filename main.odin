package main

import "base:runtime"
import "core:fmt"
import vk "vendor:vulkan"
import "vendor:sdl3"
import "vendor:directx/dxc"

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

find_memory_type_index :: proc(
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
    defer {
        delete(vk_memory_requirementses)
    }

    total_size: vk.DeviceSize
    for i in 0..<len(vk_images) {
        vk.GetImageMemoryRequirements(vk_device, vk_images[i], &vk_memory_requirementses[i])
        ti := find_memory_type_index(vk_physical_device, vk_memory_requirementses[i].memoryTypeBits, vk_memory_properties)
        if ti == vk.MAX_MEMORY_TYPES {
            delete(sizes)
            delete(offsets)
            return 0, {}, {}, .ERROR_UNKNOWN
        } else if ti != vk_memory_type_index && i != 0 {
            delete(sizes)
            delete(offsets)
            return 0, {}, {}, .ERROR_FRAGMENTED_POOL
        }

        r := total_size % vk_memory_requirementses[i].alignment
        total_size = total_size + r == 0 ? 0 : vk_memory_requirementses[i].alignment - r
        offsets[i] = total_size
        sizes[i] = vk_memory_requirementses[i].size
        total_size += sizes[i]
    }

    for i in 0..<len(vk_buffers) {
        vk.GetBufferMemoryRequirements(vk_device, vk_buffers[i], &vk_memory_requirementses[i + len(vk_images)])
        ti := find_memory_type_index(vk_physical_device, vk_memory_requirementses[i + len(vk_images)].memoryTypeBits, vk_memory_properties)
        if ti == vk.MAX_MEMORY_TYPES {
            delete(sizes)
            delete(offsets)
            return 0, {}, {}, .ERROR_UNKNOWN
        } else if ti != vk_memory_type_index && i + len(vk_images) != 0 {
            delete(sizes)
            delete(offsets)
            return 0, {}, {}, .ERROR_FRAGMENTED_POOL
        }

        r := total_size % vk_memory_requirementses[i + len(vk_images)].alignment
        total_size = total_size + r == 0 ? 0 : vk_memory_requirementses[i + len(vk_images)].alignment - r
        offsets[i + len(vk_images)] = total_size
        sizes[i + len(vk_images)] = vk_memory_requirementses[i + len(vk_images)].size
        total_size += sizes[i + len(vk_images)]
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

main :: proc() {
    assert(sdl3.Init({ .VIDEO }))
    assert(sdl3.Vulkan_LoadLibrary(nil))

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
        vk_instance_flags |= .ENUMERATE_PORTABILITY_KHR
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
            pApplicationName = "voxels",
            applicationVersion = vk.MAKE_VERSION(1, 0, 0),
            pEngineName = "voxels",
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

    vk_voxel_memory, vk_voxel_texture_sizes, vk_voxel_texture_offsets, vk_voxel_allocation_result := allocate_for_resources(vk_device, vk_physical_device, { vk_voxel_texture }, {}, { .DEVICE_LOCAL })
    assert(vk_voxel_allocation_result == .SUCCESS)
    defer {
        vk.DestroyImage(vk_device, vk_voxel_texture, nil)
        vk.FreeMemory(vk_device, vk_voxel_memory, nil)
    }

    vk_voxel_texture_size := vk_voxel_texture_sizes[0]
    vk_voxel_texture_offset := vk_voxel_texture_offsets[0]
    delete(vk_voxel_texture_sizes)
    delete(vk_voxel_texture_offsets)

    assert(bind_resources_to_allocation(vk_device, vk_voxel_memory, { vk_voxel_texture }, {}, { vk_voxel_texture_offset }) == .SUCCESS)

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
                0, nil, 0, nil, 1, & vk.ImageMemoryBarrier {
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
                },
            })

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
            })

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
