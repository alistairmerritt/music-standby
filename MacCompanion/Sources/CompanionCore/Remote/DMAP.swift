import Foundation

/// The tagged format Music's remote-control protocol (DACP, as Apple's iTunes
/// Remote app uses it) answers in: a 4-character tag, a 4-byte big-endian
/// length, then the value. Which tags are containers isn't in the data, so
/// `parse` opens only the ones it's told about.
public struct DMAPNode: Equatable, Sendable {
    public var tag: String
    public var value: Data
    public var children: [DMAPNode]

    /// Containers DACP answers with, as far as the companion reads them.
    public static let containers: Set<String> = [
        "mlog", "msrv", "cmst", "ceQR", "ceQS", "mlcl", "mlit", "avdb", "adbs", "cmpa", "ceQi",
    ]

    public static func parse(_ data: Data, containers: Set<String> = containers) -> [DMAPNode] {
        var nodes: [DMAPNode] = []
        var index = data.startIndex
        while data.distance(from: index, to: data.endIndex) >= 8 {
            let tag = String(decoding: data[index..<index + 4], as: UTF8.self)
            let length = data[index + 4..<index + 8].reduce(0) { $0 << 8 | Int($1) }
            let start = index + 8
            guard length >= 0, data.distance(from: start, to: data.endIndex) >= length else { break }
            let value = Data(data[start..<start + length])
            nodes.append(DMAPNode(tag: tag, value: value, children: containers.contains(tag) ? parse(value, containers: containers) : []))
            index = start + length
        }
        return nodes
    }

    /// The first descendant with this tag, depth first.
    public func first(_ tag: String) -> DMAPNode? {
        for child in children {
            if child.tag == tag { return child }
            if let found = child.first(tag) { return found }
        }
        return nil
    }

    public func all(_ tag: String) -> [DMAPNode] { children.filter { $0.tag == tag } }

    /// An unsigned integer of 1, 2, 4 or 8 bytes.
    public var integer: UInt64? {
        guard [1, 2, 4, 8].contains(value.count) else { return nil }
        return value.reduce(0) { $0 << 8 | UInt64($1) }
    }

    public var string: String { String(decoding: value, as: UTF8.self) }

    public static func encode(_ tag: String, _ value: Data) -> Data {
        var data = Data(tag.utf8.prefix(4))
        withUnsafeBytes(of: UInt32(value.count).bigEndian) { data.append(contentsOf: $0) }
        return data + value
    }

    public static func encode(_ tag: String, string: String) -> Data { encode(tag, Data(string.utf8)) }

    public static func encode(_ tag: String, uint32: UInt32) -> Data {
        withUnsafeBytes(of: uint32.bigEndian) { encode(tag, Data($0)) }
    }

    public static func encode(_ tag: String, uint64: UInt64) -> Data {
        withUnsafeBytes(of: uint64.bigEndian) { encode(tag, Data($0)) }
    }

    public static func encode(_ tag: String, children: [Data]) -> Data { encode(tag, children.reduce(Data(), +)) }
}

extension Array where Element == DMAPNode {
    public func first(_ tag: String) -> DMAPNode? {
        for node in self {
            if node.tag == tag { return node }
            if let found = node.first(tag) { return found }
        }
        return nil
    }
}
