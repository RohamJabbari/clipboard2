import SwiftUI

// Personal info cards in Auth, under "Me" (docs/features/auth-autofill.md → Phase 2).

/// New Card… and Edit: a label and the card's values.
@Observable
final class CardFormState {
    var card: PersonalCard
    let isNew: Bool
    var error: String?

    init(card: PersonalCard, isNew: Bool) {
        self.card = card
        self.isNew = isNew
    }

    var canSave: Bool {
        !card.label.trimmingCharacters(in: .whitespaces).isEmpty || !card.isEmpty
    }

    func binding(_ kind: FormFieldKind) -> Binding<String> {
        Binding(get: { [self] in rawValue(kind) },
                set: { [self] in card.set($0, for: kind) })
    }

    private func rawValue(_ kind: FormFieldKind) -> String {
        switch kind {
        case .name, .givenName, .familyName: card.name
        case .email: card.email
        case .phone: card.phone
        case .company: card.company
        case .street: card.street
        case .postcode: card.postcode
        case .city: card.city
        case .country: card.country
        }
    }
}

/// "Me" at the end of Auth's list: one row per card.
struct MeSection: View {
    let model: PanelViewModel
    let cards: [PersonalCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("Me").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
            ForEach(cards) { card in
                let selected = model.selectedCardID == card.id && model.selectedID == nil
                HStack(spacing: 10) {
                    Image(systemName: "person.text.rectangle")
                        .frame(width: 26, height: 26)
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.title)
                            .lineLimit(1)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        if !card.subtitle.isEmpty {
                            Text(card.subtitle)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture {
                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.beginEditCard(card) } else { model.selectCard(card) }
                }
                .contextMenu {
                    Button("Edit…") { model.beginEditCard(card) }
                    Button("Delete", role: .destructive) { model.deleteCard(card) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// A card's values, each with Copy. Filling happens from the paste icon in a form.
struct CardPreview: View {
    let card: PersonalCard
    let model: PanelViewModel
    @Environment(AppEnvironment.self) private var env
    @State private var copied: FormFieldKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.text.rectangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text("Personal info · this Mac only").foregroundStyle(.secondary)
                }
            }
            if card.values.isEmpty {
                Text("No details yet.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    ForEach(card.values, id: \.kind) { entry in
                        GridRow {
                            Text(entry.kind.title).foregroundStyle(.secondary)
                            Text(entry.value).lineLimit(3).textSelection(.enabled)
                            Button(copied == entry.kind ? "Copied" : "Copy") { copy(entry.kind, entry.value) }
                        }
                    }
                }
            }
            HStack {
                Button("Edit…") { model.beginEditCard(card) }
                Button("Delete", role: .destructive) { model.deleteCard(card) }
                Spacer()
            }
            Text("In a web form, the paste icon offers these values and Fill Form.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func copy(_ kind: FormFieldKind, _ value: String) {
        env.paste.writeSecret(value, clearAfter: 0)
        copied = kind
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == kind { copied = nil }
        }
    }
}

/// New Card… and Edit, in the right pane.
struct CardFormView: View {
    @Bindable var form: CardFormState
    let onSubmit: () -> Void
    @FocusState private var labelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(form.isNew ? "New Card" : "Edit Card", systemImage: "person.text.rectangle.fill")
                .font(.headline)
            Form {
                TextField("Label", text: $form.card.label, prompt: Text("e.g. Home, Work"))
                    .focused($labelFocused)
                ForEach(PersonalCard.fields, id: \.self) { kind in
                    TextField(kind.title, text: form.binding(kind), prompt: Text(Self.prompt(kind)))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            if let error = form.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("Kept on this Mac. Not synced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canSave)
            }
        }
        .padding(16)
        .onAppear { labelFocused = true }
    }

    private static func prompt(_ kind: FormFieldKind) -> String {
        switch kind {
        case .name: "Full name"
        case .email: "name@example.com"
        case .phone: "+43 …"
        default: "Optional"
        }
    }
}
