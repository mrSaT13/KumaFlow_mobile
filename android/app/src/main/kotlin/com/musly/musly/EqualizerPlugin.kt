package com.kumaflow.app

import android.media.audiofx.Equalizer
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlin.math.ln
import kotlin.math.roundToInt

/**
 * Real system equalizer bound to just_audio's ExoPlayer audio session.
 *
 * Dart side (EqualizerService) used to only persist band values — the sound
 * never changed ("fake EQ"). This plugin attaches Android's audiofx Equalizer
 * to the player's audio session, so sliders actually shape the sound.
 *
 * The UI has 10 fixed bands; the device usually exposes 5. Each device band
 * is computed by log-frequency interpolation between the UI bands.
 * Non-Android platforms report supported=false and the UI shows a hint.
 */
class EqualizerPlugin : MethodCallHandler {

    companion object {
        private const val TAG = "EqualizerPlugin"
        private const val METHOD_CHANNEL = "com.kumaflow.app/equalizer"

        // Center freqs (Hz) of the 10 UI bands in EqualizerService. Keep in sync.
        private val UI_FREQS = doubleArrayOf(
            32.0, 64.0, 125.0, 250.0, 500.0,
            1000.0, 2000.0, 4000.0, 8000.0, 16000.0
        )

        @JvmStatic
        fun registerWith(flutterEngine: FlutterEngine) {
            val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            channel.setMethodCallHandler(EqualizerPlugin())
            Log.d(TAG, "EqualizerPlugin registered")
        }
    }

    private var equalizer: Equalizer? = null
    private var boundSessionId: Int = 0
    private var lastEnabled: Boolean = false
    private var lastBandsDb: List<Double> = List(10) { 0.0 }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "init" -> result.success(initCaps())
            "apply" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                @Suppress("UNCHECKED_CAST")
                val raw = call.argument<List<Any>>("bandsDb") ?: emptyList()
                val bands = raw.mapNotNull { (it as? Number)?.toDouble() }
                result.success(applyBands(enabled, bands))
            }
            "release" -> {
                releaseEffect()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun initCaps(): Map<String, Any> {
        val session = audioSessionId()
        if (session == 0) {
            return mapOf("supported" to true, "ready" to false, "numBands" to 0)
        }
        return try {
            ensureEffect(session)
            val eq = equalizer ?: return mapOf("supported" to true, "ready" to false, "numBands" to 0)
            val range = eq.bandLevelRange
            val centers = (0 until eq.numberOfBands).map { eq.getCenterFreq(it.toShort()) / 1000 }.toList()
            mapOf(
                "supported" to true,
                "ready" to true,
                "numBands" to eq.numberOfBands.toInt(),
                "lowerMb" to range[0].toInt(),
                "upperMb" to range[1].toInt(),
                "centerFreqs" to centers
            )
        } catch (e: Exception) {
            Log.w(TAG, "init failed: ${e.message}")
            mapOf("supported" to false, "ready" to false, "numBands" to 0)
        }
    }

    private fun applyBands(enabled: Boolean, uiBands: List<Double>): Map<String, Any> {
        lastEnabled = enabled
        lastBandsDb = normalizeUiBands(uiBands)
        val session = audioSessionId()
        if (session == 0) {
            // Player not ready yet — values are stored and applied on the next
            // call (every track start re-pushes from Dart side).
            return mapOf("ok" to false, "reason" to "no_session")
        }
        return try {
            ensureEffect(session)
            val eq = equalizer ?: return mapOf("ok" to false, "reason" to "no_effect")
            val centers = (0 until eq.numberOfBands).map { eq.getCenterFreq(it.toShort()) / 1000.0 }.toDoubleArray()
            val levels = mapUiToDevice(lastBandsDb, centers, eq.bandLevelRange)
            for (i in levels.indices) {
                try {
                    eq.setBandLevel(i.toShort(), levels[i])
                } catch (e: Exception) {
                    Log.w(TAG, "setBandLevel($i) failed: ${e.message}")
                }
            }
            eq.enabled = enabled
            mapOf("ok" to true, "bands" to eq.numberOfBands.toInt())
        } catch (e: Exception) {
            Log.w(TAG, "apply failed: ${e.message}")
            mapOf("ok" to false, "reason" to (e.message ?: "error"))
        }
    }

    private fun ensureEffect(session: Int) {
        if (equalizer != null && boundSessionId == session) return
        releaseEffect()
        val eq = Equalizer(0, session)
        equalizer = eq
        boundSessionId = session
        // Re-apply last known state on the fresh effect instance.
        try {
            val centers = (0 until eq.numberOfBands).map { eq.getCenterFreq(it.toShort()) / 1000.0 }.toDoubleArray()
            val levels = mapUiToDevice(lastBandsDb, centers, eq.bandLevelRange)
            for (i in levels.indices) {
                try {
                    eq.setBandLevel(i.toShort(), levels[i])
                } catch (_: Exception) {
                }
            }
            eq.enabled = lastEnabled
        } catch (e: Exception) {
            Log.w(TAG, "re-apply failed: ${e.message}")
        }
    }

    private fun releaseEffect() {
        try {
            equalizer?.release()
        } catch (_: Exception) {
        }
        equalizer = null
        boundSessionId = 0
    }

    private fun normalizeUiBands(input: List<Double>): List<Double> {
        if (input.size == 10) return input.map { it.coerceIn(-12.0, 12.0) }
        val out = MutableList(10) { 0.0 }
        for (i in input.indices.take(10)) out[i] = input[i].coerceIn(-12.0, 12.0)
        return out
    }

    /** Log-frequency interpolation of the 10 UI dB values onto device bands. */
    private fun mapUiToDevice(uiDb: List<Double>, devFreqsHz: DoubleArray, range: ShortArray): ShortArray {
        val xs = UI_FREQS.map { ln(it) }
        val lo = range[0].toInt()
        val hi = range[1].toInt()
        return ShortArray(devFreqsHz.size) { i ->
            val x = ln(devFreqsHz[i].coerceAtLeast(1.0))
            val db = when {
                x <= xs.first() -> uiDb.first()
                x >= xs.last() -> uiDb.last()
                else -> {
                    var v = 0.0
                    for (j in 0 until xs.size - 1) {
                        if (x >= xs[j] && x <= xs[j + 1]) {
                            val t = (x - xs[j]) / (xs[j + 1] - xs[j])
                            v = uiDb[j] + t * (uiDb[j + 1] - uiDb[j])
                            break
                        }
                    }
                    v
                }
            }
            (db * 100.0).roundToInt().coerceIn(lo, hi).toShort()
        }
    }

    /** Audio session of just_audio's internal ExoPlayer via reflection (same as PitchPlugin). */
    private fun audioSessionId(): Int {
        return try {
            val handlerClass = Class.forName("com.ryanheise.just_audio.MethodCallHandlerImpl")
            val instanceField = handlerClass.getDeclaredField("instance")
            instanceField.isAccessible = true
            val handlerInstance = instanceField.get(null) ?: return 0

            val playersField = handlerClass.getDeclaredField("players")
            playersField.isAccessible = true
            @Suppress("UNCHECKED_CAST")
            val players = playersField.get(handlerInstance) as? Map<Long, Any> ?: return 0
            if (players.isEmpty()) return 0

            val audioPlayer = players.values.first()
            val exoPlayer = findExoPlayer(audioPlayer) ?: return 0
            val m = exoPlayer.javaClass.getMethod("getAudioSessionId")
            (m.invoke(exoPlayer) as? Int) ?: 0
        } catch (_: Exception) {
            0
        }
    }

    private fun findExoPlayer(audioPlayer: Any): Any? {
        try {
            val playerField = audioPlayer.javaClass.getDeclaredField("player")
            playerField.isAccessible = true
            val candidate = playerField.get(audioPlayer)
            if (isExoPlayer(candidate)) return candidate
        } catch (_: NoSuchFieldException) {
        }
        for (field in audioPlayer.javaClass.declaredFields) {
            try {
                field.isAccessible = true
                val candidate = field.get(audioPlayer)
                if (isExoPlayer(candidate)) return candidate
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun isExoPlayer(candidate: Any?): Boolean {
        if (candidate == null) return false
        val clazz = candidate.javaClass
        return clazz.name.contains("ExoPlayer") ||
                clazz.interfaces.any { it.name.contains("ExoPlayer") }
    }
}
