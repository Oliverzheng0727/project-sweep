import AppKit
import SwiftUI

/// The generic system folder image does not read the selected project or cloud files.
struct ProjectFolderIcon: View {
    let size: CGFloat
    var available = true
    private static let folder = NSImage(named: NSImage.folderName)

    var body: some View {
        Group {
            if let folder = Self.folder {
                Image(nsImage: folder).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(.blue)
            }
        }.frame(width: size, height: size).opacity(available ? 1 : 0.4).accessibilityHidden(true)
    }
}
