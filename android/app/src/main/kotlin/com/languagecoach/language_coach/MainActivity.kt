package com.languagecoach.language_coach

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), EventChannel.StreamHandler, RecognitionListener {
    private var eventSink: EventChannel.EventSink? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingLanguage: String = "en-US"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, COMMANDS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
                    "generate", "synthesize" -> result.error(
                        "MODEL_NOT_CONFIGURED",
                        "Native model runtime is not configured yet.",
                        null,
                    )
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
            startListening(pendingLanguage)
            result.success(null)
        } else {
            result.error("MICROPHONE_PERMISSION_DENIED", "Microphone permission was denied.", null)
        }
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
        speechRecognizer?.destroy()
        speechRecognizer = null
        super.onDestroy()
    }

    companion object {
        private const val COMMANDS_CHANNEL = "language_coach/ai_commands"
        private const val EVENTS_CHANNEL = "language_coach/ai_events"
        private const val AUDIO_PERMISSION_REQUEST = 4101
    }
}
