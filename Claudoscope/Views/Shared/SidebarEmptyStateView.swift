import SwiftUI

struct SidebarEmptyStateView: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(Typography.body)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}
