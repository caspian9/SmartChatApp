import Foundation
import OpenClawKit
import UIKit

final class DeviceService: @unchecked Sendable {
    func status() -> OpenClawDeviceStatusPayload {
        let batteryLevel = UIDevice.current.batteryLevel
        let batteryState = UIDevice.current.batteryState
        let thermalState = ProcessInfo.processInfo.thermalState

        let battery = OpenClawBatteryStatusPayload(
            level: batteryLevel >= 0 ? Double(batteryLevel) : nil,
            state: batteryStateString(batteryState),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )

        let thermal = OpenClawThermalStatusPayload(
            state: thermalStateString(thermalState)
        )

        // Storage - get from FileManager
        var storage = OpenClawStorageStatusPayload(totalBytes: 0, freeBytes: 0, usedBytes: 0)
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let total = attrs[.systemSize] as? Int64,
           let free = attrs[.systemFreeSize] as? Int64 {
            storage = OpenClawStorageStatusPayload(
                totalBytes: total,
                freeBytes: free,
                usedBytes: total - free
            )
        }

        // Network - basic implementation
        let network = OpenClawNetworkStatusPayload(
            status: .satisfied,
            isExpensive: false,
            isConstrained: false,
            interfaces: []
        )

        let uptime = ProcessInfo.processInfo.systemUptime

        return OpenClawDeviceStatusPayload(
            battery: battery,
            thermal: thermal,
            storage: storage,
            network: network,
            uptimeSeconds: uptime
        )
    }

    func info() -> OpenClawDeviceInfoPayload {
        let device = UIDevice.current
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        return OpenClawDeviceInfoPayload(
            deviceName: device.name,
            modelIdentifier: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            appVersion: version,
            appBuild: build,
            locale: Locale.current.identifier
        )
    }

    private func batteryStateString(_ state: UIDevice.BatteryState) -> OpenClawBatteryState {
        switch state {
        case .unknown: return .unknown
        case .unplugged: return .unplugged
        case .charging: return .charging
        case .full: return .full
        @unknown default: return .unknown
        }
    }

    private func thermalStateString(_ state: ProcessInfo.ThermalState) -> OpenClawThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}