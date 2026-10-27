import Foundation
#if os(iOS)
import UIKit
#endif

enum Haptics {
    static func tap(enabled: Bool) {
        guard enabled else { return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
        #endif
    }

    static func milestone(enabled: Bool) {
        guard enabled else { return }
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
