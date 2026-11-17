import SwiftUI
import Testing
import UIKit

/// Draws `view` in a window of the test host app's scene, the only kind that
/// draws a List, records it as a PNG attachment CI keeps, and returns how
/// many colours it holds so a blank render can fail the test.
@MainActor
func snapshot(_ view: some View, named name: String, style: UIUserInterfaceStyle, height: CGFloat = 640) throws -> Int {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
    window.overrideUserInterfaceStyle = style
    window.rootViewController = UIHostingController(rootView: view)
    window.makeKeyAndVisible()
    RunLoop.main.run(until: .now + 2)
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    window.isHidden = true
    Attachment.record(try #require(image.pngData()), named: "\(name)-\(style == .dark ? "dark" : "light").png")
    return colours(in: image)
}

/// Distinct colours in `image`, sampled on a coarse grid.
private func colours(in image: UIImage) -> Int {
    guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
    var seen = Set<UInt32>()
    for y in stride(from: 0, to: cg.height, by: 16) {
        for x in stride(from: 0, to: cg.width, by: 16) {
            let offset = y * cg.bytesPerRow + x * (cg.bitsPerPixel / 8)
            seen.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
        }
    }
    return seen.count
}
