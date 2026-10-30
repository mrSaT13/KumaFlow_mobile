package com.kumaflow.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// ВАЖНО: наследуемся от AudioServiceFragmentActivity, а не от голого
// FlutterFragmentActivity. Иначе AudioServicePlugin.onAttachedToActivity
// создаёт ВТОРОЙ движок "audio_service_engine" с executeDartEntrypoint(main)
// — два main() в одном PID с разницей 3мс (факт из logcat: Boot#95808 +
// Boot#95811), двойной сплэш и война за БД. С общим движком main() один.
class MainActivity : AudioServiceFragmentActivity() {
    private var widgetCommandChannel: MethodChannel? = null
    private var widgetCommandReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.plugins.add(AndroidAutoPlugin)

        flutterEngine.plugins.add(AndroidSystemPlugin)

        flutterEngine.plugins.add(BluetoothAvrcpPlugin)

        flutterEngine.plugins.add(SamsungIntegrationPlugin)

        // Register lyrics plugin for lock screen lyrics support
        LyricsPlugin.registerWith(flutterEngine)

        // Register pitch plugin for ExoPlayer pitch control
        PitchPlugin.registerWith(flutterEngine)

        // Register equalizer plugin: real system EQ on the player session
        EqualizerPlugin.registerWith(flutterEngine)

        // Register Dolby Atmos plugin for device-capability detection
        DolbyAtmosPlugin.registerWith(flutterEngine, this)

        // Widget command channel
        widgetCommandChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.kumaflow/widgets")
        widgetCommandChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateNowPlaying" -> {
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val coverUrl = call.argument<String>("albumArtUrl")
                    val isLiked = call.argument<Boolean>("isLiked") ?: false
                    val positionMs = (call.argument<Number>("positionMs")?.toLong()) ?: 0L
                    val durationMs = (call.argument<Number>("durationMs")?.toLong()) ?: 0L
                    val accentColor = (call.argument<Number>("accentColor")?.toInt()) ?: 0xFFFA243C.toInt()
                    val isOffline = call.argument<Boolean>("isOffline") ?: false

                    NowPlayingWidget.updateWidget(
                        this, title, artist, isPlaying, coverUrl,
                        isLiked, positionMs, durationMs, accentColor
                    )
                    // Compact v2 shows the same track (shared prefs stay in sync).
                    WidgetCompact.updateWidget(
                        this, title, artist, isPlaying, coverUrl,
                        isLiked, positionMs, durationMs, accentColor, isOffline
                    )
                    result.success(true)
                }
                "updateRecentTracks" -> {
                    // Handle recent tracks update if needed
                    result.success(true)
                }
                "showWidget" -> {
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Listen for widget commands
        widgetCommandReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val command = intent.getStringExtra("command")
                if (command != null) {
                    widgetCommandChannel?.invokeMethod(command, null)
                }
            }
        }
        val filter = IntentFilter("com.kumaflow.app.WIDGET_COMMAND")
        ContextCompat.registerReceiver(
            this,
            widgetCommandReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    override fun onDestroy() {
        widgetCommandReceiver?.let {
            unregisterReceiver(it)
        }
        super.onDestroy()
    }
}