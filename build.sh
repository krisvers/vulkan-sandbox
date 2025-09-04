odin build . -debug -out:build/vulkan
if [ $? == "0" ]; then
    if [ "$1" == "run" ]; then
        cd "./build"
        "./vulkan"
        cd "../"
    elif [ "$1" == "lldb" ]; then
        cd "./build"
        lldb "./vulkan"
        cd "../"
    elif [ "$1" == "renderdoc" ]; then
        cd "./build"
        qrenderdoc
        cd "../"
    fi
else
    echo "--- Build failed"
fi