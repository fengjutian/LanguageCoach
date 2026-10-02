package com.languagecoach.language_coach

import android.os.SystemClock
import com.qwen.tts.studio.engine.QwenEngine
import java.io.File
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Owns the resident qwen3-tts.cpp context and writes its PCM output as WAV. */
class TtsService(private val cacheDirectory: File) {
    private var engine: QwenEngine? = null
    private var loadedModelId: String? = null
    private val synthesizing = AtomicBoolean(false)
    private val peakRssKb = AtomicLong(0)
    private val lastSynthesisMs = AtomicLong(0)
    private val lastSampleCount = AtomicLong(0)

    fun isLoaded(): Boolean = engine != null

    @Synchronized
    fun loadModel(modelId: String, manifestJson: String?, localDirectory: String?): String {
        require(!localDirectory.isNullOrBlank()) { "Model directory is required" }
        val directory = File(localDirectory)
        require(directory.isDirectory) { "Model directory does not exist: $localDirectory" }
        val talker = File(directory, TALKER_FILE)
        require(talker.isFile) { "Missing $TALKER_FILE" }
        require(File(directory, TOKENIZER_FILE).isFile) { "Missing $TOKENIZER_FILE" }

        engine?.close()
        engine = null
        val candidate = QwenEngine()
        candidate.setCpuThreads((Runtime.getRuntime().availableProcessors() - 1).coerceIn(1, 8))
        if (!candidate.loadModels(directory.absolutePath, talker.name)) {
            val message = candidate.getLastError() ?: "qwen3-tts.cpp rejected the model"
            candidate.close()
            error(message)
        }
        check(candidate.getModelCapabilities()?.loaded == true) {
            "Native runtime did not report a loaded model"
        }
        engine = candidate
        loadedModelId = modelId
        peakRssKb.updateAndGet { maxOf(it, currentRssKb()) }
        return modelId
    }

    fun warmupModel(modelId: String): Int {
        check(engine != null && loadedModelId == modelId) { "Model is not loaded: $modelId" }
        return 0
    }

    fun synthesize(
        text: String,
        language: String,
        voice: String,
        speed: Double,
        model: String?,
    ): String {
        require(text.isNotBlank()) { "Text must not be blank" }
        require(speed in 0.5..2.0) { "Speed must be between 0.5 and 2.0" }
        val active = checkNotNull(engine) { "Qwen3-TTS model is not loaded" }
        check(synthesizing.compareAndSet(false, true)) { "A synthesis is already running" }
        try {
            val started = SystemClock.elapsedRealtime()
            val result = active.synthesize(
                text,
                QwenEngine.NativeParams(
                    languageId = languageId(language),
                    speaker = speaker(language, voice),
                ),
            )
            check(result.success) { result.errorMsg ?: "Native synthesis failed" }
            val samples = checkNotNull(result.audio) { "Native synthesis returned no audio" }
            check(samples.isNotEmpty() && result.sampleRate > 0) {
                "Native synthesis returned no audio"
            }
            val target = File(cacheDirectory, "synth_${text.hashCode()}_${System.nanoTime()}.wav")
            target.parentFile?.mkdirs()
            target.outputStream().buffered().use { writeWav(it, samples, result.sampleRate) }
            check(target.length() > WAV_HEADER_BYTES) { "Generated WAV contains no PCM samples" }
            peakRssKb.updateAndGet { maxOf(it, currentRssKb()) }
            lastSynthesisMs.set(SystemClock.elapsedRealtime() - started)
            lastSampleCount.set(samples.size.toLong())
            return target.absolutePath
        } finally {
            synthesizing.set(false)
        }
    }

    /** qwen3-tts.cpp currently has no cooperative cancellation ABI. */
    fun cancelSynthesis(): Boolean = false

    @Synchronized
    fun unloadModel(modelId: String) {
        if (loadedModelId != modelId) return
        engine?.close()
        engine = null
        loadedModelId = null
    }

    fun benchmarkSnapshot(): Map<String, Any> = mapOf(
        "isLoaded" to isLoaded(),
        "isSynthesizing" to synthesizing.get(),
        "peakRssKb" to peakRssKb.get().coerceAtLeast(currentRssKb()),
        "currentRssKb" to currentRssKb(),
        "threadCount" to Thread.activeCount(),
        "lastSynthesisMs" to lastSynthesisMs.get(),
        "lastSampleCount" to lastSampleCount.get(),
    )

    private fun currentRssKb(): Long {
        val runtime = Runtime.getRuntime()
        return (runtime.totalMemory() - runtime.freeMemory()) / 1024
    }

    private fun languageId(language: String): Int = when (language.lowercase()) {
        "de", "de-de", "german" -> 2053
        "es", "es-es", "spanish" -> 2054
        "zh", "zh-cn", "chinese" -> 2055
        "ja", "ja-jp", "japanese" -> 2058
        "fr", "fr-fr", "french" -> 2061
        "ko", "ko-kr", "korean" -> 2064
        "ru", "ru-ru", "russian" -> 2069
        else -> 2050
    }

    private fun speaker(language: String, voice: String): String = when {
        voice.equals("vivian", true) -> "vivian"
        voice.equals("serena", true) || voice.contains("female_warm") -> "serena"
        voice.equals("ryan", true) -> "ryan"
        language.startsWith("ja", true) -> "ono_anna"
        language.startsWith("ko", true) -> "sohee"
        language.startsWith("zh", true) -> "vivian"
        else -> "ryan"
    }

    private fun writeWav(output: OutputStream, samples: FloatArray, sampleRate: Int) {
        val dataBytes = samples.size * 2
        output.writeAscii("RIFF")
        output.writeIntLe(36 + dataBytes)
        output.writeAscii("WAVEfmt ")
        output.writeIntLe(16)
        output.writeShortLe(1)
        output.writeShortLe(1)
        output.writeIntLe(sampleRate)
        output.writeIntLe(sampleRate * 2)
        output.writeShortLe(2)
        output.writeShortLe(16)
        output.writeAscii("data")
        output.writeIntLe(dataBytes)
        samples.forEach { output.writeShortLe((it.coerceIn(-1f, 1f) * 32767f).toInt()) }
    }

    private fun OutputStream.writeAscii(value: String) = write(value.toByteArray(Charsets.US_ASCII))
    private fun OutputStream.writeIntLe(value: Int) {
        write(value and 0xff)
        write(value ushr 8 and 0xff)
        write(value ushr 16 and 0xff)
        write(value ushr 24 and 0xff)
    }
    private fun OutputStream.writeShortLe(value: Int) {
        write(value and 0xff)
        write(value ushr 8 and 0xff)
    }

    companion object {
        private const val TALKER_FILE = "qwen-talker-0.6b-customvoice-Q4_K_M.gguf"
        private const val TOKENIZER_FILE = "qwen-tokenizer-12hz-Q4_K_M.gguf"
        private const val WAV_HEADER_BYTES = 44
    }
}
