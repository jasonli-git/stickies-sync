import Foundation

/// Identifies one Mac. Stable for the life of a replica database.
public struct DeviceID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> DeviceID {
        DeviceID(rawValue: UUID().uuidString)
    }

    public var description: String { rawValue }

    public static func < (lhs: DeviceID, rhs: DeviceID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Per-note causality: one counter per device that has ever changed the note.
///
/// This is what replaces comparing modification times. Two Macs' clocks always
/// disagree by some amount, and timestamp-based conflict resolution silently
/// destroys the loser's work whenever the skew exceeds the interval between
/// edits. A vector answers the only question that matters — did one version
/// descend from the other, or did they diverge — without reference to any clock.
///
/// Milestone 3 only ever increments the local device's counter. Merging a peer's
/// vector, and acting on `.concurrent`, is Milestone 4's work; the comparison is
/// implemented here because it is what the vectors are *for*, and testing it now
/// costs nothing.
public struct VersionVector: Hashable, Sendable {
    public private(set) var counters: [DeviceID: Int]

    public init(counters: [DeviceID: Int] = [:]) {
        self.counters = counters
    }

    public var isEmpty: Bool { counters.isEmpty }

    public subscript(device: DeviceID) -> Int {
        counters[device] ?? 0
    }

    public mutating func increment(_ device: DeviceID) {
        counters[device, default: 0] += 1
    }

    /// The pairwise maximum — what a note's vector becomes once two versions are
    /// reconciled.
    public func merged(with other: VersionVector) -> VersionVector {
        var merged = counters
        for (device, seq) in other.counters {
            merged[device] = max(merged[device] ?? 0, seq)
        }
        return VersionVector(counters: merged)
    }

    public enum Ordering: Hashable, Sendable {
        case equal
        /// Every counter is less than or equal, and at least one is less: this
        /// version is an ancestor and can be replaced without losing anything.
        case ancestor
        case descendant
        /// Each side has a counter the other does not. Neither can be discarded
        /// — this is the case that becomes a conflict copy.
        case concurrent
    }

    public func ordering(against other: VersionVector) -> Ordering {
        let devices = Set(counters.keys).union(other.counters.keys)
        var anyLess = false
        var anyGreater = false

        for device in devices {
            let mine = self[device]
            let theirs = other[device]
            if mine < theirs { anyLess = true }
            if mine > theirs { anyGreater = true }
        }

        return switch (anyLess, anyGreater) {
        case (false, false): .equal
        case (true, false): .ancestor
        case (false, true): .descendant
        case (true, true): .concurrent
        }
    }
}
