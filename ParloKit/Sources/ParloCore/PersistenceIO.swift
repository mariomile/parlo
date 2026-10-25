import Foundation

/// The three fallible file operations used by the stores, injectable for failure-path tests.
struct PersistenceIO: Sendable {
    var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    var write: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    func removeIfPresent(_ url: URL) throws {
        do { try remove(url) }
        catch where Self.isMissing(error) { }
    }

    static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
            && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
