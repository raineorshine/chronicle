import Foundation

/// Filesystem locations used by Chronicle. Everything lives under
/// `~/Library/Application Support/Chronicle/`.
public enum ChroniclePaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Chronicle", isDirectory: true)
    }

    public static var databaseURL: URL {
        supportDirectory.appendingPathComponent("chronicle.db")
    }

    public static var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    /// Creates the support directory if it does not already exist.
    @discardableResult
    public static func ensureSupportDirectory() throws -> URL {
        let dir = supportDirectory
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }
}
