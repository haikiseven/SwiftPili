import SwiftUI

struct ColorSettingsView: View {
    @AppMotion private var motion
    /// nil = the system accent, which is the default and the top row.
    @State private var selected = AccentTheme.current
    @State private var scope = AccentScope.current

    /// What the chosen colour will ACTUALLY paint, given the scope — not the
    /// raw swatch. The preview used to show `selected.color` on Like / Coin /
    /// Favorite regardless of scope, so a user could pick Teal, see a teal
    /// preview of those exact controls, and then find them unchanged on the
    /// video page. A preview that disagrees with the result is worse than none.
    private var effectiveContentAccent: Color {
        // Same predicate as `AccentStore.semanticAccent`, which it is previewing.
        // While those two disagreed, this swatch under-reported: the Controls
        // scope really did colour these surfaces, and the preview said it would
        // not — the exact "preview that disagrees with the result" this property
        // was written to prevent.
        guard scope.includesControls, let selected else { return .accentColor }
        return selected.color
    }

    private func apply(theme: AccentTheme?) {
        selected = theme
        AccentTheme.current = theme
        AccentStore.shared.reload()
    }

    var body: some View {
        List {
            Section {
                ForEach(AccentTheme.allCases) { theme in
                    row(theme: theme, swatchLabel: LocalizedStringKey(theme.rawValue))
                }
            } header: {
                Text("Accent Color")
            }

            Section {
                Picker(selection: Binding(
                    // `pickerEquivalent`, so an install that persisted the
                    // withdrawn "Accent Elements" row shows the row it is
                    // identical to instead of an empty selection.
                    get: { scope.pickerEquivalent },
                    set: { newValue in
                        scope = newValue
                        AccentScope.current = newValue
                        AccentStore.shared.reload()
                    }
                )) {
                    // `selectableCases`, not `allCases`: the third case is
                    // behaviourally identical to `.controls` and offering both
                    // taught the user something false about the setting.
                    ForEach(AccentScope.selectableCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    Label {
                        Text("Apply Color To")
                    } icon: {
                        SettingsIcon(symbol: "paintpalette")
                    }
                }
                // Deliberately NOT disabled on "no colour chosen". The scope
                // decides whether a colour reaches content at all, so greying it
                // out until a colour exists made the control that determines the
                // whole outcome inert at exactly the moment the user forms an
                // expectation about it — then left it reading "Bottom Navigation
                // Only" once it woke up. With `.controls` as the default the row
                // now describes what will happen rather than gating it.
                //
                // No section header: its only row is already labelled "Apply
                // Color To", and a header repeating that ("Scope") was the
                // redundant-naming the row's own label makes unnecessary.
            }

            Section("Preview") {
                VStack(spacing: 12) {
                    // The bar is the surface the default scope actually targets,
                    // and the old preview never showed it.
                    HStack(spacing: 22) {
                        tabPreview("house.fill", selected: true)
                        tabPreview("bolt.horizontal.fill", selected: false)
                        tabPreview("person.fill", selected: false)
                    }
                    .frame(maxWidth: .infinity)

                    Divider()

                    HStack(spacing: 16) {
                        previewButton("Like", icon: "hand.thumbsup.fill")
                        previewButton("Coin", icon: "bitcoinsign.circle.fill")
                        previewButton("Favorite", icon: "star.fill")
                    }
                    .frame(maxWidth: .infinity)

                    ProgressView(value: 0.6)
                        .tint(effectiveContentAccent)
                }
                .padding(.vertical, 8)
            }
        }
        .listRowBackground(AppFill.card)
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Color")
        .navigationBarTitleDisplayMode(.inline)
        .animation(motion.animation(normal: .easeInOut(duration: 0.2)), value: selected)
    }

    private func row(theme: AccentTheme?, swatchLabel: LocalizedStringKey) -> some View {
        let isSelected = selected == theme
        return Button {
            apply(theme: theme)
        } label: {
            HStack(spacing: AppSpacing.m) {
                Group {
                    if let theme {
                        Circle().fill(theme.color)
                    } else {
                        Circle().fill(Color.accentColor)
                    }
                }
                .frame(width: 24, height: 24)

                Text(swatchLabel)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme?.color ?? Color.accentColor)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Bottom-navigation preview. The selected item follows the pick under BOTH
    /// scopes; unselected items keep the system's secondary treatment.
    private func tabPreview(_ symbol: String, selected isSelected: Bool) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(
                isSelected ? (selected?.color ?? Color.accentColor) : Color.secondary
            )
    }

    private func previewButton(_ label: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(effectiveContentAccent)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
