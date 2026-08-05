// AEasy Display iOS viewer — the phone listens on :7355, the Mac dials in
// (usbmuxd only forwards Mac -> device, the inverse of adb reverse).
// Non-scene lifecycle on purpose: one window, one view controller, iOS 15 target.

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = ViewController()
        w.makeKeyAndVisible()
        window = w
        // FLAG_KEEP_SCREEN_ON equivalent. Prevents auto-lock only — a side-button
        // press still suspends the app; that limitation is documented, not fixable.
        application.isIdleTimerDisabled = true
        return true
    }
}
