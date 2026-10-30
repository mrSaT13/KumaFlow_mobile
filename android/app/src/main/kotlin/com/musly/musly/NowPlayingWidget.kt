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
import android.widget.RemoteViews
import kotlinx.coroutines.*
import java.net.HttpURLConnection
import java.net.URL

class NowPlayingWidget : AppWidgetProvider() {

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
            ACTION_PLAY_PAUSE -> {
                sendCommandToFlutter(context, "playPause")
            }
            ACTION_NEXT -> {
                sendCommandToFlutter(context, "next")
            }
            ACTION_PREVIOUS -> {
                sendCommandToFlutter(context, "previous")
            }
            ACTION_LIKE -> {
                sendCommandToFlutter(context, "like")
            }
            ACTION_DISLIKE -> {
                sendCommandToFlutter(context, "dislike")
            }
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
        private const val ACTION_PLAY_PAUSE = "com.kumaflow.app.ACTION_PLAY_PAUSE"
        private const val ACTION_NEXT = "com.kumaflow.app.ACTION_NEXT"
        private const val ACTION_PREVIOUS = "com.kumaflow.app.ACTION_PREVIOUS"
        private const val ACTION_LIKE = "com.kumaflow.app.ACTION_LIKE"
        private const val ACTION_DISLIKE = "com.kumaflow.app.ACTION_DISLIKE"
        private const val ACTION_OPEN_APP = "com.kumaflow.app.ACTION_OPEN_APP"

        // SharedPreferences keys
        private const val PREFS_NAME = "kumaflow_widget"
        private const val KEY_TITLE = "widget_title"
        private const val KEY_ARTIST = "widget_artist"
        private const val KEY_IS_PLAYING = "widget_is_playing"
        private const val KEY_IS_LIKED = "widget_is_liked"
        private const val KEY_COVER_URL = "widget_cover_url"
        private const val KEY_POSITION = "widget_position"
        private const val KEY_DURATION = "widget_duration"
        private const val KEY_ACCENT_COLOR = "widget_accent_color"

        fun updateWidget(
            context: Context,
            title: String,
            artist: String,
            isPlaying: Boolean,
            coverUrl: String? = null,
            isLiked: Boolean = false,
            positionMs: Long = 0L,
            durationMs: Long = 0L,
            accentColor: Int = 0xFFFA243C.toInt()
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
                apply()
            }

            // Render immediately through AppWidgetManager — this is the
            // reliable path and does not depend on broadcast delivery.
            val appWidgetManager = AppWidgetManager.getInstance(context)
            val componentName = ComponentName(context, NowPlayingWidget::class.java)
            val widgetIds = appWidgetManager.getAppWidgetIds(componentName)
            for (widgetId in widgetIds) {
                renderWidget(context, appWidgetManager, widgetId, prefs)
            }

            // Also trigger widget update via broadcast (must include widget ids,
            // otherwise onReceive won't dispatch to onUpdate). Kept as a backup
            // so the provider state stays consistent.
            val intent = Intent(context, NowPlayingWidget::class.java).apply {
                action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, widgetIds)
            }
            context.sendBroadcast(intent)
        }

        fun updateAllWidgets(context: Context) {
            val appWidgetManager = AppWidgetManager.getInstance(context)
            val componentName = ComponentName(context, NowPlayingWidget::class.java)
            val widgetIds = appWidgetManager.getAppWidgetIds(componentName)

            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            for (widgetId in widgetIds) {
                renderWidget(context, appWidgetManager, widgetId, prefs)
            }

            val intent = Intent(context, NowPlayingWidget::class.java).apply {
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

            val views = RemoteViews(context.packageName, R.layout.widget_now_playing)

            // Set text
            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_artist, artist)

            // Play/Pause button
            val playPauseIcon = if (isPlaying) R.drawable.ic_widget_pause else R.drawable.ic_widget_play
            views.setImageViewResource(R.id.widget_play_pause, playPauseIcon)

            // Like (heart) button
            val likeIcon = if (isLiked) R.drawable.widget_button_like_filled else R.drawable.widget_button_like
            views.setImageViewResource(R.id.widget_like, likeIcon)

            // Progress bar — tint = accent color chosen in app (fixes "цвет виджета не совпадает с прогресс баром")
            if (durationMs > 0) {
                val progress = ((positionMs.toFloat() / durationMs.toFloat()) * 1000).toInt().coerceIn(0, 1000)
                views.setProgressBar(R.id.widget_progress, 1000, progress, false)
            } else {
                views.setProgressBar(R.id.widget_progress, 1000, 0, false)
            }
            try {
                // setProgressTintList requires API 31+ for RemoteViews, try via reflection/method
                if (android.os.Build.VERSION.SDK_INT >= 31) {
                    views.setColorStateList(R.id.widget_progress, "setProgressTintList", android.content.res.ColorStateList.valueOf(accentColor))
                    views.setColorStateList(R.id.widget_progress, "setProgressBackgroundTintList", android.content.res.ColorStateList.valueOf(0x40FFFFFF))
                }
            } catch (_: Exception) {}

            // Time
            views.setTextViewText(R.id.widget_current_time, formatTime(positionMs))
            views.setTextViewText(R.id.widget_total_time, formatTime(durationMs))

            // Set click listeners
            val playPauseIntent = Intent(context, NowPlayingWidget::class.java).apply {
                action = ACTION_PLAY_PAUSE
            }
            views.setOnClickPendingIntent(
                R.id.widget_play_pause,
                PendingIntent.getBroadcast(
                    context, 0, playPauseIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )

            val nextIntent = Intent(context, NowPlayingWidget::class.java).apply {
                action = ACTION_NEXT
            }
            views.setOnClickPendingIntent(
                R.id.widget_next,
                PendingIntent.getBroadcast(
                    context, 1, nextIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )

            val prevIntent = Intent(context, NowPlayingWidget::class.java).apply {
                action = ACTION_PREVIOUS
            }
            views.setOnClickPendingIntent(
                R.id.widget_previous,
                PendingIntent.getBroadcast(
                    context, 2, prevIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )

            val likeIntent = Intent(context, NowPlayingWidget::class.java).apply {
                action = ACTION_LIKE
            }
            views.setOnClickPendingIntent(
                R.id.widget_like,
                PendingIntent.getBroadcast(
                    context, 4, likeIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )

            val dislikeIntent = Intent(context, NowPlayingWidget::class.java).apply {
                action = ACTION_DISLIKE
            }
            views.setOnClickPendingIntent(
                R.id.widget_dislike,
                PendingIntent.getBroadcast(
                    context, 5, dislikeIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )

            // Open app on widget tap
            val openAppIntent = Intent(context, NowPlayingWidget::class.java).apply {
                action = ACTION_OPEN_APP
            }
            views.setOnClickPendingIntent(
                R.id.widget_container,
                PendingIntent.getBroadcast(
                    context, 3, openAppIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )

            // Load cover art in background (downscaled to avoid RemoteViews OOM)
            if (coverUrl != null) {
                loadCoverArt(context, coverUrl) { bitmap ->
                    try {
                        if (bitmap != null) {
                            // Downscale to 512 max to stay under 6.5MB limit (512*512*4 ~1MB)
                            val scaled = if (bitmap.width > 512 || bitmap.height > 512) {
                                val ratio = minOf(512f / bitmap.width, 512f / bitmap.height)
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
                            // Fallback without cover if still too large
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
                        // Local file/asset artwork (offline mode)
                        context.contentResolver?.openInputStream(uri)?.use {
                            BitmapFactory.decodeStream(it)
                        } ?: BitmapFactory.decodeFile(uri.path)
                    } else {
                        // Remote artwork over HTTP(S)
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

        private fun formatTime(ms: Long): String {
            val totalSec = ms / 1000
            val m = totalSec / 60
            val s = totalSec % 60
            return String.format("%d:%02d", m, s)
        }
    }
}