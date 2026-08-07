import ApplicationServices
import CoreGraphics

// The AX API exposes no public way to get a window's CGWindowID, which
// ScreenCaptureKit needs to identify a window. This private symbol is the
// standard bridge (alt-tab, Rectangle et al. use it); it resolves at link
// time, so its disappearance would be a build failure, not a silent bug.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

func cgWindowID(for element: AXUIElement) -> CGWindowID? {
    var windowID: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else {
        return nil
    }
    return windowID
}
