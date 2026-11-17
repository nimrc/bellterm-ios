import SwiftUI

/// Each release's changes, newest first, with the installed version marked.
struct WhatsNewScreen: View {
    var releases = ReleaseNotes.load(language: Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh" : "en")
    var installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        List {
            ForEach(releases, id: \.version) { release in
                Section(release.version == installed ? String(localized: "\(release.version) · installed") : release.version) {
                    ForEach(release.notes, id: \.self) { note in
                        Text(note).font(.callout)
                    }
                }
            }
        }
        .navigationTitle("What's new")
        .accessibilityIdentifier("whats_new")
    }
}
