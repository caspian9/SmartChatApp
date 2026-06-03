import SwiftUI

struct EntryCard: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 48))
                    .foregroundColor(.white)

                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
            .frame(width: 150, height: 120)
            .background(Color(hex: "1E1E1E"))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}