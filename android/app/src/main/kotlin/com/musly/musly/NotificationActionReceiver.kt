package com.kumaflow.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        Log.d("NotificationAction", "Received action: $action")
        when (action) {
            ACTION_LIKE -> AndroidAutoPlugin.sendCommand("like", null)
            ACTION_DISLIKE -> AndroidAutoPlugin.sendCommand("dislike", null)
            ACTION_STOP -> AndroidAutoPlugin.sendCommand("stop", null)
        }
    }

    companion object {
        const val ACTION_LIKE = "com.kumaflow.app.ACTION_LIKE"
        const val ACTION_DISLIKE = "com.kumaflow.app.ACTION_DISLIKE"
        const val ACTION_STOP = "com.kumaflow.app.ACTION_STOP"
    }
}
