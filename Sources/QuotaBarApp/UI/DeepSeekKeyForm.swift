import SwiftUI

struct DeepSeekKeyForm: View {
    let text: AppText
    let isReplacing: Bool
    var importedKey: String? = nil
    let onSave: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    private enum Field: Hashable { case key, name }

    @FocusState private var focusedField: Field?
    @State private var key = ""
    @State private var showsKey = false
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var title: String {
        if isReplacing { return text.replaceDeepSeekKey }
        return importedKey == nil ? text.string(.addAccount) : text.importDeepSeekKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            } icon: {
                ToolLogoIcon(tool: .deepSeek, size: 17)
            }

            HStack(spacing: 8) {
                field(.key) {
                    if showsKey {
                        TextField("DeepSeek API Key", text: $key)
                    } else {
                        SecureField("DeepSeek API Key", text: $key)
                    }
                }
                Button {
                    showsKey.toggle()
                    focusedField = .key
                } label: {
                    Image(systemName: showsKey ? "eye.slash" : "eye")
                        .foregroundStyle(Branding.inkMuted)
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.quotaInteractive())
                .help(text.deepSeekKeyVisibilityAction(showsKey: showsKey))
                .accessibilityLabel(text.deepSeekKeyVisibilityAction(showsKey: showsKey))
                .disabled(isSaving)
            }

            if !isReplacing {
                field(.name) {
                    TextField(text.optionalAccountName, text: $name)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Branding.warning)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(text.string(.refreshing))
                }
                Spacer()
                CardTextActionButton(
                    title: text.string(.cancel),
                    tint: Branding.inkMuted,
                    softTint: Branding.controlSurface,
                    action: { dismiss() }
                )
                .keyboardShortcut(.cancelAction)

                CardTextActionButton(
                    title: title,
                    tint: Branding.accentBlueDark,
                    softTint: Branding.accentBlueSoft,
                    isEnabled: !isSaving && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submit
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .foregroundStyle(Branding.ink)
        .background(Branding.pageBackground)
        .onAppear {
            // The sheet's candidate seeds the editable field on presentation.
            if key.isEmpty, let importedKey { key = importedKey }
            focusedField = importedKey == nil ? .key : .name
        }
        .task(id: isSaving) {
            guard isSaving else { return }
            do {
                try await onSave(key, name)
                dismiss()
            } catch is CancellationError {
                isSaving = false
            } catch {
                errorMessage = text.userFacingErrorMessage(error)
                isSaving = false
                focusedField = .key
            }
        }
    }

    private func field<Content: View>(_ field: Field, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Branding.radiusControl)
        return content()
            .textFieldStyle(.plain)
            .focused($focusedField, equals: field)
            .disabled(isSaving)
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Branding.controlSurface, in: shape)
            .overlay {
                shape.strokeBorder(
                    focusedField == field ? Branding.accentBlue : Branding.controlStroke,
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
            }
    }

    private func submit() {
        errorMessage = nil
        isSaving = true
    }
}
