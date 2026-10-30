package com.felnanuke.google_cast

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.util.Log
import android.widget.MediaController
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.mediarouter.app.MediaRouteButton
import androidx.mediarouter.app.MediaRouteControllerDialog
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import com.google.android.gms.cast.LaunchOptions
import com.google.android.gms.cast.framework.CastButtonFactory
import com.google.android.gms.cast.framework.CastStateListener
import java.util.concurrent.Executors

private const val TAG = "CastContext"

class CastContextMethodChannel : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private val discoveryManager = DiscoveryManagerMethodChannel()
    private lateinit var sessionManagerMethodChannel: SessionManagerMethodChannel
    private lateinit var nearbyWifiDevicesPermissionLauncher: ActivityResultLauncher<String>
    private val executor = Executors.newSingleThreadExecutor()


    //FlutterPlugin
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {

        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.felnanuke.google_cast.context")
        channel.setMethodCallHandler(this)
        discoveryManager.onAttachedToEngine(binding)
        sessionManagerMethodChannel = SessionManagerMethodChannel(discoveryManager)
        sessionManagerMethodChannel.onAttachedToEngine(binding)

    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }


    // MethodCallHandler
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setSharedInstance" -> setSharedInstance(call.arguments, result)
            else -> result.notImplemented()
        }
    }

    private fun setupActivityResult(activity: ComponentActivity) {
        nearbyWifiDevicesPermissionLauncher =
            activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { isGranted: Boolean ->
                if (isGranted) {
                    Log.d(TAG, "NEARBY_WIFI_DEVICES granted")
                } else {
                    Log.w(TAG, "NEARBY_WIFI_DEVICES denied — Cast discovery may fail")
                }
            }
    }


    private fun setSharedInstance(arguments: Any?, result: MethodChannel.Result) {
        try {
            val map = arguments as HashMap<*, *>
            val appId = (map["appId"] as? String)?.takeIf { it.isNotBlank() } ?: "CC1AD845"
            val optionsBuilder = CastOptions.Builder()
            optionsBuilder.setReceiverApplicationId(appId)
            val launcherOptions = LaunchOptions.Builder().setAndroidReceiverCompatible(true).build()
            optionsBuilder.setLaunchOptions(launcherOptions)
            optionsBuilder.setResumeSavedSession(true)
            optionsBuilder.setEnableReconnectionService(true)
            GoogleCastOptionsProvider.options = optionsBuilder.build()
            try {
                CastContext.getSharedInstance(appContext).sessionManager.addSessionManagerListener(sessionManagerMethodChannel)
                Log.d(TAG, "setSharedInstance OK appId=$appId")
            } catch (e: Exception) {
                Log.e(TAG, "CastContext.getSharedInstance failed (Play Services missing?): ${e.message}")
            }
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "setSharedInstance error: ${e.message}")
            result.error("CAST_INIT_FAILED", e.message, null)
        }
    }

}