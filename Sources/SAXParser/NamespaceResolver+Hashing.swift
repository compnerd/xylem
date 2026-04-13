// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import XMLCore

@inline(__always)
@_lifetime(borrow source, borrow storage)
private func span(of reference: XML.ResolvedAttributes.Reference,
                  in source: borrowing Span<XML.Byte>,
                  storage: borrowing Span<XML.Byte>) -> Span<XML.Byte> {
  switch reference {
  case let .input(range):  source.extracting(range)
  case let .buffer(range): storage.extracting(range)
  }
}

@inline(__always)
internal func hash(namespace: XML.ResolvedAttributes.Reference?,
                   local: borrowing Span<XML.Byte>,
                   in source: borrowing Span<XML.Byte>,
                   storage: borrowing Span<XML.Byte>) -> UInt64 {
  var hash = FNV1a.Hash64()
  if let namespace {
    hash.mix(span(of: namespace, in: source, storage: storage))
    hash.mix(UInt8(0x00))
  } else {
    hash.mix(UInt8(0xff))
  }
  hash.mix(local)
  return hash.value
}

internal enum Bytes {
  @inline(__always)
  internal static func equal(_ lhs: XML.ResolvedAttributes.Reference,
                             _ rhs: XML.ResolvedAttributes.Reference,
                             in source: borrowing Span<XML.Byte>,
                             storage: borrowing Span<XML.Byte>) -> Bool {
    span(of: lhs, in: source, storage: storage) == span(of: rhs, in: source, storage: storage)
  }

  @inline(__always)
  internal static func equal(_ lhs: XML.ResolvedAttributes.Reference?,
                             _ rhs: XML.ResolvedAttributes.Reference?,
                             in source: borrowing Span<XML.Byte>,
                             storage: borrowing Span<XML.Byte>) -> Bool {
    guard let lhs else { return rhs == nil }
    guard let rhs else { return false }
    return equal(lhs, rhs, in: source, storage: storage)
  }
}
