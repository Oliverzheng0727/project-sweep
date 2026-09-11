import CleanupCore
import Darwin
import Foundation

/// Quick Look receives only a revalidated local file or an opaque document package.
enum PreviewSafety {
    static func isEligible(_ item: CleanupItem) -> Bool {
        guard item.action != .deleteSession, item.risk != .unavailable, let snapshot = item.snapshot else { return false }
        let kind = snapshot.mode & UInt32(S_IFMT)
        return kind == UInt32(S_IFREG) || (kind == UInt32(S_IFDIR) && item.category == .document)
    }

    static func validate(_ item: CleanupItem, authorizedRoot: URL) throws -> URL {
        guard isEligible(item), item.rootPath == authorizedRoot.path, let snapshot = item.snapshot else {
            throw CleanupError.unsafe("此项目不可预览，请重新扫描或选择受支持的本地文件。")
        }
        try PathSafety.validate(item.url, within: authorizedRoot)
        let rootState = try Snapshotter.capture(authorizedRoot)
        if let identity = item.metadata["rootIdentity"] {
            guard identity == "\(rootState.device):\(rootState.inode)" else {
                throw CleanupError.changed("授权目录已被替换，请重新扫描。")
            }
        } else if let encoded = item.metadata["rootSnapshot"], let data = encoded.data(using: .utf8) {
            let originalRoot = try JSONDecoder().decode(FileSnapshot.self, from: data)
            guard originalRoot.device == rootState.device, originalRoot.inode == rootState.inode else {
                throw CleanupError.changed("工具数据目录已被替换，请重新扫描。")
            }
        } else { throw CleanupError.unsafe("缺少授权目录校验信息，请重新扫描。") }
        let live = try Snapshotter.capture(item.url)
        let kind = live.mode & UInt32(S_IFMT)
        guard kind == UInt32(S_IFREG) || kind == UInt32(S_IFDIR), live.device == rootState.device else {
            throw CleanupError.unsafe("符号链接、特殊文件或其他挂载卷不支持预览。")
        }
        let values = try item.url.resourceValues(forKeys: [.isPackageKey, .isReadableKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isReadable == true else { throw CleanupError.unsafe("没有读取此文件的权限。") }
        guard kind == UInt32(S_IFREG) || values.isPackage == true else {
            throw CleanupError.unsafe("文件夹请在 Finder 中查看。快速查看仅支持文件与完整文档包。")
        }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current, values.ubiquitousItemDownloadingStatus != .downloaded {
            throw CleanupError.unsafe("云端占位文件不会下载或预览。")
        }
        try Snapshotter.verify(item.url, matches: snapshot)
        try PathSafety.validate(item.url, within: authorizedRoot)
        return item.url
    }
}
