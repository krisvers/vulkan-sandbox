@echo off

odin build . -debug -out:build\voxels.exe
if %ERRORLEVEL% equ 0 (
    copy "C:\odin-windows-amd64-dev-2025-07\dist\vendor\sdl3\SDL3.dll" ".\build\SDL3.dll"
    if "%~1" == "run" (
        cd ".\build"
        ".\voxels.exe"
        cd "..\"
    )
) else (
    echo --- Build failed
)