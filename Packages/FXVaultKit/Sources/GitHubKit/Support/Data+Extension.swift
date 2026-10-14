import Foundation

extension Data {
    /// Overwrites every byte with zero using `memset_s`, which the compiler may not elide.
    /// Used on temporary copies of process output (§5.12).
    mutating func secureWipe() {
        withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }
}
