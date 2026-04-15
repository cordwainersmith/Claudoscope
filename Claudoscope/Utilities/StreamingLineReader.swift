import Foundation

/// Reads lines from a FileHandle without loading the entire file into memory.
/// Yields one line at a time, stripping the newline delimiter.
///
/// Implemented as a class to avoid copy-hazard: the mutable buffer and FileHandle
/// seek position must not diverge across independent copies.
final class StreamingLineReader: Sequence, IteratorProtocol {
    private let fileHandle: FileHandle
    private let chunkSize: Int
    private var buffer = Data()
    private var isEOF = false

    init(fileHandle: FileHandle, chunkSize: Int = 256 * 1024) {
        self.fileHandle = fileHandle
        self.chunkSize = chunkSize
    }

    func next() -> String? {
        while true {
            // Check if buffer contains a newline
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                return line
            }

            // No newline in buffer — read more data
            if isEOF {
                // Return remaining buffer as last line
                if !buffer.isEmpty {
                    let remaining = buffer
                    buffer = Data()
                    return String(data: remaining, encoding: .utf8)
                }
                return nil
            }

            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                isEOF = true
            } else {
                buffer.append(chunk)
            }
        }
    }
}
