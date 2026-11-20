#if os(iOS)
import UIKit

public extension UIView {
    /// Session replay draws this view and its whole subtree as one grey
    /// placeholder (no text, no image, no child), or paints it black in a
    /// screenshot. The token `cohorly-no-capture` in
    /// `accessibilityIdentifier` has the same effect (the path React Native
    /// reaches). Text inputs are always masked anyway; this hides anything
    /// else.
    @IBInspectable var cohorlyNoCapture: Bool {
        get { cohorlyReplayNoCaptureFlag }
        set { cohorlyReplayNoCaptureFlag = newValue }
    }
}
#endif
