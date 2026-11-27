import UIKit
import ObjectiveC

/// UIViewController 页面展示自动采集；SwiftUI 页面可继续调用 track("page_view")。
enum AutoPageTracking {
    static func start() { _ = install }
    private static let install: Void = {
        guard let original = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewDidAppear(_:))),
              let replacement = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.mpTrackingViewDidAppear(_:))) else { return }
        method_exchangeImplementations(original, replacement)
    }()
}

extension UIViewController {
    @objc func mpTrackingViewDidAppear(_ animated: Bool) {
        mpTrackingViewDidAppear(animated)
        guard !(self is UINavigationController), !(self is UITabBarController), !(self is UIAlertController) else { return }
        MpTracker.shared.track("page_view", params: ["page_name": String(describing: type(of: self))])
    }
}
