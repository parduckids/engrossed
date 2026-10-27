import Foundation
import Compression

/// A minimal read-only ZIP reader.
///
/// An EPUB is a ZIP file, and Foundation has no API for reading one. This does
/// the smallest useful subset: find the central directory, list the entries, and
/// inflate the ones asked for. Everything is bounds-checked, because the input
/// is a file someone downloaded and a malformed archive must fail rather than
/// read off the end of a buffer.
struct ZipArchive {

    struct Entry {
        let name: String
        let isCompressed: Bool
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]
    private(set) var order: [String] = []

    /// A single entry larger than this is refused. No sane EPUB chapter is
    /// anywhere near it, and it stops a crafted archive claiming a gigabyte.
    private static let maximumEntrySize = 64 * 1024 * 1024

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.data = data
        guard let directory = ZipArchive.findCentralDirectory(in: data) else { return nil }
        guard readEntries(at: directory.offset, count: directory.count) else { return nil }
    }

    // MARK: - Reading numbers

    private func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + i]) << (8 * UInt32(i))
        }
        return value
    }

    // MARK: - Central directory

    /// The end-of-central-directory record sits at the very end, unless the file
    /// carries a comment, in which case it is up to 64KB earlier. Scan back.
    private static func findCentralDirectory(in data: Data) -> (offset: Int, count: Int)? {
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let minimumRecord = 22
        guard data.count >= minimumRecord else { return nil }

        let searchLimit = min(data.count, 65_536 + minimumRecord)
        var index = data.count - minimumRecord
        let floor = data.count - searchLimit

        while index >= floor {
            let base = data.startIndex + index
            if data[base] == signature[0], data[base + 1] == signature[1],
               data[base + 2] == signature[2], data[base + 3] == signature[3] {
                var count = 0
                var offset = 0
                for i in 0..<2 { count |= Int(data[base + 10 + i]) << (8 * i) }
                for i in 0..<4 { offset |= Int(data[base + 16 + i]) << (8 * i) }
                guard offset >= 0, offset < data.count, count > 0, count < 100_000 else { return nil }
                return (offset, count)
            }
            index -= 1
        }
        return nil
    }

    private mutating func readEntries(at start: Int, count: Int) -> Bool {
        var offset = start
        for _ in 0..<count {
            guard uint32(at: offset) == 0x0201_4b50 else { return !entries.isEmpty }

            guard let method = uint16(at: offset + 10),
                  let compressed = uint32(at: offset + 20),
                  let uncompressed = uint32(at: offset + 24),
                  let nameLength = uint16(at: offset + 28),
                  let extraLength = uint16(at: offset + 30),
                  let commentLength = uint16(at: offset + 32),
                  let localOffset = uint32(at: offset + 42)
            else { return !entries.isEmpty }

            let nameStart = offset + 46
            guard nameStart + Int(nameLength) <= data.count else { return !entries.isEmpty }
            let nameData = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + Int(nameLength)))
            let name = String(decoding: nameData, as: UTF8.self)

            // 0 is stored, 8 is deflate. Anything else is not something an EPUB
            // should be using, and is skipped rather than guessed at.
            if method == 0 || method == 8 {
                let entry = Entry(name: name,
                                  isCompressed: method == 8,
                                  compressedSize: Int(compressed),
                                  uncompressedSize: Int(uncompressed),
                                  localHeaderOffset: Int(localOffset))
                if entries[name] == nil { order.append(name) }
                entries[name] = entry
            }

            offset = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        return !entries.isEmpty
    }

    // MARK: - Extraction

    func contents(of name: String) -> Data? {
        guard let entry = entries[name] else { return nil }
        guard entry.uncompressedSize <= ZipArchive.maximumEntrySize,
              entry.compressedSize <= ZipArchive.maximumEntrySize else { return nil }

        // The local header repeats the name and extra fields, and its lengths
        // are the authoritative ones for finding where the data starts.
        let header = entry.localHeaderOffset
        guard uint32(at: header) == 0x0403_4b50,
              let nameLength = uint16(at: header + 26),
              let extraLength = uint16(at: header + 28)
        else { return nil }

        let start = header + 30 + Int(nameLength) + Int(extraLength)
        guard start >= 0, start + entry.compressedSize <= data.count else { return nil }

        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        guard entry.isCompressed else { return payload }
        return ZipArchive.inflate(payload, expecting: entry.uncompressedSize)
    }

    /// ZIP stores raw deflate with no zlib wrapper, which is exactly what
    /// `COMPRESSION_ZLIB` means to the Compression framework.
    private static func inflate(_ input: Data, expecting size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var output = Data(count: size)

        let written: Int = output.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { source in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, size,
                                                 sourceBase, input.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }

        guard written > 0 else { return nil }
        return written == size ? output : output.prefix(written)
    }
}
