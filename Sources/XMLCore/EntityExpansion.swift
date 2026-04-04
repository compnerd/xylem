// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

package enum Expansion {
  case attribute
  case text

  @inline(__always)
  fileprivate func stops(at byte: XML.Byte) -> Bool {
    switch self {
    case .attribute:
      byte == UInt8(ascii: "&")
          || byte == UInt8(ascii: "\t")
          || byte == UInt8(ascii: "\n")
          || byte == UInt8(ascii: "\r")

    case .text:
      byte == UInt8(ascii: "&")
    }
  }

  @inline(__always)
  fileprivate var invalid: XML.Error {
    self == .attribute ? .invalidAttribute : .invalidCharacter
  }
}

private enum Radix {
  case decimal
  case hexadecimal

  @inline(__always)
  fileprivate static func classify(_ bytes: borrowing Span<XML.Byte>, at start: Int) throws(XML.Error) -> (radix: Self, index: Int) {
    switch bytes[start] {
    case UInt8(ascii: "x"):
      let index = start + 1
      guard index < bytes.count else { throw .unexpectedEOF }
      return (.hexadecimal, index)

    case UInt8(ascii: "0") ... UInt8(ascii: "9"):
      return (.decimal, start)

    default:
      throw .invalidCharacter
    }
  }

  @inline(__always)
  fileprivate func scan(_ bytes: borrowing Span<XML.Byte>, at start: Int) throws(XML.Error) -> (value: UInt32, index: Int) {
    var value: UInt32 = 0
    var index = start
    var overflow: Bool

    while index < bytes.count, bytes[index] != UInt8(ascii: ";") {
      let digit: UInt32 = switch bytes[index] {
      case UInt8(ascii: "0") ... UInt8(ascii: "9"):
        UInt32(bytes[index] - UInt8(ascii: "0"))
      case UInt8(ascii: "A") ... UInt8(ascii: "F"),
           UInt8(ascii: "a") ... UInt8(ascii: "f") where self == .hexadecimal:
        UInt32((bytes[index] & ~0x20) - UInt8(ascii: "A")) + 10
      default:
        throw .invalidCharacter
      }

      (value, overflow) = value.multipliedReportingOverflow(by: base)
      guard !overflow else { throw .invalidCharacter }
      (value, overflow) = value.addingReportingOverflow(digit)
      guard !overflow else { throw .invalidCharacter }
      index += 1
    }

    guard index < bytes.count, index > start else { throw .invalidCharacter }
    return (value, index)
  }

  @inline(__always)
  private var base: UInt32 {
    switch self {
    case .decimal:      10
    case .hexadecimal:  16
    }
  }
}

// [66] CharRef ::= '&#' [0-9]+ ';' | '&#x' [0-9a-fA-F]+ ';'
@inline(__always)
private func parse(reference bytes: borrowing Span<XML.Byte>, at start: Int) throws(XML.Error) -> (scalar: Unicode.Scalar, index: Int) {
  guard start < bytes.count else { throw .unexpectedEOF }

  let (radix, index) = try Radix.classify(bytes, at: start)
  let (value, next) = try radix.scan(bytes, at: index)
  guard let scalar = Unicode.Scalar(value), scalar.isXMLChar else {
    throw .invalidCharacter
  }
  return (scalar, next + 1)
}

extension Array where Element == XML.Byte {
  @inline(__always)
  package mutating func append(expanding bytes: borrowing Span<XML.Byte>, mode: Expansion = .text) throws(XML.Error) -> Range<Int>? {
    var index = 0
    while index < bytes.count, !mode.stops(at: bytes[index]) { index += 1 }
    guard index < bytes.count else { return nil }

    let start = count
    reserveCapacity(count + bytes.count)
    append(bytes, in: 0 ..< index)

    while index < bytes.count {
      switch bytes[index] {
      case UInt8(ascii: "&"):
        try append(reference: bytes, at: &index, mode: mode)

      case UInt8(ascii: "\t"), UInt8(ascii: "\n"):
        append(whitespace: bytes[index], mode: mode)
        index += 1

      case UInt8(ascii: "\r"):
        append(whitespace: bytes[index], mode: mode)
        index += 1
        // XML line-end normalization treats CRLF and bare CR as one line break.
        if mode == .attribute, index < bytes.count, bytes[index] == UInt8(ascii: "\n") {
          index += 1
        }

      default:
        try append(verbatim: bytes, at: &index, mode: mode)
      }
    }

    return start ..< count
  }

  @inline(__always)
  package mutating func replace(expanding bytes: borrowing Span<XML.Byte>, mode: Expansion = .text) throws(XML.Error) -> Bool {
    removeAll(keepingCapacity: true)
    return try append(expanding: bytes, mode: mode) != nil
  }
}

extension Array where Element == XML.Byte {
  @inline(__always)
  private mutating func append(_ bytes: borrowing Span<XML.Byte>, in range: Range<Int>) {
    bytes.extracting(range).withUnsafeBufferPointer { append(contentsOf: $0) }
  }

  @inline(__always)
  private mutating func append(_ scalar: Unicode.Scalar, mode: Expansion) {
    // Normalize space characters in attribute values to a single space (§3.3.3).
    if mode == .attribute, scalar.isXMLSpace { return append(UInt8(ascii: " ")) }
    append(contentsOf: scalar.utf8)
  }

  // [67] Reference ::= EntityRef | CharRef
  // [68] EntityRef ::= '&' Name ';'
  // [66] CharRef   ::= '&#' [0-9]+ ';' | '&#x' [0-9a-fA-F]+ ';'
  @inline(__always)
  private mutating func append(reference bytes: borrowing Span<XML.Byte>, at index: inout Int, mode: Expansion) throws(XML.Error) {
    guard index + 1 < bytes.count else { throw .unexpectedEOF }
    index += 1

    switch bytes[index] {
    case UInt8(ascii: "#"):
      let (scalar, next) = try parse(reference: bytes, at: index + 1)
      append(scalar, mode: mode)
      index = next

    default:
      let start = index
      // Scan for ';' from index — entity names in valid XML are always short
      // ASCII strings (lt, gt, amp, apos, quot), so skip XML.Name.scan().
      guard let offset = bytes.extracting(start...).first(UInt8(ascii: ";")) else {
        index = bytes.count
        throw .unexpectedEOF
      }
      let end = start + offset
      guard end > start else { throw .invalidCharacter }
      try append(entity: bytes.extracting(start ..< end), mode: mode)
      index = end + 1
    }
  }

  @inline(__always)
  private mutating func append(whitespace byte: XML.Byte, mode: Expansion) {
    append(mode == .attribute ? UInt8(ascii: " ") : byte)
  }

  @inline(__always)
  private mutating func append(verbatim bytes: borrowing Span<XML.Byte>, at index: inout Int, mode: Expansion) throws(XML.Error) {
    if mode == .text, bytes.matches("]]>", at: index) {
      throw .invalidCharacter
    }
    let start = index
    while index < bytes.count, !mode.stops(at: bytes[index]) { index += 1 }
    append(bytes, in: start ..< index)
  }

  // [68] EntityRef — only the five predefined XML entities (§4.6) are recognized.
  @inline(__always)
  private mutating func append(entity: borrowing Span<XML.Byte>, mode: Expansion) throws(XML.Error) {
    switch entity {
    case "lt":
      append(UInt8(ascii: "<"))
    case "gt":
      append(UInt8(ascii: ">"))
    case "amp":
      append(UInt8(ascii: "&"))
    case "apos":
      append(UInt8(ascii: "'"))
    case "quot":
      append(UInt8(ascii: "\""))
    default:
      // User-defined entity declarations are not implemented yet, so only the
      // predefined XML entities are accepted here.
      throw mode.invalid
    }
  }
}
