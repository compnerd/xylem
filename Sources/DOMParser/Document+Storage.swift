// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

extension Document {
  // MARK: - Internal storage types

  // An offset + length pair into `Document.storage`.
  // A sentinel value with `start == -1` represents an absent field;
  // consistent with the `-1` convention used for all other navigation fields.
  package struct Slice {
    package var start: Int32
    package var count: Int32

    package var range: Range<Int> { Int(start) ..< Int(start) + Int(count) }
    package var absent: Bool { start < 0 }
    package var present: Bool { start >= 0 }
    package static var absent: Slice { Slice(start: -1, count: 0) }
  }

  package struct Node {
    package var kind: NodeKind
    package var name: (spelling: Slice, hash: UInt32) = (.absent, 0)        // element / PI name; DOCTYPE name + FNV-1a32 of local name
    package var colon: Int32 = -1                                           // ':' offset within `name`; -1 = unqualified
    package var value: Slice = .absent                                      // text / comment / CDATA; PI data; DOCTYPE publicID
    package var extra: Slice = .absent                                      // DOCTYPE systemID; absent for all other kinds
    package var namespace: Slice = .absent                                  // element namespace URI
    package var attributes: (base: Int32, count: Int32) = (-1, 0)           // slice of Document.attributes; -1 = no attributes
    package var location: (line: UInt32, offset: UInt32) = (0, 0)           // source position (1-based line + byte offset)
    // Tree links; -1 = absent
    package var parent: Int32 = -1
    package var children: (first: Int32, last: Int32) = (-1, -1)
    package var sibling: (previous: Int32, next: Int32) = (-1, -1)

    internal init(kind: NodeKind) { self.kind = kind }
  }

  package struct Attribute {
    package var name: (spelling: Slice, hash: UInt32)   // attribute name + FNV-1a32 of local name
    package var colon: Int32                            // ':' offset within `name`; -1 = unqualified
    package var namespace: Slice                        // namespace URI; .absent if unqualified
    package var value: Slice
  }
}
