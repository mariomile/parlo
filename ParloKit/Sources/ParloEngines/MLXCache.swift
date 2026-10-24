import MLX

/// MLX keeps freed GPU buffers for reuse, by default without a limit: after a few runs that can be gigabytes
/// on top of the model itself.
enum MLXCache {
    static func limit() {
        Memory.cacheLimit = 512 * 1024 * 1024
    }
}
