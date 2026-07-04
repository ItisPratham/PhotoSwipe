import Foundation
import UIKit

/// Builds the support `mailto:` URL with the app + iOS version pre-filled in
/// the subject so incoming emails carry enough context to diagnose without a
/// round-trip. Address is finalized in the v2 spec.
enum ContactLink {
    static let supportAddress = "pratham_dev@icloud.com"

    static func makeSupportURL() -> URL? {
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let subject = "PhotoSwipe Support (v\(appVersion), iOS \(iosVersion))"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? subject
        return URL(string: "mailto:\(supportAddress)?subject=\(encoded)")
    }
}
