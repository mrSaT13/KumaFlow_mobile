package com.kumaflow.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import kotlinx.coroutines.*
import java.net.HttpURLConnection
import java.net.URL

/**
 * KumaFlow compact widget v2 (~64dp, 4x1): cover + title/artist +
 * thin progress + prev/play/next/like + offline badge.
 * v1 (NowPlayingWidget) is untouched; both read the same prefs so they
 * always show the same track.
 */
class WidgetCompact : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        for (appWidgetId in appWidgetIds) {
            renderWidget(context, appWidgetManager, appWidgetId, prefs)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        when (intent.action) {
            ACTION_PLAY_PAUSE -> sendCommandToFlutter(context, "playPause")
            ACTION_NEXT -> sendCommandToFlutter(context, "next")
            ACTION_PREVIOUS -> sendCommandToFlutter(context, "previous")
            ACTION_LIKE -> sendCommandToFlutter(context, "like")
            ACTION_OPEN_APP -> {
                val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                if (launchIntent != null) {
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    context.startActivity(launchIntent)
                }
            }
        }
    }

    private fun sendCommandToFlutter(context: Context, command: String) {
        val intent = Intent("com.kumaflow.app.WIDGET_COMMAND").apply {
            putExtra("command", command)
            setPackage(context.packageName)
        }
        context.sendBroadcast(intent)
    }

    companion object {
        private const val ACTION_PLAY_PAUSE = "com.kumaflow.app.COMPACT_PLAY_PAUSE"
        private const val ACTION_NEXT = "com.kumaflow.app.COMPACT_NEXT"
        private const val ACTION_PREVIOUS = "com.kumaflow.app.COMPACT_PREVIOUS"
        private const val ACTION_LIKE = "com.kumaflow.app.COMPACT_LIKE"
        private const val ACTION_OPEN_APP = "com.kumaflow.app.COMPACT_OPEN_APP"

        // Same prefs file as v1 — both widgets stay in sync.
        private const val PREFS_NAME = "kumaflow_widget"
        private const val KEY_TITLE = "widget_title"
        private const val KEY_ARTIST = "widget_artist"
        private const val KEY_IS_PLAYING = "widget_is_playing"
        private const val KEY_IS_LIKED = "widget_is_liked"
        private const val KEY_COVER_URL = "widget_cover_url"
        private const val KEY_POSITION = "widget_position"
        private const val KEY_DURATION = "widget_duration"
        private const val KEY_ACCENT_COLOR = "widget_accent_color"
        private const val KEY_OFFLINE = "widget_offline"

        fun updateWidget(
            context: Context,
            title: String,
            artist: String,
            isPlaying: Boolean,
            coverUrl: String? = null,
            isLiked: Boolean = false,
            positionMs: Long = 0L,
            durationMs: Long = 0L,
            accentColor: Int = 0xFFFA243C.toInt(),
            isOffline: Boolean = false
        ) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().apply {
                putString(KEY_TITLE, title)
                putString(KEY_ARTIST, artist)
                putBoolean(KEY_IS_PLAYING, isPlaying)
                putBoolean(KEY_IS_LIKED, isLiked)
                putString(KEY_COVER_URL, coverUrl)
                putLong(KEY_POSITION, positionMs)
                putLong(KEY_DURATION, durationMs)
                putInt(KEY_ACCENT_COLOR, accentColor)
                putBoolean(KEY_OFFLINE, isOffline)
                apply()
            }

            val appWidgetManager = AppWidgetManager.getInstance(context)
            val componentName = ComponentName(context, WidgetCompact::class.java)
            val widgetIds = appWidgetManager.getAppWidgetIds(componentName)
            for (widgetId in widgetIds) {
                renderWidget(context, appWidgetManager, widgetId, prefs)
            }

            val intent = Intent(context, WidgetCompact::class.java).apply {
                action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, widgetIds)
            }
            context.sendBroadcast(intent)
        }

        private fun renderWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int,
            prefs: android.content.SharedPreferences
        ) {
            val title = prefs.getString(KEY_TITLE, "No Track") ?: "No Track"
            val artist = prefs.getString(KEY_ARTIST, "") ?: ""
            val isPlaying = prefs.getBoolean(KEY_IS_PLAYING, false)
            val isLiked = prefs.getBoolean(KEY_IS_LIKED, false)
            val coverUrl = prefs.getString(KEY_COVER_URL, null)
            val positionMs = prefs.getLong(KEY_POSITION, 0L)
            val durationMs = prefs.getLong(KEY_DURATION, 0L)
            val accentColor = prefs.getInt(KEY_ACCENT_COLOR, 0xFFFA243C.toInt())
            val isOffline = prefs.getBoolean(KEY_OFFLINE, false)

            val views = RemoteViews(context.packageName, R.layout.widget_compact)

            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_artist, artist)
            views.setViewVisibility(
                R.id.widget_offline_badge,
                if (isOffline) View.VISIBLE else View.GONE
            )

            val playPauseIcon = if (isPlaying) R.drawable.ic_widget_pause else R.drawable.ic_widget_play
            views.setImageViewResource(R.id.widget_play_pause, playPauseIcon)

            val likeIcon = if (isLiked) R.drawable.widget_button_like_filled else R.drawable.widget_button_like
            views.setImageViewResource(R.id.widget_like, likeIcon)

            if (durationMs > 0) {
                val progress = ((positionMs.toFloat() / durationMs.toFloat()) * 1000).toInt().coerceIn(0, 1000)
                views.setProgressBar(R.id.widget_progress, 1000, progress, false)
            } else {
                views.setProgressBar(R.id.widget_progress, 1000, 0, false)
            }
            try {
                if (android.os.Build.VERSION.SDK_INT >= 31) {
                    views.setColorStateList(R.id.widget_progress, "setProgressTintList", android.content.res.ColorStateList.valueOf(accentColor))
                    views.setColorStateList(R.id.widget_progress, "setProgressBackgroundTintList", android.content.res.ColorStateList.valueOf(0x40FFFFFF))
                }
            } catch (_: Exception) {}

            // Distinct request codes (10+) so PendingIntents never clash with v1.
            val playPauseIntent = Intent(context, WidgetCompact::class.java).apply { action = ACTION_PLAY_PAUSE }
            views.setOnClickPendingIntent(
                R.id.widget_play_pause,
                PendingIntent.getBroadcast(context, 10, playPauseIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            )

            val nextIntent = Intent(context, WidgetCompact::class.java).apply { action = ACTION_NEXT }
            views.setOnClickPendingIntent(
                R.id.widget_next,
                PendingIntent.getBroadcast(context, 11, nextIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            )

            val prevIntent = Intent(context, WidgetCompact::class.java).apply { action = ACTION_PREVIOUS }
            views.setOnClickPendingIntent(
                R.id.widget_previous,
                PendingIntent.getBroadcast(context, 12, prevIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            )

            val likeIntent = Intent(context, WidgetCompact::class.java).apply { action = ACTION_LIKE }
            views.setOnClickPendingIntent(
                R.id.widget_like,
                PendingIntent.getBroadcast(context, 14, likeIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            )

            val openAppIntent = Intent(context, WidgetCompact::class.java).apply { action = ACTION_OPEN_APP }
            views.setOnClickPendingIntent(
                R.id.widget_container,
                PendingIntent.getBroadcast(context, 13, openAppIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            )

            if (coverUrl != null) {
                loadCoverArt(context, coverUrl) { bitmap ->
                    try {
                        if (bitmap != null) {
                            // Compact cover is 48dp — 256px is plenty, keeps RemoteViews small.
                            val scaled = if (bitmap.width > 256 || bitmap.height > 256) {
                                val ratio = minOf(256f / bitmap.width, 256f / bitmap.height)
                                Bitmap.createScaledBitmap(bitmap, (bitmap.width * ratio).toInt(), (bitmap.height * ratio).toInt(), true)
                            } else bitmap
                            views.setImageViewBitmap(R.id.widget_cover_art, scaled)
                            if (scaled != bitmap) bitmap.recycle()
                        } else {
                            views.setImageViewResource(R.id.widget_cover_art, R.drawable.ic_widget_default_cover)
                        }
                        try {
                            appWidgetManager.updateAppWidget(appWidgetId, views)
                        } catch (e: IllegalArgumentException) {
                            views.setImageViewResource(R.id.widget_cover_art, R.drawable.ic_widget_default_cover)
                            appWidgetManager.updateAppWidget(appWidgetId, views)
                        }
                    } catch (e: Exception) {
                        try { appWidgetManager.updateAppWidget(appWidgetId, views) } catch (_: Exception) {}
                    }
                }
            } else {
                views.setImageViewResource(R.id.widget_cover_art, R.drawable.ic_widget_default_cover)
                try { appWidgetManager.updateAppWidget(appWidgetId, views) } catch (_: Exception) {}
            }
        }

        private fun loadCoverArt(
            context: Context,
            url: String,
            callback: (Bitmap?) -> Unit
        ) {
            CoroutineScope(Dispatchers.IO).launch {
                try {
                    val uri = Uri.parse(url)
                    val bitmap = if (uri.scheme == "file" || uri.scheme == "content") {
                        context.contentResolver?.openInputStream(uri)?.use {
                            BitmapFactory.decodeStream(it)
                        } ?: BitmapFactory.decodeFile(uri.path)
                    } else {
                        val imageUrl = URL(url)
                        val connection = imageUrl.openConnection() as HttpURLConnection
                        connection.doInput = true
                        connection.connectTimeout = 8000
                        connection.readTimeout = 8000
                        connection.instanceFollowRedirects = true
                        connection.connect()
                        val inputStream = connection.inputStream
                        val bmp = BitmapFactory.decodeStream(inputStream)
                        inputStream.close()
                        connection.disconnect()
                        bmp
                    }
                    withContext(Dispatchers.Main) {
                        callback(bitmap)
                    }
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) {
                        callback(null)
                    }
                }
            }
        }
    }
}
