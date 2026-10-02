# P1-3 placeholder for the Qwen3-TTS JNI runtime. The actual
# `libqwen_tts_jni.so` ships in P1-5 once the model artifacts are ready.
# The Kotlin side stubs every call so this file is here purely to satisfy
# `externalNativeBuild.cmake.path` and to document the symbol contract.
cmake_minimum_required(VERSION 3.22.1)
project(qwen_tts_jni LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Sources land in src/main/cpp/qwen_tts_jni.cpp — populated in P1-5 when
# the Qwen3-TTS runtime arrives.
add_library(qwen_tts_jni SHARED
    src/main/cpp/qwen_tts_jni.cpp
)

target_include_directories(qwen_tts_jni PRIVATE
    src/main/cpp
)

# Android log + JNI helpers come with the NDK.
find_library(log-lib log)
target_link_libraries(qwen_tts_jni PRIVATE ${log-lib})
