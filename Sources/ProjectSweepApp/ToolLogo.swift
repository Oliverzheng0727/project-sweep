import AppKit
import CleanupCore
import SwiftUI

/// Bundled branding used alongside the tool's visible name; no network lookup.
struct ToolLogo: View {
    let tool: ToolKind
    var size: CGFloat = 28

    private static let resources: Bundle = {
        // Installed .app resources live in Contents/Resources. SwiftPM command-line
        // builds use Bundle.module instead, without depending on the source tree.
        if let url = Bundle.main.url(forResource: "ProjectSweep_ProjectSweepApp", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()

    private static let images: [ToolKind: NSImage] = {
        let names: [ToolKind: String] = [
            .codex: "ToolLogoCodex", .claude: "ToolLogoClaude", .cursor: "ToolLogoCursor"
        ]
        return names.compactMapValues { resources.image(forResource: NSImage.Name($0)) }
    }()

    private var logo: Image {
        if let image = Self.images[tool] { return Image(nsImage: image) }
        return Image(systemName: "app.dashed")
    }

    var body: some View {
        logo
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
