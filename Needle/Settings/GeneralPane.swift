import SwiftUI

struct GeneralPane: View {
    @Bindable var settings: Settings
    let model: AppModel
    @State private var launchesAtLogin = false

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open Needle when you log in", isOn: Binding(
                    get: { launchesAtLogin },
                    set: { model.launchesAtLogin = $0; launchesAtLogin = model.launchesAtLogin }
                ))
                Toggle("Show Needle in the menu bar", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("Right-click the cover for its menu, or open Needle again to come back here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("When the music pauses", selection: $settings.whenPaused) {
                    ForEach([PausedBehaviour.keep, .afterFiveMinutes, .afterAMinute, .rightAway], id: \.self) { behaviour in
                        Text(behaviour.title).tag(behaviour)
                    }
                }
                Toggle("Swipe or scroll over the cover to skip", isOn: $settings.scrollToSkip)
                Text("Click the cover to play or pause, and the title to see the cover large.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needle \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .font(.headline)
                        Text("What's playing, beside the Dock.")
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.player.problem ?? "Needle reads what Control Center's Now Playing shows: Music, Spotify, Podcasts, a browser, any app that plays. Nothing leaves your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchesAtLogin = model.launchesAtLogin }
    }
}
