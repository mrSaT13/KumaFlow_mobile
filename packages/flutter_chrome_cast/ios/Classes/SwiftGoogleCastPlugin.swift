import Flutter
import UIKit
import GoogleCast

public class SwiftGoogleCastPlugin:GCKCastContext, GCKLoggerDelegate, FlutterPlugin, UIApplicationDelegate    {
    let kDebugLoggingEnabled = true
    private var channel : FlutterMethodChannel?
   
    
    public override var sessionManager: GCKSessionManager {
        GCKCastContext.sharedInstance().sessionManager
    }
    public override var discoveryManager: GCKDiscoveryManager {
        GCKCastContext.sharedInstance().discoveryManager
    }

    //MARK: - RegisterMethodChannel
  public static func register(with registrar: FlutterPluginRegistrar) {
   
      let instance = SwiftGoogleCastPlugin()
      
      instance.channel = FlutterMethodChannel(name: "google_cast.context", binaryMessenger: registrar.messenger())
    
      registrar.addMethodCallDelegate(instance, channel: instance.channel!)
      FGCSessionManagerMethodChannel.register(with: registrar)
      FGCSessionMethodChannel.register(with: registrar)
      FGCDiscoveryManagerMethodChannel.register(with: registrar)
      RemoteMediaClienteMethodChannel.register(with: registrar)
      
      
      
    
  }

    
    //MARK: - FlutterPlugin
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {

      switch call.method {
      case "setSharedInstanceWithOptions":
          setSharedInstanceWithOption(arguments: call.arguments as! Dictionary<String, Any>, result: result)
          break
      default:
          break
      }

      
  }
    
    
    
    
    private func setSharedInstanceWithOption(arguments: Dictionary<String, Any> ,result: @escaping FlutterResult){
        let option = GCKCastOptions.fromMap(arguments)
        GCKCastContext.setSharedInstanceWith(option)
        GCKLogger.sharedInstance().consoleLoggingEnabled = false
        GCKLogger.sharedInstance().delegate = self
        discoveryManager.add(FGCDiscoveryManagerMethodChannel.instance)
        sessionManager.add(FGCSessionManagerMethodChannel.instance)
        // Do NOT call discoveryManager.startDiscovery() here.
        // Discovery is started/stopped from Dart (cast_button.dart) only while
        // the device-picker dialog is open, preventing continuous background
        // mDNS scanning that heats the device in idle.
    }
    
    
    //MARK: - GCKLoggerDelegate

    public func logMessage(_ message: String,
                      at level: GCKLoggerLevel,
                      fromFunction function: String,
                      location: String) {
        // Suppress Cast SDK verbose logging in release; keep for debug builds.
        #if DEBUG
        if level == .error || level == .warning {
            print("[Cast] " + function + " - " + message)
        }
        #endif
    }
    
  

    
    
    
    
    
    
}




