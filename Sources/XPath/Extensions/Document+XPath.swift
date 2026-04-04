// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import XMLCore
internal import DOMParser

extension Document.NodeKind {
  @inline(__always)
  internal var textual: Bool {
    self == .text || self == .cdata
  }
}

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
  internal func attribute(of handle: Reference) -> Attribute? {
    guard let (element, position) = handle.attribute else { return nil }
    let node = nodes[element]
    let base = Int(node.attributes.base)
    assert(base >= 0 && position < Int(node.attributes.count))
    return attributes[base + position]
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
    span(slice).withUnsafeBufferPointer {
      Double(String(decoding: $0, as: UTF8.self).trimmed()) ?? .nan
    }
  }
}
