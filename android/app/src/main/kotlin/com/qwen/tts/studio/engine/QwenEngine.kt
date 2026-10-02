package com.qwen.tts.studio.engine

/** Thin Kotlin owner for the qwen3-tts.cpp JNI context. */
class QwenEngine : AutoCloseable {
    private var nativePtr: Long = nativeInit()

    class NativeParams(
        val languageId: Int = 2050,
        val instruction: String? = null,
        val speaker: String? = null,
        val maxAudioTokens: Int = 512,
    )

    class NativeResult(
        val audio: FloatArray?,
        val sampleRate: Int,
        val success: Boolean,
        val errorMsg: String?,
        val timeMs: Long,
    ) {
        val tokenizeMs: Long = 0
        val encodeMs: Long = 0
        val generateMs: Long = 0
        val decodeMs: Long = 0
        val decodeFrames: Int = 0
        val decodeSamples: Long = 0
        val decodeGraphComputeMs: Long = 0
    }

    class NativeCapabilities(
        val loaded: Boolean,
        val supportsCloning: Boolean,
        val supportsNamedSpeakers: Boolean,
        val supportsInstruction: Boolean,
        val speakerEmbeddingDim: Int,
        val modelKind: Int,
        val speakerCount: Int,
    )

    fun interface ProgressCallback {
        fun onProgress(tokensGenerated: Int, maxTokens: Int)
    }

    fun loadModels(modelDir: String, modelName: String): Boolean =
        nativeLoadModels(nativePtr, modelDir, modelName)

    fun synthesize(text: String, params: NativeParams): NativeResult =
        nativeSynthesize(nativePtr, text, null, null, params)

    fun getLastError(): String? = nativeGetLastError(nativePtr)
    fun setCpuThreads(threads: Int): Boolean = nativeSetCpuThreads(threads)
    fun getModelCapabilities(): NativeCapabilities? = nativeGetModelCapabilities(nativePtr)
    fun setProgressCallback(callback: ProgressCallback?): Boolean =
        nativeSetProgressCallback(nativePtr, callback)

    override fun close() {
        if (nativePtr != 0L) {
            nativeFree(nativePtr)
            nativePtr = 0
        }
    }

    private external fun nativeInit(): Long
    private external fun nativeFree(ptr: Long)
    private external fun nativeSetCpuThreads(threads: Int): Boolean
    private external fun nativeSetProgressCallback(ptr: Long, callback: ProgressCallback?): Boolean
    private external fun nativeLoadModels(ptr: Long, modelDir: String, modelName: String?): Boolean
    private external fun nativeSynthesize(
        ptr: Long,
        text: String,
        referenceWav: String?,
        speakerEmbeddingPath: String?,
        params: NativeParams?,
    ): NativeResult
    private external fun nativeGetLastError(ptr: Long): String?
    private external fun nativeGetModelCapabilities(ptr: Long): NativeCapabilities?

    companion object {
        init {
            System.loadLibrary("qwen3_tts_jni")
        }
    }
}
