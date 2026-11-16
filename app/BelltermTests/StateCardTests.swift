import SwiftUI
import Testing
import UIKit
@testable import Bellterm

/// Renders state cards as images. CI exports these attachments from the result
/// bundle, so a change to a card's text can be seen without a host that
/// produces that state.
@MainActor
struct StateCardTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func herdrMissingCardRenders(scheme: ColorScheme) throws {
        let card = StateCard(
            state: .herdrMissing, retrying: false, rejectedPassword: false,
            onRetry: {}, onSignIn: {}, onTrust: { _, _ in }, onLeave: {}
        )
        .frame(width: 402)
        .background(scheme == .dark ? Color.black : Color.white)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        let png = try #require(renderer.uiImage?.pngData())
        Attachment.record(png, named: "herdr-missing-\(scheme == .dark ? "dark" : "light").png")
    }
}
