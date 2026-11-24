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
                VStack(spacing: AppSpacing.m) {
                    HStack(spacing: AppSpacing.l) {
                        tabPreview("house.fill", selected: true)
                        tabPreview("bolt.horizontal.fill", selected: false)
                        tabPreview("person.fill", selected: false)
                    }
                    .padding(.horizontal, AppSpacing.l)
                    .padding(.vertical, AppSpacing.s)
                    .appSolidChipSurface(isSelected: false)
                    .frame(maxWidth: .infinity)

                    Divider()

                    HStack(spacing: AppSpacing.s) {
                        previewButton("Like", icon: "hand.thumbsup.fill")
                        previewButton("Coin", icon: "bitcoinsign.circle.fill")
                        previewButton("Favorite", icon: "star.fill")
                    }
                    .frame(maxWidth: .infinity)

                    ProgressView(value: 0.6)
                        .tint(effectiveContentAccent)
                }
                .padding(.vertical, AppSpacing.s)
            }
        }
        .listRowBackground(AppFill.card)
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Color")
        .navigationBarTitleDisplayMode(.inline)
        .animation(motion.animation(normal: .easeInOut(duration: 0.2)), value: selected)
        .animation(motion.animation(normal: .easeInOut(duration: 0.2)), value: scope)
    }

    private func row(theme: AccentTheme?, swatchLabel: LocalizedStringKey) -> some View {
        let isSelected = selected == theme
        let swatchColor = theme?.color ?? Color.accentColor
        return Button {
            apply(theme: theme)
        } label: {
            HStack(spacing: AppSpacing.m) {
                Circle()
                    .fill(swatchColor)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: AppStroke.hairlineWidth)
                    )
                    .frame(width: 22, height: 22)
                    .padding(2)
                    .overlay {
                        if isSelected {
                            Circle()
                                .strokeBorder(swatchColor.opacity(0.45), lineWidth: 1.5)
                        }
                    }

                Text(swatchLabel)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(swatchColor)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tabPreview(_ symbol: String, selected isSelected: Bool) -> some View {
        let navColor = selected?.color ?? Color.accentColor
        return Image(systemName: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? navColor : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? navColor.opacity(0.14) : Color.clear,
                in: Capsule()
            )
    }

    private func previewButton(_ label: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(label)
                .appFont(.overlayBadge)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .foregroundStyle(effectiveContentAccent)
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(effectiveContentAccent.opacity(0.12), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(effectiveContentAccent.opacity(0.24), lineWidth: AppStroke.hairlineWidth)
        )
    }
}
