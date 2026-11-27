import Foundation
import UIKit

/// 设备信息与公共字段采集（iOS）。
final class DeviceInfo {

    static let shared = DeviceInfo()

    private let defaults = UserDefaults.standard
    private(set) var deviceId: String = ""
    private(set) var isNewInstall = false
    private(set) var sessionScope: String = ""

    var versionCode: Int {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard raw.range(of: "^[0-9]{1,10}$", options: .regularExpression) != nil,
              let code = Int(raw), code <= Int(Int32.max) else {
            preconditionFailure("CFBundleVersion must be an integer between 0 and 2147483647")
        }
        return code
    }

    func prepare() throws {
        let identity = try MpDeviceIdentity.prepare(defaults: defaults, secure: MpDeviceKeychain())
        deviceId = identity.deviceId
        isNewInstall = identity.isNewInstall
        sessionScope = identity.sessionScope
    }

    func event(appKey: String, eventName: String, params: [String: Any]) -> [String: Any] {
        let device = UIDevice.current
        let screen = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale

        return [
            "event_id": UUID().uuidString,
            "event_name": eventName,
            "event_time": Int(Date().timeIntervalSince1970 * 1000),
            "app_key": appKey,
            "device_id": deviceId,
            "platform": "ios",
            "report_source": "client",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "app_version_code": versionCode,
            "sdk_version": MpSdkVersion.version,
            "os_version": device.systemVersion,
            "device_model": modelName(),
            "device_type": device.userInterfaceIdiom == .pad ? "tablet" : "phone",
            "screen_resolution":
                "\(Int(screen.width * scale))x\(Int(screen.height * scale))",
            "device_language": Locale.current.identifier,
            "timezone_offset": -TimeZone.current.secondsFromGMT() / 60,
            "idfv": device.identifierForVendor?.uuidString ?? "",
            "params": params
        ]
    }

    private func modelName() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(value)))
        }
    }
}
