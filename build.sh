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
    fi
else
    echo "--- Build failed"
fi