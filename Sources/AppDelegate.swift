import UIKit
import WebKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let service = ChatService.shared

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        service.start()

        let web = WebViewController()
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = web
        window?.makeKeyAndVisible()
        return true
    }
}
