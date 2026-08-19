import Foundation

struct ModelInfo {
    let id: String
    static let releasedModels = [ModelInfo(id: "test")]
}

@main
enum ModelMemoryGateRegression {
    static func main() {
        let policy = DeviceResourcePolicy(
            physicalMemoryBytes: 4_000_000_000,
            hardwareIdentifier: "iPhone12,1",
            isPhone: true,
            isPad: false
        )
        let result = ModelQuickTestResult(
            modelID: "test",
            success: true,
            responseSnippet: "OK",
            durationMs: 100,
            timestamp: Date(),
            peakResidentMemoryBytes: 2_800_000_000,
            physicalMemoryBytes: 4_000_000_000,
            hardwareIdentifier: "iPhone12,1"
        )
        precondition(result.applies(to: policy))
        precondition(!policy.allowsMeasuredPeakResidentMemory(result.peakResidentMemoryBytes!))

        let otherDevice = DeviceResourcePolicy(
            physicalMemoryBytes: 8_000_000_000,
            hardwareIdentifier: "iPhone16,1",
            isPhone: true,
            isPad: false
        )
        precondition(!result.applies(to: otherDevice))

        let runtime = ModelRuntimeMemoryMeasurement(
            modelID: "test",
            peakResidentMemoryBytes: 2_700_000_000,
            physicalMemoryBytes: 4_000_000_000,
            hardwareIdentifier: "iPhone12,1",
            timestamp: Date(),
            operatingSystem: "test"
        )
        precondition(runtime.applies(to: policy))
        precondition(policy.allowsMeasuredPeakResidentMemory(runtime.peakResidentMemoryBytes))
        print("Measured model-memory gate regression passed")
    }
}
