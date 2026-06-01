import Foundation
import ScreenCaptureKit
import AppKit

/// Captures the screen as a PNG so the agent can *see* what the user is talking about.
/// Requires Screen Recording permission (prompted on first use). Downscaled to keep the
/// image (and its token cost) reasonable.
enum ScreenCapture {
    private static let maxWidth = 1512.0

    static func capturePNG() async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = displayUnderMouse(content.displays) ?? content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = min(1.0, maxWidth / Double(display.width))
            config.width = Int(Double(display.width) * scale)
            config.height = Int(Double(display.height) * scale)
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        } catch {
            NSLog("[Murmur] Screen capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func displayUnderMouse(_ displays: [SCDisplay]) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else { return nil }
        return displays.first { $0.displayID == number.uint32Value }
    }
}
