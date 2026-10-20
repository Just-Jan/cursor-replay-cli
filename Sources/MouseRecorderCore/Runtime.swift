import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import Synchronization

public final class Cancellation: Sendable {
    private let value = Mutex<String?>(nil)
    public init() {}
    public var reason: String? { value.withLock { $0 } }
    public var isCancelled: Bool { reason != nil }
    public func cancel(_ reason: String) { value.withLock { if $0 == nil { $0 = reason } } }
}

public struct Permissions: Sendable {
    public let accessibility: Bool
    public let listening: Bool
    public let posting: Bool

    public init() {
        accessibility = AXIsProcessTrusted()
        listening = CGPreflightListenEventAccess()
        posting = CGPreflightPostEventAccess()
    }

    public static var terminal: String {
        switch ProcessInfo.processInfo.environment["TERM_PROGRAM"] {
        case "Apple_Terminal": "Terminal (/System/Applications/Utilities/Terminal.app)"
        case "iTerm.app": "iTerm"
        case "ghostty": "Ghostty"
        case "vscode": "the application hosting this terminal (for example Visual Studio Code)"
        case let name?: name
        default: "the terminal application running cursor-replay"
        }
    }

    public var missing: [String] {
        var result: [String] = []
        if !accessibility { result.append("Accessibility") }
        if !listening { result.append("Input Monitoring") }
        if !posting { result.append("Post Event Access (controlled by Accessibility)") }
        return result
    }

    public static func require() throws {
        let permissions = Permissions()
        guard permissions.missing.isEmpty else {
            if !permissions.listening { _ = CGRequestListenEventAccess() }
            if !permissions.posting { _ = CGRequestPostEventAccess() }
            throw MouseRecorderError("""
            Missing: \(permissions.missing.joined(separator: ", ")).
            In System Settings > Privacy & Security, enable the missing permissions for \(terminal).
            If macOS lists this executable separately, enable that entry too.
            Fully quit and reopen the terminal after granting access, then rerun the compiled executable.
            """)
        }
    }
}

public struct MachClock: Sendable {
    let numerator: UInt64
    let denominator: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numerator = UInt64(info.numer)
        denominator = UInt64(info.denom)
    }

    init(numerator: UInt64, denominator: UInt64) {
        self.numerator = numerator
        self.denominator = denominator
    }

    // Full-width arithmetic avoids losing timestamp precision after long uptimes.
    static func multiplyDivide(_ value: UInt64, _ multiplier: UInt64, _ divisor: UInt64) -> UInt64 {
        let product = value.multipliedFullWidth(by: multiplier)
        return divisor.dividingFullWidth(product).quotient
    }

    public func nanoseconds(at ticks: UInt64) -> UInt64 {
        Self.multiplyDivide(ticks, numerator, denominator)
    }

    public var nowNS: UInt64 { nanoseconds(at: mach_absolute_time()) }

    func eventTimestamp(_ raw: UInt64, near referenceNS: UInt64) -> (ns: UInt64, unit: EventTimestampUnit) {
        let product = raw.multipliedFullWidth(by: numerator)
        guard product.high < denominator else { return (raw, .nanoseconds) }
        let converted = denominator.dividingFullWidth(product).quotient
        let directDistance = raw >= referenceNS ? raw - referenceNS : referenceNS - raw
        let convertedDistance = converted >= referenceNS ? converted - referenceNS : referenceNS - converted
        return convertedDistance < directDistance ? (converted, .machAbsoluteTicks) : (raw, .nanoseconds)
    }
    var maximumTick: UInt64 {
        let product = UInt64.max.multipliedFullWidth(by: denominator)
        return product.high < numerator ? numerator.dividingFullWidth(product).quotient : UInt64.max
    }

    public func ticks(forNS ns: UInt64) throws -> UInt64 {
        let product = ns.multipliedFullWidth(by: denominator)
        guard product.high < numerator else { throw MouseRecorderError("Playback deadline exceeds the clock range.") }
        let result = numerator.dividingFullWidth(product)
        if result.remainder == 0 { return result.quotient }
        let rounded = result.quotient.addingReportingOverflow(1)
        guard !rounded.overflow else { throw MouseRecorderError("Playback deadline exceeds the clock range.") }
        return rounded.partialValue
    }

    public static func scaledOffset(_ ns: UInt64, speed: Double) throws -> UInt64 {
        guard speed.isFinite, speed > 0 else { throw MouseRecorderError("Speed must be finite and greater than zero.") }
        if speed == 1 { return ns }
        let scaled = (Double(ns) / speed).rounded()
        guard scaled.isFinite, scaled >= 0, scaled < Double(UInt64.max) else {
            throw MouseRecorderError("The requested speed produces a timestamp outside the supported range.")
        }
        return UInt64(scaled)
    }

    func wait(until target: UInt64, cancellation: Cancellation) throws -> Bool {
        let spin = try ticks(forNS: 100_000)
        let slice = try ticks(forNS: 2_000_000)
        while !cancellation.isCancelled {
            let now = mach_absolute_time()
            if now >= target { return true }
            let remaining = target - now
            if remaining > spin {
                let wake = now + min(remaining - spin, slice)
                let status = mach_wait_until(wake)
                guard status == KERN_SUCCESS || status == KERN_ABORTED else {
                    throw MouseRecorderError("mach_wait_until failed with status \(status).")
                }
            }
        }
        return false
    }
}

public func countdown(_ seconds: Int, cancellation: Cancellation, onTick: ((Int) -> Void)? = nil) {
    guard seconds > 0 else { return }
    for remaining in stride(from: seconds, through: 1, by: -1) {
        guard !cancellation.isCancelled else { return }
        if let onTick {
            onTick(remaining)
        } else {
            print("Starting in \(remaining)...")
            fflush(nil)
        }
        let end = ProcessInfo.processInfo.systemUptime + 1
        while !cancellation.isCancelled, ProcessInfo.processInfo.systemUptime < end {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
