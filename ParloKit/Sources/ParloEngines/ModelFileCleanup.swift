import Foundation

/// Delete every owned path, including staging/cache siblings. Only absence counts as successful deletion.
enum ModelFileCleanup {
    struct Failure: Error, LocalizedError {
        let problems: [String]
        var errorDescription: String? { problems.joined(separator: "; ") }
    }

    static func remove(
        _ paths: [URL], using remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        var problems: [String] = []
        for path in paths {
            do { try remove(path) }
            catch {
                let ns = error as NSError
                guard ns.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code)
                else { continue }
                problems.append("\(path.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !problems.isEmpty { throw Failure(problems: problems) }
    }
}
