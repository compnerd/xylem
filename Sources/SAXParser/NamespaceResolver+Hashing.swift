// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import XMLCore

@inline(__always)
@_lifetime(borrow source, borrow storage)
private func span(of reference: XML.ResolvedAttributes.Reference,
                  in source: borrowing Span<XML.Byte>,
                  storage: Span<XML.Byte>) -> Span<XML.Byte> {
  switch reference {
  case let .input(range):  source.extracting(range)
  case let .buffer(range): storage.extracting(range)
  }
}

internal struct FNVHasher {
  private static let prime: UInt64 = 0x0000_0100_0000_01b3

  private var value: UInt64 = 0xcbf2_9ce4_8422_2325

  @inline(__always)
  private mutating func mix(_ bytes: borrowing Span<XML.Byte>) {
    for i in 0 ..< bytes.count {
      value ^= UInt64(bytes[i])
      value &*= Self.prime
    }
  }

  @inline(__always)
  private mutating func mix(_ literal: StaticString) {
    precondition(literal.hasPointerRepresentation)
    literal.withUTF8Buffer {
      for byte in $0 {
        value ^= UInt64(byte)
        value &*= Self.prime
      }
    }
  }

  @inline(__always)
  private mutating func mix(_ byte: UInt8) {
    value ^= UInt64(byte)
    value &*= Self.prime
  }

  @inline(__always)
  private mutating func mix(_ reference: XML.ResolvedAttributes.Reference,
                            in source: borrowing Span<XML.Byte>,
                            storage: Span<XML.Byte>) {
    mix(span(of: reference, in: source, storage: storage))
  }

  @inline(__always)
  internal static func hash(_ bytes: borrowing Span<XML.Byte>) -> UInt64 {
    var hash = FNVHasher()
    hash.mix(bytes)
    return hash.value
  }

  @inline(__always)
  internal static func hash(_ literal: StaticString) -> UInt64 {
    var hash = FNVHasher()
    hash.mix(literal)
    return hash.value
  }

  @inline(__always)
  internal static func hash(_ reference: XML.ResolvedAttributes.Reference,
                            in source: borrowing Span<XML.Byte>,
                            storage: Span<XML.Byte>) -> UInt64 {
    var hash = FNVHasher()
    hash.mix(reference, in: source, storage: storage)
    return hash.value
  }

  @inline(__always)
  internal static func hash(_ namespace: XML.ResolvedAttributes.Reference?,
                            local: borrowing Span<XML.Byte>,
                            in source: borrowing Span<XML.Byte>,
                            storage: Span<XML.Byte>) -> UInt64 {
    var hash = FNVHasher()
    if let namespace {
      hash.mix(namespace, in: source, storage: storage)
      hash.mix(UInt8(0x00))
    } else {
      hash.mix(UInt8(0xff))
    }
    hash.mix(local)
    return hash.value
  }
}

internal enum Bytes {
  @inline(__always)
  internal static func equal(_ lhs: XML.ResolvedAttributes.Reference,
                             _ rhs: XML.ResolvedAttributes.Reference,
                             in source: borrowing Span<XML.Byte>,
                             storage: Span<XML.Byte>) -> Bool {
    span(of: lhs, in: source, storage: storage) == span(of: rhs, in: source, storage: storage)
  }

  @inline(__always)
  internal static func equal(_ lhs: XML.ResolvedAttributes.Reference?,
                             _ rhs: XML.ResolvedAttributes.Reference?,
                             in source: borrowing Span<XML.Byte>,
                             storage: Span<XML.Byte>) -> Bool {
    guard let lhs else { return rhs == nil }
    guard let rhs else { return false }
    return equal(lhs, rhs, in: source, storage: storage)
  }
}
