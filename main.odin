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

main :: proc () {
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
        enabledLayerCount = 0,
        ppEnabledLayerNames = nil,
        enabledExtensionCount = u32(len(vk_instance_extensions)),
        ppEnabledExtensionNames = &vk_instance_extensions[0]
    }, nil, &vk_instance)
    delete(vk_instance_extensions)
    delete(vk_available_instance_extensions)
    fmt.println(vk_result)
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
    fmt.println(vk_result)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyDebugUtilsMessengerEXT(vk_instance, vk_debug_utils_messenger, nil)

    window := sdl3.CreateWindow("voxels", 1200, 900, { .VULKAN })
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
    fmt.println(vk_result)
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
    fmt.println(vk_result)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyCommandPool(vk_device, vk_command_pool, nil)

    vk_command_buffer: vk.CommandBuffer
    vk_result = vk.AllocateCommandBuffers(vk_device, &{
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = vk_command_pool,
        level = .PRIMARY,
        commandBufferCount = 1,
    }, &vk_command_buffer)
    fmt.println(vk_result)
    assert(vk_result == .SUCCESS)
    defer vk.FreeCommandBuffers(vk_device, vk_command_pool, 1, &vk_command_buffer)

    vk_swapchain: vk.SwapchainKHR
    vk_result = vk.CreateSwapchainKHR(vk_device, &{
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = vk_surface,
        minImageCount = 3,
        imageFormat = .B8G8R8A8_UNORM,
        imageColorSpace = .SRGB_NONLINEAR,
        imageExtent = {
            width = 1200,
            height = 900,
        },
        imageArrayLayers = 1,
        imageUsage = { .COLOR_ATTACHMENT },
        imageSharingMode = .EXCLUSIVE,
        preTransform = { .IDENTITY },
        compositeAlpha = { .OPAQUE },
        presentMode = .FIFO,
    }, nil, &vk_swapchain)
    fmt.println(vk_result)
    assert(vk_result == .SUCCESS)
    defer vk.DestroySwapchainKHR(vk_device, vk_swapchain, nil)

    vk_swapchain_image_count: u32
    assert(vk.GetSwapchainImagesKHR(vk_device, vk_swapchain, &vk_swapchain_image_count, nil) == .SUCCESS)

    vk_swapchain_images := make([]vk.Image, vk_swapchain_image_count)
    assert(vk.GetSwapchainImagesKHR(vk_device, vk_swapchain, &vk_swapchain_image_count, &vk_swapchain_images[0]) == .SUCCESS)

    vk_swapchain_image_views := make([]vk.ImageView, vk_swapchain_image_count)
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
    }

    defer {
        for i in 0..<vk_swapchain_image_count {
            vk.DestroyImageView(vk_device, vk_swapchain_image_views[i], nil)
        }

        delete(vk_swapchain_image_views)
    }
    
    vk_image_acquisition_semaphore: vk.Semaphore
    vk_result = vk.CreateSemaphore(vk_device, &{
        sType = .SEMAPHORE_CREATE_INFO,
    }, nil, &vk_image_acquisition_semaphore)
    fmt.println(vk_result)
    assert(vk_result == .SUCCESS)
    defer vk.DestroySemaphore(vk_device, vk_image_acquisition_semaphore, nil)

    vk_render_finished_semaphore: vk.Semaphore
    vk_result = vk.CreateSemaphore(vk_device, &{
        sType = .SEMAPHORE_CREATE_INFO,
    }, nil, &vk_render_finished_semaphore)
    fmt.println(vk_result)
    assert(vk_result == .SUCCESS)
    defer vk.DestroySemaphore(vk_device, vk_render_finished_semaphore, nil)

    vk_in_flight_fence: vk.Fence
    vk_result = vk.CreateFence(vk_device, &{
        sType = .FENCE_CREATE_INFO,
        flags = { .SIGNALED },
    }, nil, &vk_in_flight_fence)
    fmt.println(vk_result)
    assert(vk_result == .SUCCESS)
    defer vk.DestroyFence(vk_device, vk_in_flight_fence, nil)

    vk_image_index := vk_swapchain_image_count - 1
    main_loop: for true {
        event: sdl3.Event
        for sdl3.PollEvent(&event) {
            if event.type == .QUIT {
                break main_loop
            }
        }

        assert(vk.WaitForFences(vk_device, 1, &vk_in_flight_fence, true, max(u64)) == .SUCCESS)
        assert(vk.ResetFences(vk_device, 1, &vk_in_flight_fence) == .SUCCESS)

        vk_image_acquisition_semaphore_index := (vk_image_index + 1) % vk_swapchain_image_count
        fmt.println("swapchain semaphore index:", vk_image_acquisition_semaphore_index)
        assert(vk.AcquireNextImageKHR(vk_device, vk_swapchain, max(u64), vk_image_acquisition_semaphore, vk_in_flight_fence, &vk_image_index) == .SUCCESS)
        
        assert(vk.WaitForFences(vk_device, 1, &vk_in_flight_fence, true, max(u64)) == .SUCCESS)
        assert(vk.ResetFences(vk_device, 1, &vk_in_flight_fence) == .SUCCESS)
        fmt.println("swapchain image index:", vk_image_index)

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
                    width = 1200,
                    height = 900,
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
                        float32 = { 0.0, 1.0, 0.0, 1.0 },
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
            pWaitSemaphores = &vk_swapchain_image_acquisition_semaphores[vk_image_acquisition_semaphore_index],
            commandBufferCount = 1,
            pCommandBuffers = &vk_command_buffer,
            signalSemaphoreCount = 1,
            pSignalSemaphores = &vk_render_finished_semaphore,
            pWaitDstStageMask = &wait_stage,
        }, vk_in_flight_fence) == .SUCCESS)

        assert(vk.QueuePresentKHR(vk_queue, &{
            sType = .PRESENT_INFO_KHR,
            waitSemaphoreCount = 1,
            pWaitSemaphores = &vk_render_finished_semaphore,
            swapchainCount = 1,
            pSwapchains = &vk_swapchain,
            pImageIndices = &vk_image_index,
        }) == .SUCCESS)
    }

    assert(vk.DeviceWaitIdle(vk_device) == .SUCCESS)
}
