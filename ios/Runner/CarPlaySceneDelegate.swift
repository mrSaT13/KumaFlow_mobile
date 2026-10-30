// CARPLAY SUPPORT TEMPORARILY DISABLED
// (requires com.apple.developer.carplay-audio entitlement approved by Apple)
// To re-enable: remove the #if false / #endif wrappers
// import CarPlay
// import MediaPlayer
// import AVFoundation
#if false

/// CarPlay integration for KumaFlow.
///
/// Uses CPNowPlayingTemplate (iOS 14+) which is automatically populated from
/// MPNowPlayingInfoCenter — already maintained by iOSSystemPlugin. A browsing
/// list template lets users jump to common actions.
@available(iOS 14.0, *)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    var interfaceController: CPInterfaceController?

    // MARK: - Scene lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        setUpRootTemplate()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Template setup

    private func setUpRootTemplate() {
        let nowPlaying = CPNowPlayingTemplate.shared
        configureNowPlayingButtons(nowPlaying)

        // Build a simple tab bar: Now Playing + a quick-action list
        let tabBar = CPTabBarTemplate(templates: [
            wrapInNavigation(nowPlaying, title: "Now Playing"),
            buildActionsTemplate(),
        ])

        interfaceController?.setRootTemplate(tabBar, animated: false, completion: nil)
    }

    private func configureNowPlayingButtons(_ template: CPNowPlayingTemplate) {
        // Shuffle and repeat buttons rendered automatically by CarPlay from
        // MPNowPlayingInfoPropertyPlaybackQueueIdentifier; the built-in
        // skip-forward/back buttons come from MPRemoteCommandCenter which
        // iOSSystemPlugin already registers.
        template.isAlbumArtistButtonEnabled = true
        template.isUpNextButtonEnabled = false
    }

    private func buildActionsTemplate() -> CPListTemplate {
        let playPauseItem = CPListItem(
            text: "Play / Pause",
            detailText: "Toggle playback",
            image: UIImage(systemName: "playpause.fill")
        )
        playPauseItem.handler = { [weak self] _, completion in
            MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { _ in .success }
            NotificationCenter.default.post(name: .kumaflowCarPlayTogglePlayPause, object: nil)
            completion()
        }

        let skipNextItem = CPListItem(
            text: "Skip Next",
            detailText: "Play the next track",
            image: UIImage(systemName: "forward.fill")
        )
        skipNextItem.handler = { [weak self] _, completion in
            NotificationCenter.default.post(name: .kumaflowCarPlaySkipNext, object: nil)
            completion()
        }

        let skipPrevItem = CPListItem(
            text: "Skip Previous",
            detailText: "Play the previous track",
            image: UIImage(systemName: "backward.fill")
        )
        skipPrevItem.handler = { [weak self] _, completion in
            NotificationCenter.default.post(name: .kumaflowCarPlaySkipPrevious, object: nil)
            completion()
        }

        let section = CPListSection(items: [playPauseItem, skipNextItem, skipPrevItem])
        let list = CPListTemplate(title: "KumaFlow", sections: [section])
        list.tabImage = UIImage(systemName: "music.note.list")
        list.tabTitle = "Actions"
        return list
    }

    // MARK: - Helpers

    private func wrapInNavigation(_ template: CPTemplate, title: String) -> CPNavigationTemplate {
        let nav = CPNavigationTemplate(rootTemplate: template)
        return nav
    }
}

// MARK: - Notification names used by CarPlaySceneDelegate + iOSSystemPlugin

extension Notification.Name {
    static let kumaflowCarPlayTogglePlayPause = Notification.Name("kumaflowCarPlayTogglePlayPause")
    static let kumaflowCarPlaySkipNext        = Notification.Name("kumaflowCarPlaySkipNext")
    static let kumaflowCarPlaySkipPrevious    = Notification.Name("kumaflowCarPlaySkipPrevious")
}
#endif // CARPLAY SUPPORT TEMPORARILY DISABLED
