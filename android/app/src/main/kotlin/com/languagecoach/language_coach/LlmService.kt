package com.languagecoach.language_coach

import android.util.Log
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * P1-6 LLM runtime shell. The real Qwen3-0.6B inference loop lives behind
 * the JNI symbols in `libqwen_llm_jni.so`; until P1-6 ships the actual
 * artefacts this Kotlin class wires the lifecycle so the chat UI has a
 * real seam to drive from the host VM.
 *
 * Streaming model:
 *   startLlmGeneration(sessionId, prompt) spawns a worker that emits a
 *   configurable number of `LLM_TOKEN` events on the Flutter EventChannel,
 *   followed by `LLM_COMPLETE` (or `LLM_ERROR` on cancel). `cancelLlmGeneration`
 *   flips the session's flag so the worker can bail out cleanly.
 *
 * Thread-safety: each session is tracked in [sessions] keyed by sessionId.
 * Lifecycle calls may arrive on the platform thread or background workers.
 */
class LlmService(
    private val cacheDirectory: File,
    private val emit: (type: String, sessionId: String, payload: Map<String, Any?>) -> Unit,
) {
    private val loaded = AtomicBoolean(false)
    private val loadedModelId = StringBuilder()
    private val sessions = ConcurrentHashMap<String, Session>()
    private val workerExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "LlmService-Worker").also { it.isDaemon = true }
    }

    /** True once [loadLlmModel] succeeded and the runtime can generate. */
    fun isLoaded(): Boolean = loaded.get()

    /**
     * Load the Qwen3-LLM runtime. Returns the [modelId] echoed back so the
     * Dart caller can correlate it with the manifest it asked for. Fails
     * silently (returns `null`) when the on-disk artifacts are missing —
     * the Flutter side surfaces the failure as a localised error card.
     */
    fun loadLlmModel(modelId: String, manifestJson: String?, localDirectory: String?): String? {
        val resolvedDir = localDirectory ?: File(cacheDirectory, "llm/$modelId").absolutePath
        val dir = File(resolvedDir)
        val ok = dir.exists() && dir.isDirectory
        if (!ok) {
            Log.w(TAG, "loadLlmModel id=$modelId dir=$resolvedDir missing")
            return null
        }
        // JNI hook (filled in once the native library ships):
        //   nativeLoad(resolvedDir, manifestJson)
        synchronized(loadedModelId) {
            loadedModelId.setLength(0)
            loadedModelId.append(modelId)
        }
        loaded.set(true)
        Log.i(TAG, "loadLlmModel id=$modelId dir=$resolvedDir ok=true")
        return modelId
    }

    /** Release the runtime. Cancels every active session first. */
    fun unloadLlmModel(modelId: String) {
        if (!loaded.get()) return
        // JNI hook: nativeUnload()
        sessions.values.forEach { it.canceled.set(true) }
        sessions.clear()
        loaded.set(false)
        synchronized(loadedModelId) {
            loadedModelId.setLength(0)
        }
        Log.i(TAG, "unloadLlmModel id=$modelId")
    }

    /**
     * Start a streaming generation. Returns the [sessionId] the runtime
     * assigned, or `null` if the runtime rejected the request. The token
     * stream arrives on the [emit] channel tagged with the same sessionId.
     */
    fun startLlmGeneration(sessionId: String, prompt: String, modelId: String): String? {
        if (!loaded.get()) return null
        if (sessions.containsKey(sessionId)) return null
        val session = Session(sessionId, prompt, modelId)
        sessions[sessionId] = session
        workerExecutor.submit { _runSession(session) }
        Log.i(TAG, "startLlmGeneration session=$sessionId model=$modelId prompt='${prompt.take(40)}'")
        return sessionId
    }

    /** Cancel an in-flight generation. No-op when the session is unknown. */
    fun cancelLlmGeneration(sessionId: String) {
        val session = sessions.remove(sessionId) ?: return
        session.canceled.set(true)
        Log.i(TAG, "cancelLlmGeneration session=$sessionId")
    }

    /**
     * Snapshot of every LLM the runtime knows about, regardless of whether
     * the artefacts are installed. Mirrors `AsrService.listInstalledProfiles`.
     */
    fun listInstalledModels(): List<Map<String, Any?>> {
        return listOf(
            mapOf(
                "id" to "qwen3-llm-0.6B",
                "version" to "0.6.0",
                "label" to "Qwen3 LLM 0.6B (Local)",
                "type" to "llm",
                "sizeBytes" to 0,
            ),
        )
    }

    /**
     * Stub generation loop. P1-6 emits a fixed short string in 5-character
     * chunks with a small delay so the streaming path is exercisable end-to-
     * end without a real model. The real driver lands with `libqwen_llm_jni`
     * and replaces the per-token emit with native token pushes.
     */
    private fun _runSession(session: Session) {
        val fakeTokens = listOf(
            "Hello",
            " your",
            " local",
            " Qwen3",
            " model",
            " is",
            " ready",
            ".",
        )
        try {
            for (token in fakeTokens) {
                if (session.canceled.get()) break
                Thread.sleep(120)
                if (session.canceled.get()) break
                emit(
                    "LLM_TOKEN",
                    session.id,
                    mapOf("token" to token, "index" to fakeTokens.indexOf(token)),
                )
            }
            if (session.canceled.get()) {
                emit("LLM_ERROR", session.id, mapOf("message" to "cancelled"))
            } else {
                emit("LLM_COMPLETE", session.id, mapOf("tokensEmitted" to fakeTokens.size))
            }
        } catch (e: InterruptedException) {
            emit("LLM_ERROR", session.id, mapOf("message" to "interrupted"))
        } catch (e: Throwable) {
            emit("LLM_ERROR", session.id, mapOf("message" to (e.message ?: "unknown")))
        } finally {
            sessions.remove(session.id)
        }
    }

    private class Session(
        val id: String,
        val prompt: String,
        val modelId: String,
    ) {
        val canceled = AtomicBoolean(false)
    }

    companion object {
        private const val TAG = "LlmService"

        init {
            try {
                System.loadLibrary("qwen_llm_jni")
            } catch (e: UnsatisfiedLinkError) {
                // The real JNI library ships with the Qwen3-LLM artefacts.
                // Until then we run with the Kotlin stub so the streaming
                // path is still exercisable end-to-end.
                Log.w(TAG, "qwen_llm_jni not loaded — using Kotlin stub", e)
            }
        }
    }
}