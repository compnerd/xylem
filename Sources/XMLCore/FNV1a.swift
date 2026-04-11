// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

package enum FNV1a {
  package struct Hash32 {
    @inline(__always)
    package init() {}

    @inline(__always)
    package private(set) var value: UInt32 = 0x811c_9dc5

    @inline(__always)
    package mutating func mix(_ bytes: borrowing Span<UInt8>) {
      for i in 0 ..< bytes.count {
        value ^= UInt32(bytes[i])
        value &*= 0x0100_0193
      }
    }

    @inline(__always)
    package mutating func mix(_ string: borrowing String) {
      let string = copy string
      let span = string.utf8.span
      for i in 0 ..< span.count {
        value ^= UInt32(span[i])
        value &*= 0x0100_0193
      }
    }
  }

  package struct Hash64 {
    @inline(__always)
    package init() {}

    @inline(__always)
    package private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    @inline(__always)
    package mutating func mix(_ bytes: borrowing Span<UInt8>) {
      for i in 0 ..< bytes.count {
        value ^= UInt64(bytes[i])
        value &*= 0x0000_0100_0000_01b3
      }
    }

    @inline(__always)
    package mutating func mix(_ literal: StaticString) {
      precondition(literal.hasPointerRepresentation)
      literal.withUTF8Buffer { buffer in
        for byte in buffer {
          value ^= UInt64(byte)
          value &*= 0x0000_0100_0000_01b3
        }
      }
    }

    @inline(__always)
    package mutating func mix(_ byte: UInt8) {
      value ^= UInt64(byte)
      value &*= 0x0000_0100_0000_01b3
    }
  }

  @inline(__always)
  package static func hash32(_ bytes: borrowing Span<UInt8>) -> UInt32 {
    var hash = Hash32()
    hash.mix(bytes)
    return hash.value
  }

  @inline(__always)
  package static func hash32(_ string: borrowing String) -> UInt32 {
    var hash = Hash32()
    hash.mix(string)
    return hash.value
  }

  @inline(__always)
  package static func hash64(_ bytes: borrowing Span<UInt8>) -> UInt64 {
    var hash = Hash64()
    hash.mix(bytes)
    return hash.value
  }

  @inline(__always)
  package static func hash64(_ literal: StaticString) -> UInt64 {
    var hash = Hash64()
    hash.mix(literal)
    return hash.value
  }
}
