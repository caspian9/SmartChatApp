import SwiftUI

struct DeviceInfoView: View {
    private var deviceName: String {
        ConfigurationManager.shared.isConfigured ? "Hai's iPhone" : "Not Connected"
    }

    var body: some View {
        Text("当前设备: \(deviceName)")
            .font(.caption)
            .foregroundColor(.gray)
    }
}
