import Flutter
import UIKit
import AVKit

/// Registers the AirPlay button platform view factory.
/// Call from AppDelegate after GeneratedPluginRegistrant.register().
func registerAirPlayButtonFactory(with registrar: FlutterPluginRegistrar) {
    let factory = AirPlayButtonFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "kumaflow/airplay_button")
}

// MARK: - Factory

class AirPlayButtonFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return AirPlayButtonView(frame: frame, args: args as? [String: Any])
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

// MARK: - Platform view

class AirPlayButtonView: NSObject, FlutterPlatformView {
    private let routePickerView: AVRoutePickerView

    init(frame: CGRect, args: [String: Any]?) {
        routePickerView = AVRoutePickerView(frame: frame)

        // Tint from Flutter args (passed as 0xAARRGGBB int), default white.
        if let colorValue = args?["tintColor"] as? Int {
            let a = CGFloat((colorValue >> 24) & 0xFF) / 255.0
            let r = CGFloat((colorValue >> 16) & 0xFF) / 255.0
            let g = CGFloat((colorValue >>  8) & 0xFF) / 255.0
            let b = CGFloat((colorValue      ) & 0xFF) / 255.0
            routePickerView.tintColor = UIColor(red: r, green: g, blue: b, alpha: a)
            routePickerView.activeTintColor = UIColor(red: r, green: g, blue: b, alpha: a)
        } else {
            routePickerView.tintColor = .white
            routePickerView.activeTintColor = .white
        }

        routePickerView.backgroundColor = .clear
        super.init()
    }

    func view() -> UIView {
        return routePickerView
    }
}
