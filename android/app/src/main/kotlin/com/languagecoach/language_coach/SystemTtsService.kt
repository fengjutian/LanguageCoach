package com.languagecoach.language_coach

import android.content.Context
import android.media.AudioAttributes
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/** Synthesizes speech with Android's installed TTS engine when no local model is loaded. */
class SystemTtsService(context: Context, private val cacheDirectory: File) :
    TextToSpeech.OnInitListener {
    private val callbacks = ConcurrentHashMap<String, (Result<String>) -> Unit>()
    private val tts = TextToSpeech(context.applicationContext, this)
    @Volatile private var ready = false
    @Volatile private var initError: String? = null

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (!ready) initError = "Android text-to-speech engine failed to initialize"
        if (ready) {
            tts.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String) = Unit
                override fun onDone(utteranceId: String) = finish(utteranceId, null)
                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String) =
                    finish(utteranceId, "Android text-to-speech synthesis failed")
                override fun onError(utteranceId: String, errorCode: Int) =
                    finish(utteranceId, "Android text-to-speech synthesis failed ($errorCode)")
            })
        }
    }

    fun synthesize(
        text: String,
        language: String,
        speed: Double,
        callback: (Result<String>) -> Unit,
    ) {
        if (!ready) {
            callback(Result.failure(IllegalStateException(initError ?: "Android text-to-speech is still initializing")))
            return
        }
        val locale = localeFor(language)
        val availability = tts.setLanguage(locale)
        if (availability == TextToSpeech.LANG_MISSING_DATA ||
            availability == TextToSpeech.LANG_NOT_SUPPORTED) {
            callback(Result.failure(IllegalStateException("No system voice is installed for ${locale.toLanguageTag()}")))
            return
        }
        tts.setSpeechRate(speed.toFloat())
        cacheDirectory.mkdirs()
        val utteranceId = "system_${System.nanoTime()}"
        val target = File(cacheDirectory, "$utteranceId.wav")
        callbacks[utteranceId] = callback
        val status = tts.synthesizeToFile(text, Bundle(), target, utteranceId)
        if (status != TextToSpeech.SUCCESS) {
            callbacks.remove(utteranceId)
            callback(Result.failure(IllegalStateException("Android text-to-speech rejected the request")))
        }
    }

    private fun finish(utteranceId: String, error: String?) {
        val callback = callbacks.remove(utteranceId) ?: return
        val target = File(cacheDirectory, "$utteranceId.wav")
        if (error != null || !target.isFile || target.length() <= 44L) {
            callback(Result.failure(IllegalStateException(error ?: "System TTS produced empty audio")))
        } else {
            callback(Result.success(target.absolutePath))
        }
    }

    fun shutdown() {
        callbacks.clear()
        tts.stop()
        tts.shutdown()
    }

    private fun localeFor(language: String): Locale {
        val normalized = language.replace('_', '-')
        val tag = when (normalized.lowercase()) {
            "en" -> "en-US"
            "zh" -> "zh-CN"
            "ja" -> "ja-JP"
            "ko" -> "ko-KR"
            "fr" -> "fr-FR"
            "de" -> "de-DE"
            "es" -> "es-ES"
            "ru" -> "ru-RU"
            else -> normalized
        }
        return Locale.forLanguageTag(tag)
    }
}
