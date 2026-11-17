import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bellterm

@MainActor
struct ReleaseNotesTests {
    private let files = [
        "1.1.0.en.txt": "Saved machines.\n",
        "1.1.0.zh.txt": "保存的机器。\n",
        "1.9.0.en.txt": "Nine.\n",
        "1.10.0.en.txt": "First line.\n\n  Second line.  \n",
        "1.0.0.en.txt": "First beta.\n",
        "2.0.0.en.txt": "\n",
        "README.md": "not notes",
    ]

    @Test func newestFirstInTheAskedLanguageElseEnglish() {
        #expect(ReleaseNotes.parse(files, language: "zh") == [
            Release(version: "1.10.0", notes: ["First line.", "Second line."]),
            Release(version: "1.9.0", notes: ["Nine."]),
            Release(version: "1.1.0", notes: ["保存的机器。"]),
            Release(version: "1.0.0", notes: ["First beta."]),
        ])
        #expect(ReleaseNotes.parse(files, language: "fr").first { $0.version == "1.1.0" }?.notes == ["Saved machines."])
    }

    /// The app bundles release-notes/, including the version being built.
    @Test func theAppShipsItsOwnReleaseNotes() throws {
        let releases = ReleaseNotes.load(language: "en")
        let installed = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(releases.contains { $0.version == installed })
        #expect(ReleaseNotes.load(language: "zh").first?.notes != releases.first?.notes)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func whatsNewRenders(style: UIUserInterfaceStyle) throws {
        let screen = NavigationStack { WhatsNewScreen() }
        #expect(try snapshot(screen, named: "whats-new", style: style, height: 800) > 2, "What's new drew nothing")
    }
}
