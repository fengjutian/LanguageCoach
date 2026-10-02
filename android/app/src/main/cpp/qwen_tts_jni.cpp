// P1-3 JNI placeholder for the Qwen3-TTS runtime.
//
// The Kotlin `TtsService` calls into these symbols; until P1-5 ships the
// real model + inference loop we expose no-op stubs that let the lifecycle
// hooks round-trip cleanly through the host VM.
//
// Once the model lands, each stub becomes:
//   nativeLoad / nativeWarmup / nativeSynthesize / nativeCancel / nativeUnload
// with real `libqwen_tts` linkage.
#include <jni.h>
#include <android/log.h>

#define LOG_TAG "qwen_tts_jni"
#define ALOG(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

extern "C" {

JNIEXPORT void JNICALL
Java_com_languagecoach_language_1coach_TtsService_nativeLoad(
    JNIEnv *env, jclass, jstring localDirectory) {
    ALOG("nativeLoad placeholder (real impl lands in P1-5)");
}

JNIEXPORT void JNICALL
Java_com_languagecoach_language_1coach_TtsService_nativeWarmup(
    JNIEnv *env, jclass) {
    ALOG("nativeWarmup placeholder");
}

JNIEXPORT void JNICALL
Java_com_languagecoach_language_1coach_TtsService_nativeUnload(
    JNIEnv *env, jclass) {
    ALOG("nativeUnload placeholder");
}

JNIEXPORT jlong JNICALL
Java_com_languagecoach_language_1coach_TtsService_nativeSynthesize(
    JNIEnv *env, jclass, jstring text, jstring language, jstring voice,
    jdouble speed, jstring outputPath) {
    ALOG("nativeSynthesize placeholder -> %s",
         outputPath ? env->GetStringUTFChars(outputPath, nullptr) : "(null)");
    return 0;
}

JNIEXPORT void JNICALL
Java_com_languagecoach_language_1coach_TtsService_nativeCancel(
    JNIEnv *env, jclass) {
    ALOG("nativeCancel placeholder");
}

}  // extern "C"
