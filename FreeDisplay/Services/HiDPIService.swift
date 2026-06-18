import Foundation
import CoreGraphics
import IOKit

@MainActor
final class HiDPIService: @unchecked Sendable {
    static let shared = HiDPIService()
    private init() {}

    private var refreshTask: Task<Void, Never>?

    private let overridesBase = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides")

    // MARK: - Public API

    /// Checks whether HiDPI is enabled for the given display via plist override.
    func isHiDPIEnabled(for displayID: CGDirectDisplayID, vendor: UInt32, product: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: overridePlistURL(vendor: vendor, product: product).path)
    }

    /// Checks whether HiDPI is enabled for the given display via plist override only.
    func isHiDPIEnabled(vendor: UInt32, product: UInt32) -> Bool {
        let plistURL = overridePlistURL(vendor: vendor, product: product)
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Enables HiDPI for an external display via plist override.
    /// Requires display reconnect (or reboot) to apply.
    ///
    /// Returns nil on success, or an error string on failure.
    func enableHiDPI(for displayID: CGDirectDisplayID,
                     vendor: UInt32,
                     product: UInt32,
                     nativeWidth: Int,
                     nativeHeight: Int) async -> String? {
        return enableHiDPIPlist(vendor: vendor, product: product,
                                nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Legacy single-path enable (plist only).
    func enableHiDPI(vendor: UInt32, product: UInt32, nativeWidth: Int, nativeHeight: Int) -> String? {
        enableHiDPIPlist(vendor: vendor, product: product,
                         nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Disables HiDPI for an external display by removing the plist override.
    func disableHiDPI(for displayID: CGDirectDisplayID,
                      vendor: UInt32,
                      product: UInt32) -> String? {
        return disableHiDPIPlist(vendor: vendor, product: product)
    }

    /// Legacy single-path disable (plist only).
    func disableHiDPI(vendor: UInt32, product: UInt32) -> String? {
        disableHiDPIPlist(vendor: vendor, product: product)
    }

    /// Refreshes availableModes on the given DisplayInfo after enabling HiDPI.
    func refreshModes(for display: DisplayInfo) {
        refreshTask?.cancel()
        let physicalID = display.displayID

        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            async let modes = Task.detached(priority: .userInitiated) {
                DisplayMode.availableModes(for: physicalID)
            }.value
            async let current = Task.detached(priority: .userInitiated) {
                DisplayMode.currentMode(for: physicalID)
            }.value
            display.availableModes = await modes
            display.currentDisplayMode = await current
        }
    }

    // MARK: - Plist Override

    private func enableHiDPIPlist(vendor: UInt32, product: UInt32,
                                   nativeWidth: Int, nativeHeight: Int) -> String? {
        let dirPath = overrideDir(vendor: vendor).path
        let plistPath = overridePlistURL(vendor: vendor, product: product).path

        let scaledModes = generateScaledModes(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        let plist: [String: Any] = [
            "scale-resolutions": scaledModes
        ]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return "Failed to generate plist data"
        }

        // Write to a temp file first, then use privileged helper to move it
        let tmpPath = NSTemporaryDirectory() + "fd_hidpi_override.plist"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
        } catch {
            return "Failed to write temp file: \(error.localizedDescription)"
        }

        // Use AppleScript to get admin privileges for writing to /Library/Displays/
        if let err = executePrivilegedCommand("mkdir -p '\(dirPath)' && cp '\(tmpPath)' '\(plistPath)'") {
            return err
        }

        // Clean up temp file
        try? FileManager.default.removeItem(atPath: tmpPath)

        // Attempt to trigger display mode re-enumeration via IOServiceRequestProbe
        triggerDisplayReenumeration(vendor: vendor, product: product)

        return nil
    }

    private func disableHiDPIPlist(vendor: UInt32, product: UInt32) -> String? {
        let plistPath = overridePlistURL(vendor: vendor, product: product).path
        guard FileManager.default.fileExists(atPath: plistPath) else { return nil }

        if let err = executePrivilegedCommand("rm -f '\(plistPath)'") {
            return err
        }
        return nil
    }

    // MARK: - Helpers

    /// Executes a shell command with administrator privileges via AppleScript.
    /// Returns nil on success, or an error message on failure.
    private func executePrivilegedCommand(_ command: String) -> String? {
        let script = """
            do shell script "\(command)" with administrator privileges
            """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return "Failed to create AppleScript"
        }
        appleScript.executeAndReturnError(&error)
        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            if msg.contains("canceled") || msg.contains("Cancel") {
                return "User cancelled authorization"
            }
            return "Admin authorization failed: \(msg)"
        }
        return nil
    }

    private func triggerDisplayReenumeration(vendor: UInt32, product: UInt32) {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let cfDict = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() else {
                continue
            }
            let dict = cfDict as NSDictionary

            let serviceVendor: UInt32
            let serviceProduct: UInt32

            if let v = dict["DisplayVendorID"] as? UInt32 {
                serviceVendor = v
            } else if let v = dict["DisplayVendorID"] as? Int {
                serviceVendor = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
            } else { continue }

            if let p = dict["DisplayProductID"] as? UInt32 {
                serviceProduct = p
            } else if let p = dict["DisplayProductID"] as? Int {
                serviceProduct = UInt32(bitPattern: Int32(truncatingIfNeeded: p))
            } else { continue }

            guard serviceVendor == vendor && serviceProduct == product else { continue }

            IOServiceRequestProbe(service, 0)
            break
        }
    }

    private func overrideDir(vendor: UInt32) -> URL {
        overridesBase
            .appendingPathComponent(String(format: "DisplayVendorID-%x", vendor))
    }

    private func overridePlistURL(vendor: UInt32, product: UInt32) -> URL {
        overrideDir(vendor: vendor)
            .appendingPathComponent(String(format: "DisplayProductID-%x", product))
    }

    private func generateScaledModes(nativeWidth: Int, nativeHeight: Int) -> [Data] {
        // macOS scale-resolutions format (16 bytes big-endian per entry):
        //   bytes 0-3: backing width (2× logical for HiDPI)
        //   bytes 4-7: backing height
        //   bytes 8-11: flags (0x1 = HiDPI)
        //   bytes 12-15: extra flags (0x00200000 for HiDPI modes)
        // This 16-byte format is what one-key-hidpi and BetterDisplay use.

        var seen: Set<String> = []
        var result: [Data] = []

        func addEntry(backingW: Int, backingH: Int, flags: UInt32, extra: UInt32) {
            let key = "\(backingW)x\(backingH)f\(flags)e\(extra)"
            guard seen.insert(key).inserted else { return }
            var bytes = [UInt8](repeating: 0, count: 16)
            bytes[0] = UInt8((backingW >> 24) & 0xFF)
            bytes[1] = UInt8((backingW >> 16) & 0xFF)
            bytes[2] = UInt8((backingW >> 8) & 0xFF)
            bytes[3] = UInt8(backingW & 0xFF)
            bytes[4] = UInt8((backingH >> 24) & 0xFF)
            bytes[5] = UInt8((backingH >> 16) & 0xFF)
            bytes[6] = UInt8((backingH >> 8) & 0xFF)
            bytes[7] = UInt8(backingH & 0xFF)
            bytes[8] = UInt8((flags >> 24) & 0xFF)
            bytes[9] = UInt8((flags >> 16) & 0xFF)
            bytes[10] = UInt8((flags >> 8) & 0xFF)
            bytes[11] = UInt8(flags & 0xFF)
            bytes[12] = UInt8((extra >> 24) & 0xFF)
            bytes[13] = UInt8((extra >> 16) & 0xFF)
            bytes[14] = UInt8((extra >> 8) & 0xFF)
            bytes[15] = UInt8(extra & 0xFF)
            result.append(Data(bytes))
        }

        func addHiDPI(_ logicalW: Int, _ logicalH: Int) {
            addEntry(backingW: logicalW * 2, backingH: logicalH * 2,
                     flags: 0x00000001, extra: 0x00200000)
        }

        func addNonHiDPI(_ w: Int, _ h: Int) {
            addEntry(backingW: w, backingH: h,
                     flags: 0x00000009, extra: 0x00A00000)
        }

        // HiDPI logical modes (backing = 2× logical, GPU-composited)
        let hiDPIModes: [(Int, Int)] = [
            (nativeWidth, nativeHeight),           // "looks like native" HiDPI
            (2560, 1440), (2048, 1152), (1920, 1080),
            (1760, 990), (1680, 945), (1600, 900),
            (1440, 810), (1360, 765), (1280, 720), (1024, 576),
            (nativeWidth / 2, nativeHeight / 2)
        ]
        for (w, h) in hiDPIModes {
            addHiDPI(w, h)
        }

        // Non-HiDPI scaled entries (helps macOS enumerate the full list)
        let nonHiDPIModes: [(Int, Int)] = [
            (2048, 1152), (1920, 1080), (1680, 945),
            (1440, 810), (1280, 720), (1024, 576)
        ]
        for (w, h) in nonHiDPIModes {
            addNonHiDPI(w, h)
        }

        return result
    }
}
