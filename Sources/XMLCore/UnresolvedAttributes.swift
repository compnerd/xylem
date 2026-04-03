// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

extension XML {
  /// The raw, pre-namespace-resolution attribute list attached to a start tag.
  ///
  /// All spans borrow directly from the enclosing ``XML/Lexer`` input; no
  /// content is copied. Namespace resolution converts this into a
  /// ``XML/ResolvedAttributes`` value.
  public struct UnresolvedAttributes: ~Escapable {
    package struct Record {
      package let name: SourceRange
      package let colon: Int?
      package let value: SourceRange
      package let processed: Bool
      package let declaration: Bool
      package let prefix: SourceRange?

      package init(name: SourceRange, colon: Int?, value: SourceRange, processed: Bool,
                   declaration: Bool, prefix: SourceRange?) {
        self.name = name
        self.colon = colon
        self.value = value
        self.processed = processed
        self.declaration = declaration
        self.prefix = prefix
      }
    }

    package let source: Span<Byte>
    package let range: SourceRange
    package let namespaced: Bool
    package let records: [Record]

    @_lifetime(borrow source)
    package init(source: borrowing Span<Byte>, range: SourceRange, records: [Record], namespaced: Bool) {
      self.source = copy source
      self.range = range
      self.records = records
      self.namespaced = namespaced
    }

    package var bytes: Span<Byte> {
      @inline(__always)
      @_lifetime(borrow self) get {
        source.extracting(range)
      }
    }

    package var count: Int {
      @inline(__always) get { records.count }
    }

    package var isEmpty: Bool {
      @inline(__always) get { records.isEmpty }
    }
  }
}
