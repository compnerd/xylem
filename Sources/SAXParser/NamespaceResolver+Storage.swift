// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import XMLCore

internal struct Arena {
  internal var bytes: [XML.Byte] = []

  @inline(__always)
  internal mutating func clear() {
    bytes.removeAll(keepingCapacity: true)
  }

  @inline(__always)
  internal mutating func reserve(capacity: Int) {
    guard bytes.isEmpty else { return }
    bytes.reserveCapacity(capacity)
  }

  @inline(__always)
  internal mutating func intern(_ literal: StaticString) -> XML.ResolvedAttributes.Reference {
    precondition(literal.hasPointerRepresentation)

    let start = bytes.count
    literal.withUTF8Buffer { bytes.append(contentsOf: $0) }
    return .buffer(start ..< bytes.count)
  }

  @inline(__always)
  internal mutating func intern(_ bytes: borrowing Span<XML.Byte>) -> XML.ResolvedAttributes.Reference {
    let start = self.bytes.count
    bytes.withUnsafeBufferPointer { self.bytes.append(contentsOf: $0) }
    return .buffer(start ..< self.bytes.count)
  }

  @inline(__always)
  @_lifetime(borrow self)
  internal func span(for range: Range<Int>) -> Span<XML.Byte> {
    bytes.span.extracting(range)
  }

  @inline(__always)
  internal mutating func append(expanding value: borrowing Span<XML.Byte>, mode: Expansion = .attribute)
      throws(XML.Error) -> XML.ResolvedAttributes.Reference? {
    guard let range = try bytes.append(expanding: value, mode: mode) else { return nil }
    return .buffer(range)
  }
}

internal struct DoubleBuffer<T> {
  internal var front: [T] = []
  private var back: [T] = []
  internal var store = Arena()

  @inline(__always)
  internal mutating func cycle(capacity: Int) {
    swap(&front, &back)
    front.removeAll(keepingCapacity: true)
    front.reserveCapacity(capacity)
    store.clear()
  }
}

/// A generation-stamped open-addressed hash set used for duplicate detection.
///
/// `ProbeSet` stores the index of a previously-seen record in each occupied
/// bucket and resolves collisions by linear probing. Buckets are tagged with a
/// monotonically increasing generation counter so a reset can logically clear
/// the table without rewriting every slot on the common path. Callers supply
/// the hash and the equality predicate, letting the table stay generic over
/// the compared record shape while still returning the matching prior index
/// when a duplicate is found.
internal struct ProbeSet {
  private var buckets: [(index: Int32, gen: UInt32)] = []
  private var generation: UInt32 = 0

  internal mutating func reset(count: Int) {
    let capacity = Self.capacity(for: count)
    guard capacity > 0 else {
      buckets.removeAll(keepingCapacity: true)
      return
    }

    if buckets.count < capacity {
      buckets = Array(repeating: (0, 0), count: capacity)
      generation = 1
      return
    }

    if generation == .max {
      generation = 1
      var span = buckets.mutableSpan
      span.update(repeating: (0, 0))
    } else {
      generation &+= 1
    }
  }

  @inline(__always)
  internal mutating func insert(_ index: Int, hash: UInt64, equals: (Int) -> Bool) -> Int? {
    guard !buckets.isEmpty else { return nil }

    let mask = buckets.count - 1
    var bucket = Int(truncatingIfNeeded: hash) & mask
    while true {
      let slot = buckets[bucket]
      if slot.gen != generation {
        buckets[bucket] = (Int32(truncatingIfNeeded: index), generation)
        return nil
      }
      let current = Int(slot.index)
      if equals(current) { return current }
      bucket = (bucket + 1) & mask
    }
  }

  @inline(__always)
  private static func capacity(for count: Int) -> Int {
    guard count > 0 else { return 0 }

    var capacity = 8
    while capacity < count * 2 {
      capacity <<= 1
    }
    return capacity
  }
}

extension XML.UnresolvedAttributes.Record {
  @inline(__always)
  internal func normalize(in bytes: borrowing Span<XML.Byte>, source: SourceRange? = nil,
                          into store: inout Arena) throws(XML.Error) -> XML.ResolvedAttributes.Reference {
    let range = source.map { value.absolute(in: $0) } ?? value
    guard !processed else { return .input(range) }
    store.reserve(capacity: bytes.count)
    return try store.append(expanding: bytes.extracting(value), mode: .attribute) ?? .input(range)
  }
}
