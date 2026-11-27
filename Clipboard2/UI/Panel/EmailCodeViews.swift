import SwiftUI

// Email codes in Auth (docs/features/auth-autofill.md, phase 4): a row with the code, its source
// and its age; a preview with Paste and Copy. Both go transient, never into history.

struct EmailCodeRow: View {
    let code: EmailCode
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            SourceIcon(source: code.authSource, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(code.source)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Label("Email · \(code.age(at: context.date))", systemImage: "envelope.fill")
                        .labelStyle(.titleAndIcon)
                        .imageScale(.small)
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 4)
            Text(code.code)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor)
                      : hovering ? AnyShapeStyle(Color.primary.opacity(0.05)) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Email code from \(code.source)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Double-click or press Return to paste the code")
    }
}

struct EmailCodePreview: View {
    let code: EmailCode
    let model: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SourceIcon(source: code.authSource, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(code.source).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if let address = model.env.emailCodes.address(of: code) {
                        Text(address).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Text(code.code)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 4)
            HStack {
                Button("Paste Code") { model.pasteEmailCode(code) }
                    .buttonStyle(.borderedProminent)
                Button("Copy Code") { model.copyEmailCode(code) }
                    .help("Not kept in history")
            }
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let left = max(1, Int(code.expiresAt.timeIntervalSince(context.date) / 60) + 1)
                Text("Arrived \(code.age(at: context.date)). Gone in \(left) min. Return pastes it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension NotificationHub {
    /// "Code from google.com": the code itself only when Settings says so. Asks for permission
    /// the first time, like every other notification.
    func postEmailCode(_ code: EmailCode, showingCode: Bool) {
        let notification = AppNotification(kind: .authenticators, title: "Code from \(code.source)",
                                           body: showingCode ? code.code : "Open Auth to paste it",
                                           target: .emailCode(id: code.id), groupId: "emailCodes")
        let poster = self.poster
        Task {
            var permission = await poster.permission()
            if permission == .notDetermined { permission = await poster.requestPermission() ? .allowed : .denied }
            if permission == .allowed { poster.post(notification) }
        }
    }
}
