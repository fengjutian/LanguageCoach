// P1-6 JNI placeholder for the Qwen3-LLM runtime.
//
// The Kotlin `LlmService` calls into these symbols; until P1-6 ships the
// real model + inference loop we expose placeholders that round-trip cleanly
// through the host VM. Each stub becomes a real `libqwen_llm` call when the
// artefacts land (P1-6 release):
//   nativeLoad(localDirectory, manifestJson)
//   nativeGenerateStart(sessionId, prompt, outputPath) -> void, pushes
//     LLM_TOKEN / LLM_COMPLETE events via the registered callback.
//   nativeGenerateCancel(sessionId)
//   nativeUnload()
#include <jni.h>
#include <android/log.h>

#define LOG_TAG "qwen_llm_jni"
#define ALOG(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

extern "C" {

JNIEXPORT void JNICALL
Java_com_languagecoach_language_1coach_LlmService_nativeLoad(
    JNIEnv *env, jclass, jstring localDirectory, jstring manifestJson) {
    ALOG("nativeLoad placeholder (real impl lands in P1-6 release)");
}

JNIEXPORT void JNICALL
Java_com_languagecoach_language_1coach_LlmService_nativeUnload(
    JNIEnv *env, jclass) {
    ALOG("nativeUnload placeholder");
}

JNIEXPORT jboolean JNICALL
Java_com_languagecoach_language_1coach_LlmService_nativeGenerateStart(
    JNIEnv *env, jclass, jstring sessionId, jstring prompt, jint maxTokens) {
    ALOG("nativeGenerateStart placeholder session=%s",
        sessionId ? env->GetStringUTFChars(sessionId, nullptr) : "(null)");
    return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_com_languagecoach_language_1coach_LlmService_nativeGenerateCancel(
    JNIEnv *env, jclass, jstring sessionId) {
    ALOG("nativeGenerateCancel placeholder session=%s",
        sessionId ? env->GetStringUTFChars(sessionId, nullptr) : "(null)");
}

}  // extern "C"