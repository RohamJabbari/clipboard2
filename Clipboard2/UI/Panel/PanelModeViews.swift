import SwiftUI

/// ⌘K menu: paste variants, transforms, Claude actions and item actions for the selection.
struct ActionMenuView: View {
    @Bindable var model: PanelViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var filterFocused: Bool

    var body: some View {
        let actions = model.filteredActions
        let isPinned = model.selectedEntry?.clip?.isPinned ?? false

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter actions", text: $model.actionQuery, prompt: Text("Filter actions or ask \(model.aiName)"))
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .accessibilityLabel("Filter actions")
                ModelPickerMenu()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if actions.isEmpty {
                ContentUnavailableView("No Matching Actions", systemImage: "magnifyingglass")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                if index == 0 || actions[index - 1].section(aiName: model.aiName) != action.section(aiName: model.aiName) {
                                    Text(action.section(aiName: model.aiName))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.top, index == 0 ? 2 : 10)
                                        .padding(.bottom, 2)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                ActionRow(action: action, title: action.title(isPinned: isPinned),
                                          isSelected: index == model.actionSelection)
                                    .id(action.id)
                                    .onTapGesture { model.perform(action) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.actionSelection) { _, index in
                        guard actions.indices.contains(index) else { return }
                        if reduceMotion { proxy.scrollTo(actions[index].id) } else {
                            withAnimation(.snappy(duration: 0.12)) { proxy.scrollTo(actions[index].id) }
                        }
                    }
                }
            }
        }
        .onAppear { filterFocused = true }
    }
}

private struct ActionRow: View {
    let action: PanelAction
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .frame(width: 20)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Small form for custom snippet placeholders like {name}.
struct SnippetFormView: View {
    @Bindable var form: SnippetFormState
    let onSubmit: () -> Void
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(form.snippet.name.isEmpty ? "Snippet" : form.snippet.name, systemImage: "text.badge.star")
                .font(.headline)
            Text("Fill in the fields, then press Return to paste.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                ForEach(form.fields, id: \.self) { field in
                    TextField(field.capitalized, text: binding(for: field))
                        .focused($focused, equals: field)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Paste", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { focused = form.fields.first }
    }

    private func binding(for field: String) -> Binding<String> {
        Binding(
            get: { form.values[field] ?? "" },
            set: { form.values[field] = $0 }
        )
    }
}

/// Names a history item and moves it into the keychain-backed Secrets vault.
struct SaveSecretView: View {
    @Bindable var form: SaveSecretState
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Save as Secret", systemImage: "key.fill")
                .font(.headline)
            Text("Stores the value in your Keychain and removes it from clipboard history. Pasting it asks for Touch ID, and the clipboard is cleared again afterwards.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $form.name, prompt: Text("e.g. Prod DB password"))
                    .focused($focused)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Save", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear { focused = true }
    }
}

/// Changes a secret's name and value in place (the value is shown only after Touch ID).
struct EditSecretView: View {
    @Bindable var form: EditSecretState
    let onSubmit: () -> Void
    @FocusState private var valueFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Edit Secret", systemImage: "key.fill")
                .font(.headline)
            Text("Changes are saved to your Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $form.name)
                TextField("Value", text: $form.value)
                    .font(.body.monospaced())
                    .focused($valueFocused)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Save", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.name.trimmingCharacters(in: .whitespaces).isEmpty || form.value.isEmpty)
            }
        }
        .padding(16)
        .onAppear { valueFocused = true }
    }
}

/// Chooses the sync group the selected items are copied into.
struct ShareToGroupView: View {
    @Bindable var form: ShareGroupState
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Share to Group", systemImage: "person.2.fill")
                .font(.headline)
            Text(form.items.count == 1
                 ? "Copies this item into the group. Every member sees it, end-to-end encrypted."
                 : "Copies \(form.items.count) items into the group. Every member sees them, end-to-end encrypted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                ForEach(Array(form.groups.enumerated()), id: \.element.id) { index, group in
                    let selected = index == form.selection
                    HStack(spacing: 10) {
                        Image(systemName: "person.2.fill")
                            .frame(width: 20)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                        Text(group.name)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        Spacer()
                        Text("\(group.memberCount) \(group.memberCount == 1 ? "member" : "members")")
                            .font(.caption)
                            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        form.selection = index
                        onSubmit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Share", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.selectedGroup == nil)
            }
        }
        .padding(16)
    }
}

/// Label for a pinned item, or the name of a secret. Shows the value it belongs to.
struct LabelFormView: View {
    @Bindable var form: LabelFormState
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(form.isSecret ? "Rename Secret" : "Label", systemImage: "tag")
                .font(.headline)
            Text(form.isSecret
                 ? "The name shown for this secret in the panel and in search."
                 : "Shown instead of the content in lists and searchable. Labelled items are pinned, so they never expire. Leave empty to remove the label.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Label", text: $form.text, prompt: Text("e.g. Staging DB host"))
                    .focused($focused)
                LabeledContent("Value") {
                    Text(form.valuePreview)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Save", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { focused = true }
    }
}

/// Streaming AI output with Paste / Copy / Replace actions.
struct AIResultView: View {
    let run: AIRun
    let model: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: run.action.symbol)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(run.action.title).font(.headline)
                Spacer()
                ModelPickerMenu { model.rerunAI() }
                if run.isStreaming {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Waiting for the response")
                }
            }
            .padding(14)

            Divider()

            ScrollView {
                Group {
                    if let error = run.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else if run.output.isEmpty {
                        Text("Thinking…").foregroundStyle(.secondary)
                    } else {
                        Text(run.output)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .accessibilityLabel("AI result")

            Divider()

            HStack {
                if run.error?.needsSettings == true {
                    Button("Open Settings…") {
                        model.onClose()
                        SettingsOpener.open()
                    }
                }
                Spacer()
                if !run.item.isTransient {
                    Button("Replace Item") { model.replaceItemWithAIOutput() }
                        .disabled(!run.isFinished)
                        .help("⌘R")
                }
                Button("Copy") { model.copyAIOutput() }
                    .disabled(run.output.isEmpty)
                    .help("⌘C")
                Button(run.item.isTransient ? "Replace Selection" : "Paste") { model.pasteAIOutput() }
                    .disabled(!run.isFinished)
                    .buttonStyle(.borderedProminent)
                    .help("Return")
            }
            .padding(12)
        }
    }
}

/// Compact menu showing the active provider's models; changing it updates Settings → Actions too.
struct ModelPickerMenu: View {
    @Environment(AppEnvironment.self) private var env
    var onChange: (() -> Void)?

    var body: some View {
        let prefs = env.prefs
        let provider = prefs.aiProvider
        let catalog = env.modelCatalog
        let models = catalog.models(for: provider, current: prefs.aiModel)

        Menu {
            Section(provider.title) {
                ForEach(models, id: \.self) { id in
                    Button {
                        prefs.aiModel = id
                        onChange?()
                    } label: {
                        if id == prefs.aiModel {
                            Label(AIModelCatalog.displayName(id), systemImage: "checkmark")
                        } else {
                            Text(AIModelCatalog.displayName(id))
                        }
                    }
                }
                if catalog.loading.contains(provider) {
                    Text("Loading models…")
                } else if let error = catalog.errors[provider], !provider.isSubscription {
                    Text(error)
                }
            }
            Divider()
            if !provider.isSubscription {
                Button("Refresh Models") { catalog.reload(provider, customBaseURL: prefs.customBaseURL) }
            }
            Button("Change Provider…") {
                env.panel.close()
                SettingsOpener.open()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text(prefs.aiModel.isEmpty ? "Choose model" : AIModelCatalog.displayName(prefs.aiModel))
                    .lineLimit(1)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(provider.title) model")
        .accessibilityLabel("Model: \(prefs.aiModel)")
        .onAppear { catalog.loadIfNeeded(provider, customBaseURL: prefs.customBaseURL) }
    }
}
