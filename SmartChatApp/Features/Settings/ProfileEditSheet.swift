import SwiftUI

struct ProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let profile: GatewayProfile?
    let onSave: (String, String, String, Int, String, Bool) -> Void

    @State private var name: String = ""
    @State private var colorTag: String = "#10A37F"
    @State private var host: String = ""
    @State private var port: String = "443"
    @State private var token: String = ""
    @State private var tlsEnabled: Bool = true

    private let colorOptions = ["#10A37F", "#3B82F6", "#F97316", "#EF4444", "#8B5CF6"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                        .foregroundColor(theme.textPrimary)

                    HStack {
                        Text("Color")
                        Spacer()
                        ForEach(colorOptions, id: \.self) { color in
                            Circle()
                                .fill(Color(hex: color))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(colorTag == color ? Color.primary : Color.clear, lineWidth: 2)
                                )
                                .onTapGesture {
                                    colorTag = color
                                }
                        }
                    }
                }

                Section("Connection") {
                    TextField("Host", text: $host)
                        .foregroundColor(theme.textPrimary)
                        .keyboardType(.URL)
                        .autocapitalization(.none)

                    TextField("Port", text: $port)
                        .foregroundColor(theme.textPrimary)
                        .keyboardType(.numberPad)

                    Toggle("Use TLS", isOn: $tlsEnabled)
                        .foregroundColor(theme.textPrimary)
                }

                Section("Authentication") {
                    SecureField("Token", text: $token)
                        .foregroundColor(theme.textPrimary)
                }
            }
            .navigationTitle(profile == nil ? "New Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let portInt = Int(port) ?? 443
                        onSave(name, colorTag, host, portInt, token, tlsEnabled)
                        dismiss()
                    }
                    .disabled(name.isEmpty || host.isEmpty || token.isEmpty)
                }
            }
            .onAppear {
                if let profile = profile {
                    name = profile.name
                    colorTag = profile.colorTag
                    host = profile.host
                    port = String(profile.port)
                    token = profile.token
                    tlsEnabled = profile.tlsEnabled
                }
            }
        }
    }
}
