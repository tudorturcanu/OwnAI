import Foundation
import Metal

#if canImport(UIKit)
import UIKit
#endif

/// Centralizes conservative resource limits for older, low-memory devices.
/// Keep this value-based so the policy can be regression-tested without a
/// simulator pretending to have the RAM characteristics of a physical phone.
struct DeviceResourcePolicy: Equatable, Sendable {
    nonisolated static let lowMemoryThresholdBytes: UInt64 = 4_500_000_000

    let physicalMemoryBytes: UInt64
    let hardwareIdentifier: String
    let isPhone: Bool
    let isPad: Bool

    nonisolated init(
        physicalMemoryBytes: UInt64,
        hardwareIdentifier: String,
        isPhone: Bool,
        isPad: Bool
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.hardwareIdentifier = hardwareIdentifier
        self.isPhone = isPhone
        self.isPad = isPad
    }

    nonisolated var physicalMemoryGB: Double {
        Double(physicalMemoryBytes) / 1_073_741_824.0
    }

    /// iPhone 11-class devices need extra headroom for the KV cache, Metal
    /// scratch buffers, audio engines, images, and the rest of the app.
    nonisolated var isLowMemoryPhone: Bool {
        isPhone && physicalMemoryBytes <= Self.lowMemoryThresholdBytes
    }

    /// Largest advertised MLX weight footprint allowed on this device.
    /// Download size is only an approximation, so low-memory phones use a
    /// deliberately conservative hard ceiling until a model passes real-device
    /// readiness testing.
    ///
    /// iPad gets a larger share than iPhone: iPadOS grants a higher jetsam
    /// limit for the same RAM, the app carries the increased-memory-limit
    /// entitlement, and an iPad isn't competing with an incoming call or the
    /// camera. At 0.35 an 8 GB iPad was capped at 2.8 GB, which silently hid
    /// every 3–4 GB model even though `currentDeviceFit` rates them `.supported`
    /// on iPad up to 4.6 GB. 0.5 keeps the two ladders in agreement and still
    /// lands under `safePeakResidentMemoryBytes` once runtime overhead is added.
    nonisolated var usableModelBudgetGB: Double {
        if isLowMemoryPhone { return 1.0 }
        return physicalMemoryGB * (isPad ? 0.5 : 0.35)
    }

    nonisolated var maximumGenerationTokens: Int {
        isLowMemoryPhone ? 768 : .max
    }

    /// Keeps chat alive under heat or battery pressure by shortening the
    /// answer instead of letting the process accumulate a large KV cache.
    nonisolated func generationTokenLimit(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Int {
        var limit = maximumGenerationTokens
        if lowPowerMode {
            limit = min(limit, 768)
        }
        switch thermalState {
        case .critical:
            limit = min(limit, 384)
        case .serious:
            limit = min(limit, 512)
        case .fair, .nominal:
            break
        @unknown default:
            limit = min(limit, 512)
        }
        return limit
    }

    nonisolated var maximumContextTokens: Int {
        isLowMemoryPhone ? 2_048 : .max
    }

    nonisolated var mlxCacheLimitBytes: UInt64 {
        if isLowMemoryPhone { return 128 * 1_024 * 1_024 }
        let floorBytes: UInt64 = 64 * 1_024 * 1_024
        let capBytes: UInt64 = 384 * 1_024 * 1_024
        return min(max(physicalMemoryBytes / 20, floorBytes), capBytes)
    }

    /// Resident-memory ceiling for a measured model run. The remaining
    /// headroom is reserved for transient Metal allocations, attachments,
    /// keyboards, audio, and iOS itself.
    nonisolated var safePeakResidentMemoryBytes: UInt64 {
        let fraction = isLowMemoryPhone ? 0.68 : 0.78
        return UInt64(Double(physicalMemoryBytes) * fraction)
    }

    nonisolated func allowsMeasuredPeakResidentMemory(_ bytes: UInt64) -> Bool {
        bytes <= safePeakResidentMemoryBytes
    }

    nonisolated var shouldRunAutomaticModelBenchmarks: Bool {
        false
    }

    /// Optional AI work must not compete with the next user-visible answer on
    /// a constrained phone. The normal fallback conversation title remains.
    nonisolated var shouldRunPostResponseEnrichment: Bool {
        !isLowMemoryPhone
    }

    /// Fewer published stream snapshots reduce SwiftUI invalidation and
    /// repeated string copying without reducing model throughput.
    nonisolated var streamingUpdateInterval: TimeInterval {
        isLowMemoryPhone ? 0.14 : 0.08
    }

    /// MLX's Metal kernels require the Apple7 GPU family (A14/M1 and newer):
    /// they use native bfloat16 and SIMD-group matrix multiply, neither of
    /// which exists on A13-class GPUs (iPhone 11, iPhone SE 2nd gen). On those
    /// devices the shader compiler crashes and MLX aborts the process with an
    /// uncatchable fatal error ("Unable to load kernel affine_qmm_t_bfloat16…"),
    /// so MLX models must be gated off entirely before any GPU work starts.
    /// The simulator never runs MLX (compiled out), so it reports supported to
    /// keep the model catalog usable during development.
    nonisolated static let supportsMLXCompute: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple7)
        #endif
    }()

    nonisolated static var current: DeviceResourcePolicy {
        #if canImport(UIKit)
        let idiom = UIDevice.current.userInterfaceIdiom
        return DeviceResourcePolicy(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            hardwareIdentifier: resolveHardwareIdentifier(),
            isPhone: idiom == .phone,
            isPad: idiom == .pad
        )
        #else
        return DeviceResourcePolicy(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            hardwareIdentifier: resolveHardwareIdentifier(),
            isPhone: false,
            isPad: false
        )
        #endif
    }

    nonisolated private static func resolveHardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { charPointer in
                String(cString: charPointer)
            }
        }
    }
}
