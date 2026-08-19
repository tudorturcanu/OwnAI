import Foundation

struct RuntimePerformanceStatus: Equatable {
    let message: String
    let symbolName: String

    static func current(
        appLowPowerMode: Bool,
        recentMemoryPressure: Bool
    ) -> RuntimePerformanceStatus? {
        if recentMemoryPressure {
            return RuntimePerformanceStatus(
                message: String(localized: "Using a lighter configuration to keep your iPhone responsive."),
                symbolName: "memorychip"
            )
        }
        switch ProcessInfo.processInfo.thermalState {
        case .critical, .serious:
            return RuntimePerformanceStatus(
                message: String(localized: "Performance is reduced while your device cools down."),
                symbolName: "thermometer.high"
            )
        default:
            break
        }
        if appLowPowerMode || ProcessInfo.processInfo.isLowPowerModeEnabled {
            return RuntimePerformanceStatus(
                message: String(localized: "Low Power Mode is using shorter, lighter responses."),
                symbolName: "battery.25percent"
            )
        }
        return nil
    }
}
