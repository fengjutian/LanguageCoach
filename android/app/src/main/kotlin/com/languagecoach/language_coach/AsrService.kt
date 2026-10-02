package com.languagecoach.language_coach

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * P1-4 ASR runtime shell. The real AudioRecord + sherpa-onnx pipeline
 * lives behind the JNI symbols in `libqwen_tts_jni` (renamed to
 * `liblanguage_coach_asr` when P1-5 ships); this class wires the bridge
 * lifecycle (start / stop / cancel / silence timeout / profile list) so
 * the Flutter side has a real seam to drive from the host VM.
 *
 * Pcm flow:
 *   AudioRecord (16 kHz mono) -> onCapture -> VadEngine.feed() ->
 *   AsrEngine.feed() + emit(ASR_PARTIAL / ASR_FINAL) -> Flutter.
 *
 * Until the JNI library is built the class acts as a permission-aware
 * shim that emits a single `ASR_ERROR` event with code 9
 * (`ERROR_NO_MATCH`) so the chat UI can still drive the fallback path
 * (system SpeechRecognizer).
 */
class AsrService(
    private val context: Context,
    private val cacheDirectory: File,
    private val emit: (type: String, payload: Map<String, Any?>) -> Unit,
) {
    private val capturing = AtomicBoolean(false)
    private val loaded = AtomicBoolean(false)
    private var activeProfileId: String? = null
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    private var silenceStartMs: Long = 0L
    private val silenceTimeoutMs: Int = 8000

    /** True when a model is resident and can stream results. */
    fun isReady(): Boolean = loaded.get()

    /** Currently active profile, or `null` if none. */
    fun activeProfile(): String? = activeProfileId

    /** Permission gate — local-runtime error codes live outside Android's range. */
    fun hasRecordPermission(): Boolean = ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.RECORD_AUDIO,
    ) == PackageManager.PERMISSION_GRANTED

    fun loadProfile(profileId: String, languageCode: String): Boolean {
        // JNI hook (filled in once `liblanguage_coach_asr` ships):
        //   val ok = nativeLoadProfile(profileId, languageCode,
        //                              cacheDirectory.absolutePath + "/asr")
        val modelDir = File(cacheDirectory, "asr/$profileId")
        val ok = modelDir.exists()
        loaded.set(ok)
        activeProfileId = if (ok) profileId else null
        Log.i(TAG, "loadProfile id=$profileId language=$languageCode ok=$ok")
        return ok
    }

    fun unloadProfile(profileId: String) {
        if (activeProfileId == profileId) {
            // JNI hook: nativeUnloadProfile()
            loaded.set(false)
            activeProfileId = null
        }
    }

    /**
     * Start the microphone capture session. Returns `true` if capture
     * started cleanly; `false` if the permission is missing or another
     * session is already active.
     */
    fun startCapture(preferredAsrLanguage: String, profileId: String?): Boolean {
        if (capturing.get()) return false
        if (!hasRecordPermission()) {
            emit(
                "ASR_ERROR",
                mapOf("code" to ERROR_PERMISSION_DENIED, "message" to "Microphone permission denied"),
            )
            return false
        }
        if (!loaded.get()) {
            emit(
                "ASR_ERROR",
                mapOf("code" to ERROR_MODEL_MISSING, "message" to "No ASR model loaded"),
            )
            return false
        }

        try {
            val sampleRate = 16_000
            val channelConfig = AudioFormat.CHANNEL_IN_MONO
            val audioFormat = AudioFormat.ENCODING_PCM_16BIT
            val minBuffer = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
                .coerceAtLeast(4096)
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                sampleRate,
                channelConfig,
                audioFormat,
                minBuffer * 4,
            )
            audioRecord?.startRecording()
            silenceStartMs = SystemClock.uptimeMillis()
            capturing.set(true)
            emit("ASR_START", mapOf("language" to preferredAsrLanguage))
            _startCaptureThread()
            return true
        } catch (e: Throwable) {
            Log.w(TAG, "startCapture failed", e)
            emit("ASR_ERROR", mapOf("code" to 9, "message" to (e.message ?: "capture failed")))
            return false
        }
    }

    fun stopCapture() {
        if (!capturing.get()) return
        capturing.set(false)
        try {
            audioRecord?.stop()
        } catch (_: Throwable) {
        }
        audioRecord?.release()
        audioRecord = null
        captureThread?.interrupt()
        captureThread = null
        // JNI hook: nativeFlush() — emit ASR_FINAL with whatever is buffered.
        emit("ASR_FINAL", mapOf("text" to "", "language" to "auto"))
    }

    fun cancelCapture() {
        if (!capturing.get()) return
        capturing.set(false)
        try {
            audioRecord?.stop()
        } catch (_: Throwable) {
        }
        audioRecord?.release()
        audioRecord = null
        captureThread?.interrupt()
        captureThread = null
        emit("ASR_CANCELLED", emptyMap())
    }

    private fun _startCaptureThread() {
        captureThread = Thread {
            val buffer = ShortArray(1024)
            while (capturing.get()) {
                val r = audioRecord ?: break
                val read = try {
                    r.read(buffer, 0, buffer.size)
                } catch (_: Throwable) {
                    break
                }
                if (read <= 0) break
                // JNI hook: nativeFeedPcm(buffer, read) -> partial/final events
                // Silence detection — the runtime fires ASR_FINAL when the
                // user pauses longer than `silenceTimeoutMs`.
                val now = SystemClock.uptimeMillis()
                val rms = _rms(buffer, read)
                if (rms < 200) {
                    if (silenceStartMs == 0L) silenceStartMs = now
                    if (now - silenceStartMs > silenceTimeoutMs) {
                        emit("ASR_FINAL", mapOf("text" to "", "language" to "auto"))
                        capturing.set(false)
                        break
                    }
                } else {
                    silenceStartMs = 0L
                }
            }
        }.also { it.name = "AsrCaptureThread"; it.start() }
    }

    private fun _rms(buffer: ShortArray, length: Int): Int {
        if (length <= 0) return 0
        var sum = 0.0
        for (i in 0 until length) {
            val v = buffer[i].toDouble()
            sum += v * v
        }
        val rms = Math.sqrt(sum / length).toInt()
        return rms
    }

    /**
     * Profiles known to the native runtime. P1-5 swaps the static list
     * for a discovery pass over the on-disk `asr/` directory; for now
     * these are the curated ones declared in `asr_model_profile.dart`.
     */
    fun listInstalledProfiles(): List<Map<String, Any?>> {
        return listOf(
            mapOf(
                "id" to "sherpa-onnx-zipformer-zh-small",
                "languageCode" to "zh-CN",
                "label" to "普通话 · 小",
                "sizeBytes" to 0,
                "accuracyTier" to "small",
                "transducer" to "zipformer",
            ),
            mapOf(
                "id" to "sherpa-onnx-zipformer-en-small",
                "languageCode" to "en-US",
                "label" to "English · Small",
                "sizeBytes" to 0,
                "accuracyTier" to "small",
                "transducer" to "zipformer",
            ),
        )
    }

    companion object {
        private const val TAG = "AsrService"
        private const val ERROR_PERMISSION_DENIED = 1001
        private const val ERROR_MODEL_MISSING = 1002
    }
}
