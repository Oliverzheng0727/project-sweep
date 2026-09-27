import Foundation

/// Shared authored-file types for cleanup protection and occupied-space classification.
/// Extending a display category must not leave the same content eligible for cache quick selection.
enum ProjectFileTypes {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif", "ico", "icns", "psd", "ai", "eps", "raw", "dng", "exr"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "m4v", "avi", "webm", "mpeg", "mpg"]
    static let audioExtensions: Set<String> = ["mp3", "wav", "aiff", "aif", "m4a", "aac", "flac", "ogg", "opus", "caf"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "key", "pages", "numbers", "rtf", "rtfd", "txt", "csv", "epub", "odt", "ods", "odp"]
    static let sourceExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "c", "cpp", "cc", "cxx", "h", "hpp", "java", "kt", "go", "sh", "bash", "zsh", "ipynb", "r", "tex", "html", "css", "scss", "md", "rb", "php", "sql", "lua"]
    static let creativeExtensions = documentExtensions.union(imageExtensions)
        .union(videoExtensions).union(audioExtensions).union(["fig", "blend"])
}
