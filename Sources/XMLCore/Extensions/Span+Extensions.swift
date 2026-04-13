// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

extension Span where Element == XML.Byte {
  // MARK: - Encoding

  // XML Appendix F
  package var sniff: Span<XML.Byte>.Index {
    let b0: XML.Byte = count > 0 ? self[0] : 0
    let b1: XML.Byte = count > 1 ? self[1] : 0
    let b2: XML.Byte = count > 2 ? self[2] : 0
    let b3: XML.Byte = count > 3 ? self[3] : 0

    // UTF-32 cases must precede UTF-16: [ff fe 00 00] shares a prefix with
    // [ff fe]. The three `where count >= 4` guards prevent false matches on
    // short spans when 0x00 appears as a significant byte and coincides with
    // the 0-padding sentinel.
    return switch (b0, b1, b2, b3) {
    case (0x00, 0x00, 0xfe, 0xff):                  4
    case (0x00, 0x00, 0x00, 0x3c):                  0
    case (0xff, 0xfe, 0x00, 0x00) where count >= 4: 4
    case (0x3c, 0x00, 0x00, 0x00) where count >= 4: 0
    case (0xfe, 0xff, _, _):                        2
    case (0x00, 0x3c, 0x00, 0x3f):                  0
    case (0xff, 0xfe, _, _):                        2
    case (0x3c, 0x00, 0x3f, 0x00) where count >= 4: 0
    case (0xef, 0xbb, 0xbf, _):                     3
    default:                                        0
    }
  }

  // MARK: - Search

  @inline(__always)
  package func first(_ element: Element) -> Index? {
    withUnsafeBufferPointer { buffer in
      buffer.firstIndex(of: element)
    }
  }

  @inline(__always)
  package func matches(_ literal: StaticString,
                       at offset: Int = 0,
                       insensitive: Bool = false) -> Bool {
    precondition(literal.hasPointerRepresentation)

    let mask = UInt8(insensitive ? 0x20 : 0x00)
    return literal.withUTF8Buffer { utf8 in
      guard offset >= 0, offset <= count, utf8.count <= count - offset else {
        return false
      }
      for index in 0 ..< utf8.count {
        guard (self[offset + index] | mask) == (utf8[index] | mask) else {
          return false
        }
      }
      return true
    }
  }

  // MARK: - Comparison

  @inline(__always)
  package func equals(_ literal: StaticString, insensitive: Bool) -> Bool {
    precondition(literal.hasPointerRepresentation)

    let mask = UInt8(insensitive ? 0x20 : 0x00)
    return literal.withUTF8Buffer { utf8 in
      guard count == utf8.count else { return false }
      for index in 0 ..< utf8.count {
        guard (self[index] | mask) == (utf8[index] | mask) else { return false }
      }
      return true
    }
  }

  @inline(__always)
  package static func ~= (_ pattern: StaticString, _ value: borrowing Span<Element>) -> Bool {
    value == pattern
  }

  @inline(__always)
  package static func == (_ lhs: borrowing Span<Element>, _ rhs: StaticString) -> Bool {
    precondition(rhs.hasPointerRepresentation)

    return rhs.withUTF8Buffer { rhs in
      guard lhs.count == rhs.count else { return false }
      if lhs.isEmpty { return true }
      for index in 0 ..< rhs.count {
        guard lhs[index] == rhs[index] else { return false }
      }
      return true
    }
  }

  @inline(__always)
  package static func == (_ lhs: borrowing Span<Element>, _ rhs: borrowing String) -> Bool {
    return lhs == rhs.utf8.span
  }

  @inline(__always)
  package static func == (_ lhs: borrowing Span<Element>, _ rhs: borrowing Span<Element>) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for index in 0 ..< lhs.count {
      guard lhs[index] == rhs[index] else { return false }
    }
    return true
  }

  // MARK: - Ranges

  @inline(__always)
  @_lifetime(borrow self)
  package func extracting(_ range: SourceRange) -> Span<Element> {
    extracting(range.bounds)
  }

  // MARK: - Decoding

  // Decode the UTF-8 scalar starting at `offset`. Returns nil at end of input.
  @inline(__always)
  package func decodeScalar(at offset: Int) throws(XML.Error) -> (scalar: Unicode.Scalar, stride: Int)? {
    guard offset < count else { return nil }

    let byte = self[offset]
    if byte < 0x80 { return (Unicode.Scalar(byte), 1) }

    return try withUnsafeBufferPointer { bytes throws(XML.Error) -> (scalar: Unicode.Scalar, stride: Int)? in
      var codec = Unicode.UTF8()
      var iterator = bytes[offset...].makeIterator()
      switch codec.decode(&iterator) {
      case .scalarValue(let scalar): return (scalar, scalar.utf8.count)
      case .emptyInput:              return nil
      case .error:                   throw .invalidEncoding
      }
    }
  }
}
