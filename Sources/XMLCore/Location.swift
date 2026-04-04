// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

extension XML {
  /// The parser's position within the input byte stream.
  ///
  /// Both ``line`` and ``offset`` are 1-based. ``offset`` counts raw UTF-8
  /// bytes from the start of the current line — not Unicode scalar values or
  /// display columns — matching the convention used by libxml2.
  public struct Location: Equatable {
    /// The current line number, starting at 1.
    public let line: Int

    /// The byte offset from the start of the current line, starting at 1.
    public let offset: Int

    /// Creates a location at `line` and `offset`.
    ///
    /// Both parameters default to 1, placing the location at the very start
    /// of the document.
    package init(line: Int = 1, offset: Int = 1) {
      self.line = line
      self.offset = offset
    }
  }
}

extension XML {
  package struct LocationTracker {
    package var line = 1
    package var offset = 0

    @inline(__always)
    package func location(at cursor: Int) -> Location {
      Location(line: line, offset: cursor - offset + 1)
    }

    @inline(__always)
    package mutating func newline(at cursor: Int) {
      line += 1
      offset = cursor + 1
    }
  }
}
