package com.languagecoach.language_coach

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity(), EventChannel.StreamHandler, RecognitionListener {
    private var eventSink: EventChannel.EventSink? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingLanguage: String = "en-US"
    private var pendingAsrProfileId: String? = null
    private var pendingLocalCapture = false
    private var ttsService: TtsService? = null
    private var systemTtsService: SystemTtsService? = null
    private var asrService: AsrService? = null
    private var llmService: LlmService? = null
    // Track the model ids the runtime currently has resident so
    // `onDestroy` can unload them instead of guessing the manifest id.
    private val loadedLlmModels = mutableSetOf<String>()
    private var loadedTtsModelId: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // The native TTS runtime owns its own scratch directory under the
        // app's private files dir; Flutter copies the produced WAVs into
        // `getApplicationDocumentsDirectory()/audio/...` for caching.
        val ttsCache = File(filesDir, "tts_scratch")
        if (!ttsCache.exists()) ttsCache.mkdirs()
        ttsService = TtsService(ttsCache)
        systemTtsService = SystemTtsService(this, ttsCache)

        val asrCache = File(filesDir, "asr_scratch")
        if (!asrCache.exists()) asrCache.mkdirs()
        asrService = AsrService(this, asrCache, ::emit)

        val llmCache = File(filesDir, "llm_scratch")
        if (!llmCache.exists()) llmCache.mkdirs()
        llmService = LlmService(llmCache) { type, sessionId, payload ->
            eventSink?.success(mapOf("type" to type, "sessionId" to sessionId, "payload" to payload))
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COMMANDS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openAppSettings" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.fromParts("package", packageName, null),
                                ),
                            )
                            result.success(null)
                        } catch (e: Throwable) {
                            result.error("OPEN_SETTINGS_FAILED", e.message, null)
                        }
                    }
                    "startListening" -> {
                        val language = call.argument<String>("language") ?: "en-US"
                        requestAudioPermissionAndStart(language, result)
                    }
                    "stopListening" -> {
                        speechRecognizer?.stopListening()
                        result.success(null)
                    }
                    "cancelListening" -> {
                        speechRecognizer?.cancel()
                        emit("ASR_CANCELLED")
                        result.success(null)
                    }
                    "isSpeechRecognitionAvailable" ->
                        result.success(SpeechRecognizer.isRecognitionAvailable(this))
                    "loadLlmModel" -> {
                        val modelId = call.argument<String>("modelId") ?: ""
                        val manifestJson = call.argument<String>("manifestJson")
                        val localDirectory = call.argument<String>("localDirectory")
                        val echoed = try {
                            llmService?.loadLlmModel(modelId, manifestJson, localDirectory)
                        } catch (e: Throwable) {
                            null
                        }
                        if (echoed == null) {
                            result.error(
                                "LLM_LOAD_FAILED",
                                "Local LLM artifacts are missing for $modelId",
                                null,
                            )
                        } else {
                            loadedLlmModels.add(echoed)
                            result.success(echoed)
                        }
                    }
                    "startLlmGeneration" -> {
                        val sessionId = call.argument<String>("sessionId") ?: ""
                        val prompt = call.argument<String>("prompt").orEmpty()
                        val modelId = call.argument<String>("modelId") ?: ""
                        val started = llmService?.startLlmGeneration(sessionId, prompt, modelId)
                        if (started == null) {
                            result.error(
                                "LLM_NOT_LOADED",
                                "Local LLM runtime is not loaded or sessionId already in use.",
                                null,
                            )
                        } else {
                            result.success(started)
                        }
                    }
                    "cancelLlmGeneration" -> {
                        val sessionId = call.argument<String>("sessionId") ?: ""
                        llmService?.cancelLlmGeneration(sessionId)
                        result.success(null)
                    }
                    "unloadLlmModel" -> {
                        val modelId = call.argument<String>("modelId") ?: ""
                        llmService?.unloadLlmModel(modelId)
                        loadedLlmModels.remove(modelId)
                        result.success(null)
                    }
                    "listLlmModels" -> {
                        result.success(llmService?.listInstalledModels() ?: emptyList<Map<String, Any?>>())
                    }
                    "synthesize" -> {
                        val text = call.argument<String>("text").orEmpty()
                        val language = call.argument<String>("language") ?: "en-US"
                        val voice = call.argument<String>("voice") ?: "default"
                        val speed = (call.argument<Double>("speed") ?: 1.0)
                        val model = call.argument<String>("model")
                        if (ttsService?.isLoaded() != true) {
                            systemTtsService?.synthesize(text, language, speed) { outcome ->
                                runOnUiThread {
                                    outcome.fold(
                                        onSuccess = result::success,
                                        onFailure = { result.error("TTS_FAILED", it.message, null) },
                                    )
                                }
                            } ?: result.error("TTS_FAILED", "System TTS is unavailable", null)
                        } else try {
                            val path = ttsService?.synthesize(
                                text = text,
                                language = language,
                                voice = voice,
                                speed = speed,
                                model = model,
                            )
                            result.success(path)
                        } catch (e: Throwable) {
                            result.error("TTS_FAILED", e.message, null)
                        }
                    }
                    "loadModel" -> {
                        val modelId = call.argument<String>("modelId") ?: ""
                        val manifestJson = call.argument<String>("manifestJson")
                        val localDirectory = call.argument<String>("localDirectory")
                        try {
                            val echoed = ttsService?.loadModel(
                                modelId = modelId,
                                manifestJson = manifestJson,
                                localDirectory = localDirectory,
                            ) ?: modelId
                            loadedTtsModelId = echoed
                            result.success(echoed)
                        } catch (e: Throwable) {
                            result.error("TTS_LOAD_FAILED", e.message, null)
                        }
                    }
                    "warmupModel" -> {
                        val modelId = call.argument<String>("modelId") ?: ""
                        try {
                            val elapsed = ttsService?.warmupModel(modelId) ?: 0
                            result.success(elapsed)
                        } catch (e: Throwable) {
                            result.error("TTS_WARMUP_FAILED", e.message, null)
                        }
                    }
                    "unloadModel" -> {
                        val modelId = call.argument<String>("modelId") ?: ""
                        ttsService?.unloadModel(modelId)
                        if (loadedTtsModelId == modelId) loadedTtsModelId = null
                        result.success(null)
                    }
                    "cancelSynthesis" -> {
                        val cancelled = ttsService?.cancelSynthesis() ?: false
                        result.success(cancelled)
                    }
                    "benchmarkSnapshot" -> {
                        result.success(ttsService?.benchmarkSnapshot())
                    }
                    "listAsrProfiles" -> {
                        result.success(asrService?.listInstalledProfiles())
                    }
                    "loadAsrProfile" -> {
                        val profileId = call.argument<String>("profileId") ?: ""
                        val languageCode = call.argument<String>("languageCode") ?: "auto"
                        try {
                            val ok = asrService?.loadProfile(profileId, languageCode) ?: false
                            result.success(ok)
                        } catch (e: Throwable) {
                            result.error("ASR_LOAD_FAILED", e.message, null)
                        }
                    }
                    "startAsrCapture" -> {
                        val language = call.argument<String>("preferredAsrLanguage") ?: "auto"
                        val profileId = call.argument<String>("profileId")
                        requestAudioPermissionAndStartCapture(language, profileId, result)
                    }
                    "stopAsrCapture" -> {
                        asrService?.stopCapture()
                        result.success(null)
                    }
                    "cancelAsrCapture" -> {
                        asrService?.cancelCapture()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS_CHANNEL)
            .setStreamHandler(this)
    }

    private fun requestAudioPermissionAndStart(language: String, result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.error("ASR_UNAVAILABLE", "Speech recognition is unavailable on this device.", null)
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            startListening(language)
            result.success(null)
            return
        }

        pendingLanguage = language
        pendingLocalCapture = false
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            AUDIO_PERMISSION_REQUEST,
        )
    }

    private fun requestAudioPermissionAndStartCapture(
        language: String,
        profileId: String?,
        result: MethodChannel.Result,
    ) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(asrService?.startCapture(language, profileId) ?: false)
            return
        }

        pendingLanguage = language
        pendingAsrProfileId = profileId
        pendingLocalCapture = true
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            AUDIO_PERMISSION_REQUEST,
        )
    }

    private fun startListening(language: String) {
        speechRecognizer?.destroy()
        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).also {
            it.setRecognitionListener(this)
            it.startListening(
                Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(
                        RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                        RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                    )
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                },
            )
        }
        emit("ASR_START", mapOf("language" to language))
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != AUDIO_PERMISSION_REQUEST) return

        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            if (pendingLocalCapture) {
                result.success(asrService?.startCapture(pendingLanguage, pendingAsrProfileId) ?: false)
            } else {
                startListening(pendingLanguage)
                result.success(null)
            }
        } else {
            result.error("MICROPHONE_PERMISSION_DENIED", "Microphone permission was denied.", null)
        }
        pendingLocalCapture = false
        pendingAsrProfileId = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onReadyForSpeech(params: Bundle?) = emit("ASR_READY")
    override fun onBeginningOfSpeech() = emit("ASR_SPEECH_START")
    override fun onRmsChanged(rmsdB: Float) = emit("ASR_LEVEL", mapOf("level" to rmsdB))
    override fun onBufferReceived(buffer: ByteArray?) = Unit
    override fun onEndOfSpeech() = emit("ASR_SPEECH_END")

    override fun onError(error: Int) {
        emit(
            "ASR_ERROR",
            mapOf("code" to error, "message" to recognitionErrorMessage(error)),
        )
    }

    override fun onResults(results: Bundle?) {
        val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
        emit("ASR_FINAL", mapOf("text" to matches.firstOrNull().orEmpty(), "alternatives" to matches))
    }

    override fun onPartialResults(partialResults: Bundle?) {
        val matches = partialResults
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            .orEmpty()
        emit("ASR_PARTIAL", mapOf("text" to matches.firstOrNull().orEmpty()))
    }

    override fun onEvent(eventType: Int, params: Bundle?) = Unit

    private fun emit(type: String, payload: Map<String, Any?> = emptyMap()) {
        eventSink?.success(mapOf("type" to type, "payload" to payload))
    }

    private fun recognitionErrorMessage(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "Audio recording error"
        SpeechRecognizer.ERROR_CLIENT -> "Recognition client error"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is missing"
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Network error"
        SpeechRecognizer.ERROR_NO_MATCH -> "No speech was recognized"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Recognizer is busy"
        SpeechRecognizer.ERROR_SERVER -> "Recognition service error"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was detected"
        else -> "Speech recognition failed ($error)"
    }

    override fun onDestroy() {
        systemTtsService?.shutdown()
        speechRecognizer?.destroy()
        speechRecognizer = null
        loadedTtsModelId?.let { ttsService?.unloadModel(it) }
        loadedTtsModelId = null
        asrService?.cancelCapture()
        // Unload every LLM model the runtime has resident rather than
        // guessing the manifest id; set is a copy so the iteration is
        // safe if `unloadLlmModel` mutates the underlying binding.
        val llmIds = loadedLlmModels.toList()
        llmIds.forEach { llmService?.unloadLlmModel(it) }
        loadedLlmModels.clear()
        super.onDestroy()
    }

    companion object {
        private const val COMMANDS_CHANNEL = "language_coach/ai_commands"
        private const val EVENTS_CHANNEL = "language_coach/ai_events"
        private const val AUDIO_PERMISSION_REQUEST = 4101
    }
}
