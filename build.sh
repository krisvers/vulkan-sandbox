if [ "$1" == "release" ]; then
    odin build . -out:build/vulkan
else
    odin build . -debug -out:build/vulkan
fi

if [ $? == "0" ]; then
    if [ "$1" == "run" ]; then
        "./build/vulkan" ${@:2}
    elif [ "$1" == "lldb" ]; then
        lldb "./build/vulkan" ${@:2}
    elif [ "$1" == "renderdoc" ]; then
        qrenderdoc
    fi
else
    echo "--- Build failed"
fi
