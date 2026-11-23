import SwiftUI
import UIKit

struct ColorSettingsView: View {
    @AppMotion private var motion
    @State private var selected = AccentTheme.current
    @State private var scope = AccentScope.current
    @State private var syncAppIcon = AppIconSync.isEnabled

    private var effectiveContentAccent: Color {
        guard scope.includesControls, let selected else { return .accentColor }
        return selected.color
    }

    private func apply(theme: AccentTheme?) {
        selected = theme
        AccentTheme.current = theme
        AccentStore.shared.reload()
        AppIconSync.syncIfEnabled(for: theme)
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
                    get: { scope.pickerEquivalent },
                    set: { newValue in
                        scope = newValue
                        AccentScope.current = newValue
                        AccentStore.shared.reload()
                    }
                )) {
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

                if UIApplication.shared.supportsAlternateIcons {
                    Toggle(isOn: Binding(
                        get: { syncAppIcon },
                        set: { newValue in
                            syncAppIcon = newValue
                            AppIconSync.isEnabled = newValue
                            if newValue {
                                AppIconSync.syncIfEnabled(for: selected)
                            }
                        }
                    )) {
                        Label {
                            Text("Sync App Icon")
                        } icon: {
                            SettingsIcon(symbol: "app.badge")
                        }
                    }
                }
            }

            Section("Preview") {
                VStack(spacing: 12) {
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
