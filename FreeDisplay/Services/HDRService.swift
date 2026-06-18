import CoreGraphics
import Foundation

/// Manages HDR mode for external displays via CoreDisplay private API.
@MainActor
final class HDRService: ObservableObject {
    static let shared = HDRService()
    private init() {}

    private typealias IsHDRFunc = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias SetHDRFunc = @convention(c) (CGDirectDisplayID, Bool) -> Void

    private lazy var handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
    }()

    private lazy var isHDRFunc: IsHDRFunc? = {
        guard let h = handle, let sym = dlsym(h, "CoreDisplay_Display_IsHDRModeEnabled") else { return nil }
        return unsafeBitCast(sym, to: IsHDRFunc.self)
    }()

    private lazy var setHDRFunc: SetHDRFunc? = {
        guard let h = handle, let sym = dlsym(h, "CoreDisplay_Display_SetHDRModeEnabled") else { return nil }
        return unsafeBitCast(sym, to: SetHDRFunc.self)
    }()

    /// Whether the CoreDisplay HDR API is available on this system.
    var isAvailable: Bool { isHDRFunc != nil && setHDRFunc != nil }

    /// Returns whether HDR is currently enabled for the given display.
    func isHDREnabled(for displayID: CGDirectDisplayID) -> Bool {
        isHDRFunc?(displayID) ?? false
    }

    /// Returns the maximum refresh rate at which HDR works for the display.
    /// Reads from UserDefaults per-display override, defaulting to 120Hz.
    func maxHDRRefreshRate(for displayID: CGDirectDisplayID) -> Double {
        let key = "fd.HDRMaxHz.\(displayID)"
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : 120.0
    }

    /// Sets the maximum HDR refresh rate override for a display.
    func setMaxHDRRefreshRate(_ hz: Double, for displayID: CGDirectDisplayID) {
        UserDefaults.standard.set(hz, forKey: "fd.HDRMaxHz.\(displayID)")
    }

    /// Enables or disables HDR. When enabling, will switch to a compatible refresh rate
    /// if current rate exceeds the HDR limit.
    func setHDR(enabled: Bool, for displayID: CGDirectDisplayID) {
        guard let setFunc = setHDRFunc else { return }

        if enabled {
            let maxHz = maxHDRRefreshRate(for: displayID)
            if let currentMode = CGDisplayCopyDisplayMode(displayID),
               currentMode.refreshRate > maxHz {
                // Switch to highest refresh rate <= maxHz at same resolution
                switchToCompatibleRate(displayID: displayID, maxHz: maxHz, mode: currentMode)
            }
        }

        setFunc(displayID, enabled)
    }

    private func switchToCompatibleRate(displayID: CGDirectDisplayID, maxHz: Double, mode: CGDisplayMode) {
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let allModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }

        // Find best mode: same resolution, same HiDPI status, highest rate <= maxHz
        let targetW = mode.width
        let targetH = mode.height
        let targetPW = mode.pixelWidth
        let isHiDPI = mode.pixelWidth > mode.width

        let candidate = allModes
            .filter {
                $0.width == targetW && $0.height == targetH &&
                ($0.pixelWidth > $0.width) == isHiDPI &&
                $0.pixelWidth == targetPW &&
                $0.refreshRate > 0 && $0.refreshRate <= maxHz
            }
            .max(by: { $0.refreshRate < $1.refreshRate })

        guard let best = candidate else { return }

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, displayID, best, nil)
        CGCompleteDisplayConfiguration(config, .permanently)
    }
}
