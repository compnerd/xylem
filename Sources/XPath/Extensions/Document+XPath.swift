// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import XMLCore
internal import DOMParser

extension Document {
  internal enum NameType {
    case qualified
    case local
  }

  @inline(__always)
  internal func reference(_ index: Int32) -> Reference? {
    if index >= 0 { return Reference(index: Int(index)) }
    return nil
  }

  @inline(__always)
  @_lifetime(borrow self)
  internal func span(_ slice: Slice) -> Span<XML.Byte> {
    storage.span.extracting(slice.range)
  }

  @inline(__always)
  internal func string(_ slice: Slice) -> String {
    String(span(slice))
  }

  @inline(__always)
  internal func number(_ slice: Slice) -> Double {
    Double(string(slice).trimmed()) ?? .nan
  }
}
