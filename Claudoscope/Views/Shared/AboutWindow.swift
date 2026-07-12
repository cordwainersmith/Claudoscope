import SwiftUI

// MARK: - About Window

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var year: String {
        String(Calendar.current.component(.year, from: Date()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let nsImage = loadAppIcon() {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("claudoscope")
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                        Text("v\(version)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text("session explorer for claude code")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                MonoRow(label: "home", value: "claudoscope.com",
                        url: "https://claudoscope.com/")
                MonoRow(label: "source", value: "cordwainersmith/Claudoscope",
                        url: "https://github.com/cordwainersmith/Claudoscope")
                MonoRow(label: "web", value: "liranbaba.dev",
                        url: "https://liranbaba.dev")
            }
            .padding(.top, 2)

            Divider()

            Text("runs locally · © \(year) Liran Baba")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 340, alignment: .leading)
        .modifier(ActivationPolicyModifier())
    }
}

// MARK: - Mono Key/Value Row

private struct MonoRow: View {
    let label: String
    let value: String
    let url: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)

            Link(destination: URL(string: url)!) {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .pointingHand()
        }
    }
}

private extension View {
    func pointingHand() -> some View {
        onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
