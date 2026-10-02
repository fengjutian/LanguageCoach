# P1-3 + P1-6 placeholders for the Qwen3 JNI runtimes. The real
# `libqwen_tts_jni.so` ships in P1-5 once the model artifacts are ready;
# `libqwen_llm_jni.so` ships with P1-6's LLM artefacts. The Kotlin side
# stubs every call so these files are here purely to satisfy
# `externalNativeBuild.cmake.path` and to document the symbol contract.
cmake_minimum_required(VERSION 3.22.1)
project(language_coach_jni LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Qwen3-TTS runtime — populated in P1-5 when the Qwen3-TTS runtime arrives.
add_library(qwen_tts_jni SHARED
    src/main/cpp/qwen_tts_jni.cpp
)
target_include_directories(qwen_tts_jni PRIVATE src/main/cpp)

# Qwen3-LLM runtime — populated in P1-6 release.
add_library(qwen_llm_jni SHARED
    src/main/cpp/qwen_llm_jni.cpp
)
target_include_directories(qwen_llm_jni PRIVATE src/main/cpp)

# Android log + JNI helpers come with the NDK.
find_library(log-lib log)
target_link_libraries(qwen_tts_jni PRIVATE ${log-lib})
target_link_libraries(qwen_llm_jni PRIVATE ${log-lib})
