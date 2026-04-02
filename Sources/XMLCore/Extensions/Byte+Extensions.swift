// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

extension XML {
  // Bitmap for ASCII name characters: A-Z, a-z, 0-9, :, _, -, .
  // Two 64-bit words cover bytes 0x00–0x3f and 0x40–0x7f.

  @inline(__always)
  fileprivate static var NameCharBitmap: (high: UInt64, low: UInt64) {
    // High bits for 'A'-'Z'(0x41-0x5a) '_'(0x5f) 'a'-'z'(0x61-0x7a)
    // Low bits for '-'(0x2d) '.'(0x2e) '0'-'9'(0x30-0x39) ':'(0x3a)
    return (high: 0x07ff_fffe_87ff_fffe, low: 0x07ff_6000_0000_0000)
  }

  @inline(__always)
  fileprivate static var NameStartCharBitmap: (high: UInt64, low: UInt64) {
    // High bits for 'A'-'Z'(0x41-0x5a) '_'(0x5f) 'a'-'z'(0x61-0x7a)
    // Low bits for ':'(0x3a)
    return (high: 0x07ff_fffe_87ff_fffe, low: 0x0400_0000_0000_0000)
  }
}

extension XML.Byte {
  // ASCII NameStartChar per XML 1.0 §2.3
  // [4]: ':' | [A-Z] | '_' | [a-z]
  @inline(__always)
  package var isXMLASCIINameStartChar: Bool {
    if self < 0x40 { return (XML.NameStartCharBitmap.low &>> self) & 1 == 1 }
    return XML.NameStartCharBitmap.high &>> (self &- 0x40) & 1 == 1
  }

  // ASCII NameChar per XML 1.0 §2.3
  // [4a]: NameStartChar | '-' | '.' | [0-9]
  @inline(__always)
  package var isXMLASCIINameChar: Bool {
    if self < 0x40 { return (XML.NameCharBitmap.low &>> self) & 1 == 1 }
    return XML.NameCharBitmap.high &>> (self &- 0x40) & 1 == 1
  }

  // [3]: S — XML whitespace.
  @inline(__always)
  package var isXMLASCIIWhitespace: Bool {
    self == UInt8(ascii: "\t") || self == UInt8(ascii: "\n") || self == UInt8(ascii: "\r") || self == UInt8(ascii: " ")
  }

  @inline(__always)
  package var isASCIIDigit: Bool {
    self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9")
  }
}
