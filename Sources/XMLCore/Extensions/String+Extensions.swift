// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

extension String {
  @inline(__always)
  package func fnv1a32() -> UInt32 {
    let string = self
    let span = string.utf8.span
    var hash: UInt32 = 2_166_136_261
    for i in 0 ..< span.count {
      hash ^= UInt32(span[i])
      hash &*= 16_777_619
    }
    return hash
  }

  @inline(__always)
  package init(_ span: borrowing Span<XML.Byte>) {
    self = span.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
  }

  @inline(__always)
  package func trimmed() -> String {
    let scalars = unicodeScalars
    var lower = scalars.startIndex
    var upper = scalars.endIndex
    while lower < upper, scalars[lower].isXMLSpace { scalars.formIndex(after: &lower) }
    while upper > lower, scalars[scalars.index(before: upper)].isXMLSpace {
      scalars.formIndex(before: &upper)
    }
    return String(scalars[lower..<upper])
  }
}
