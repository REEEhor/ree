mkdir -p build
clear; zig build run -- ${1} | tee build/out.s && zig build-exe build/out.s -femit-bin=build/out && ./build/out

