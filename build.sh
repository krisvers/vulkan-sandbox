odin build . -debug -out:build/voxels
if [ $? == "0" ]; then
    if [ "$1" == "run" ]; then
        cd "./build"
        "./voxels"
        cd "../"
    fi
else
    echo "--- Build failed"
fi