import Foundation

@main
enum LowMemoryPolicyRegression {
    static func main() {
        let iPhone11 = DeviceResourcePolicy(
            physicalMemoryBytes: 4_000_000_000,
            hardwareIdentifier: "iPhone12,1",
            isPhone: true,
            isPad: false
        )
        precondition(iPhone11.isLowMemoryPhone)
        precondition(iPhone11.usableModelBudgetGB == 1.0)
        precondition(iPhone11.maximumGenerationTokens == 768)
        precondition(iPhone11.generationTokenLimit(lowPowerMode: false, thermalState: .nominal) == 768)
        precondition(iPhone11.generationTokenLimit(lowPowerMode: false, thermalState: .critical) == 384)
        precondition(iPhone11.maximumContextTokens == 2_048)
        precondition(iPhone11.mlxCacheLimitBytes == 128 * 1_024 * 1_024)
        precondition(iPhone11.safePeakResidentMemoryBytes == 2_720_000_000)
        precondition(!iPhone11.shouldRunAutomaticModelBenchmarks)
        precondition(!iPhone11.shouldRunPostResponseEnrichment)
        precondition(iPhone11.streamingUpdateInterval == 0.14)

        let modernPhone = DeviceResourcePolicy(
            physicalMemoryBytes: 8_000_000_000,
            hardwareIdentifier: "iPhone16,1",
            isPhone: true,
            isPad: false
        )
        precondition(!modernPhone.isLowMemoryPhone)
        precondition(modernPhone.usableModelBudgetGB > 2.5)
        precondition(modernPhone.maximumGenerationTokens == .max)
        precondition(modernPhone.generationTokenLimit(lowPowerMode: true, thermalState: .nominal) == 768)
        precondition(modernPhone.generationTokenLimit(lowPowerMode: false, thermalState: .serious) == 512)
        precondition(modernPhone.maximumContextTokens == .max)
        precondition(!modernPhone.shouldRunAutomaticModelBenchmarks)
        precondition(modernPhone.shouldRunPostResponseEnrichment)
        precondition(modernPhone.streamingUpdateInterval == 0.08)

        print("Low-memory device policy regression passed")
    }
}
