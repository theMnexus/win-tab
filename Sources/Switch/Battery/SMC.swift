import IOKit

/// Reads the battery's temperature sensors from the System Management Controller, for Macs whose
/// battery controller doesn't report a temperature in the registry. Read-only, no root needed.
enum SMC {
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    /// Padded to C's 12 bytes so the fields after it line up with the kernel's struct.
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, attributes: UInt8 = 0, pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0 }
    private struct Param {
        var key: UInt32 = 0
        var version = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let handleEvent: UInt32 = 2
    private static let readKey: UInt8 = 5
    private static let getKeyInfo: UInt8 = 9
    private static let batteryKeys = ["TB0T", "TB1T", "TB2T"]

    /// Warmest battery sensor in °C, or nil when there's no SMC or no battery sensor.
    static func batteryTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }
        return batteryKeys.compactMap { read($0, connection) }.filter { $0 > 0 && $0 < 100 }.max()
    }

    private nonisolated(unsafe) static var cache: (value: Double?, at: Date) = (nil, .distantPast)
    private static let cacheFor: TimeInterval = 120

    /// `batteryTemperature()` at most every two minutes; the battery warms slowly. Main thread only.
    static func cachedBatteryTemperature() -> Double? {
        if Date().timeIntervalSince(cache.at) > cacheFor { cache = (batteryTemperature(), Date()) }
        return cache.value
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func call(_ input: inout Param, _ connection: io_connect_t) -> Param? {
        var output = Param()
        var size = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(connection, handleEvent, &input, MemoryLayout<Param>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private static func read(_ key: String, _ connection: io_connect_t) -> Double? {
        var input = Param()
        input.key = fourCC(key)
        input.command = getKeyInfo
        guard let info = call(&input, connection) else { return nil }
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.command = readKey
        guard let out = call(&input, connection) else { return nil }
        let b = out.bytes
        switch info.keyInfo.dataType {
        case fourCC("sp78"): return Double(Int16(bitPattern: UInt16(b.0) << 8 | UInt16(b.1))) / 256
        case fourCC("flt "): return Double(Float(bitPattern: UInt32(b.0) | UInt32(b.1) << 8 | UInt32(b.2) << 16 | UInt32(b.3) << 24))
        default: return nil
        }
    }

    #if DEBUG
    /// The struct handed to the kernel must match its 80-byte C layout.
    static func selfCheck() -> [String] {
        MemoryLayout<Param>.size == 80 ? [] : ["SMC param is \(MemoryLayout<Param>.size) bytes, want 80"]
    }
    #endif
}
