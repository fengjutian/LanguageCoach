package com.languagecoach.language_coach

import android.os.SystemClock
import android.util.Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Local Qwen3-TTS runtime stub. The actual JNI calls live in
 * `libqwen_tts_jni.so` and are wired in once the model artifacts ship in
 * P1-5. Until then this class pretends to load a model, runs a no-op
 * synthesis that writes a 44-byte WAV header, and surfaces all the
 * lifecycle hooks the Flutter side expects.
 *
 * Thread-safety: lifecycle calls may land on the platform thread or a
 * background thread; [canceled] is the only mutable state and uses an
 * [AtomicBoolean].
 */
class TtsService(private val cacheDirectory: File) {
    private val loaded = AtomicBoolean(false)
    private val modelId = AtomicLong(0)
    private val canceled = AtomicBoolean(false)
    private val peakRssKb = AtomicLong(0)

    /** True once `loadModel` has finished and the runtime can synthesize. */
    fun isLoaded(): Boolean = loaded.get()

    /**
     * "Load" the Qwen3-TTS runtime. Returns the [modelId] the runtime
     * assigned (the caller passes its manifest id; the runtime echoes it
     * after warming up its internal tables).
     */
    fun loadModel(modelId: String, manifestJson: String?, localDirectory: String?): String {
        // JNI hook (filled in once the native library is built):
        //   nativeLoad(localDirectory ?: cacheDirectory.absolutePath + "/models")
        Log.i(TAG, "loadModel id=$modelId local=$localDirectory")
        loaded.set(true)
        this.modelId.set(SystemClock.uptimeMillis())
        return modelId
    }

    /**
     * First-call priming. Returns elapsed milliseconds — the benchmark
     * page uses this to populate `model_load_ms`.
     */
    fun warmupModel(modelId: String): Int {
        check(loaded.get()) { "warmup before loadModel for $modelId" }
        val start = SystemClock.uptimeMillis()
        // JNI hook: nativeWarmup()
        val elapsed = (SystemClock.uptimeMillis() - start).toInt()
        Log.i(TAG, "warmupModel id=$modelId ms=$elapsed")
        return elapsed
    }

    /**
     * Run one synthesis. Writes a placeholder WAV file at
     * `cacheDirectory/synth_{hash}.wav` and returns the absolute path.
     * The Flutter side copies that file into [AudioCacheRepository] when
     * the call returns.
     */
    fun synthesize(
        text: String,
        language: String,
        voice: String,
        speed: Double,
        model: String?,
    ): String {
        check(loaded.get()) { "synthesize before loadModel" }
        canceled.set(false)
        val filename = "synth_${text.hashCode()}_${System.nanoTime()}.wav"
        val target = File(cacheDirectory, filename)
        target.parentFile?.mkdirs()
        // JNI hook: nativeSynthesize(text, language, voice, speed, target.absolutePath)
        //   returns elapsedMs, peakRssKb, sampleCount — TtsService records
        //   them in the benchmark snapshot.
        WAV_HEADER_PLACEHOLDER.let { target.writeBytes(it) }
        peakRssKb.updateAndGet { maxOf(it, currentRssKb()) }
        Log.i(
            TAG,
            "synthesize text='${text.take(32)}' lang=$language voice=$voice " +
                "model=${model ?: "default"} -> ${target.absolutePath}",
        )
        return target.absolutePath
    }

    /** Best-effort cancel — flips the flag the JNI loop polls. */
    fun cancelSynthesis(): Boolean {
        if (!loaded.get()) return false
        canceled.set(true)
        // JNI hook: nativeCancel() — may return true if a job was running.
        return true
    }

    /** Release the runtime's resources. Safe to call when not loaded. */
    fun unloadModel(modelId: String) {
        if (!loaded.get()) return
        // JNI hook: nativeUnload()
        loaded.set(false)
        Log.i(TAG, "unloadModel id=$modelId")
    }

    /**
     * Snapshot for the benchmark page. All values come from Android
     * framework APIs; the JNI side will overwrite the temperature / peak
     * rss once the model is resident.
     */
    fun benchmarkSnapshot(): Map<String, Any> {
        return mapOf(
            "isLoaded" to isLoaded(),
            "peakRssKb" to peakRssKb.get().coerceAtLeast(currentRssKb()),
            "currentRssKb" to currentRssKb(),
            "threadCount" to Thread.activeCount(),
        )
    }

    private fun currentRssKb(): Long {
        val runtime = Runtime.getRuntime()
        val used = runtime.totalMemory() - runtime.freeMemory()
        return used / 1024
    }

    companion object {
        private const val TAG = "TtsService"

        // Minimal RIFF/WAVE header pointing at zero PCM data — just enough
        // for the audio pipeline to load + report its size.
        private val WAV_HEADER_PLACEHOLDER = byteArrayOf(
            0x52, 0x49, 0x46, 0x46,
            0x24, 0x00, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45,
            0x66, 0x6d, 0x74, 0x20,
            0x10, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00,
            0x44, 0xac, 0x00, 0x00,
            0x88, 0x58, 0x01, 0x00,
            0x02, 0x00, 0x10, 0x00,
            0x64, 0x61, 0x74, 0x61,
            0x00, 0x00, 0x00, 0x00,
        )

        init {
            try {
                System.loadLibrary("qwen_tts_jni")
            } catch (e: UnsatisfiedLinkError) {
                // P1-3 ships the placeholder JNI library alongside the
                // model artifacts in P1-5. Until then we run with the
                // stub Kotlin path above so the lifecycle hooks are still
                // testable end-to-end.
                Log.w(TAG, "qwen_tts_jni not loaded — using Kotlin stub", e)
            }
        }
    }
}
