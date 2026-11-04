import FirebaseCore
import FirebaseMessaging
import SwiftUI
import UserNotifications
import WidgetKit

@main
struct MiniemApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PanelModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PanelView()
                .environmentObject(model)
                .onOpenURL { url in model.open(url) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.resume() } }
                }
        }
    }
}

/// Push: Firebase turns the APNs token into an FCM token, which is what Home Assistant
/// sends to. A push carries no UI, only "the cards changed"; the app then fetches them and
/// tells WidgetKit to redraw. A focus push also carries a visible, time-sensitive
/// notification, the closest iOS lets an app get to bringing itself up.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {

    /// Builds without GoogleService-Info.plist still work, just without push.
    static var pushAvailable: Bool { Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        guard Self.pushAvailable else { return true }
        FirebaseApp.configure()
        Messaging.messaging().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, fcmToken != Store.pushToken else { return }
        Store.pushToken = fcmToken
        Task { _ = await HAClient.register(force: true) }
    }

    /// Silent pushes. iOS gives this about 30 seconds and rations how often it runs.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard Store.configured else { return .noData }
        let result = await PanelModel.shared.refresh()
        WidgetCenter.shared.reloadAllTimelines()
        return result ? .newData : .failed
    }

    /// A focus notification arriving while the app is open: no banner, just the panel.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await PanelModel.shared.refresh()
        return []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await PanelModel.shared.refresh()
    }
}
