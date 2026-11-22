import SwiftUI

struct AdvancedSettingsView: View {
    @State private var preloadStrategy = PlayerPlaybackPreferences.preloadStrategy
    @State private var smartCDNEnabled = SmartCDNSelector.isEnabled
    @State private var currentCDNLabel = CDNService.current.label

    var body: some View {
        List {
            Section("Playback") {
                Picker(selection: Binding(
                    get: { preloadStrategy },
                    set: {
                        preloadStrategy = $0
                        PlayerPlaybackPreferences.preloadStrategy = $0
                    }
                )) {
                    ForEach(PlayerPlaybackPreferences.PreloadStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.label).tag(strategy)
                    }
                } label: {
                    Label {
                        Text("Preload")
                    } icon: {
                        SettingsIcon(symbol: "arrow.down.circle.dotted")
                    }
                }
            }
            Section("Network") {
                NavigationLink {
                    CDNSettingsView()
                } label: {
                    LabeledContent {
                        if smartCDNEnabled {
                            Text("Smart CDN")
                        } else {
                            Text(currentCDNLabel)
                        }
                    } label: {
                        Label {
                            Text("CDN Settings")
                        } icon: {
                            SettingsIcon(symbol: "server.rack")
                        }
                    }
                }
            }
        }
        .listRowBackground(AppFill.card)
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Advanced Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            smartCDNEnabled = SmartCDNSelector.isEnabled
            currentCDNLabel = CDNService.current.label
        }
    }
}
