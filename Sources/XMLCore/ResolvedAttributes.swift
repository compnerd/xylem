// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

extension XML {
  /// An attribute list after namespace prefixes have been resolved to URIs.
  ///
  /// Produced by `SAXParser`'s namespace resolver from a corresponding
  /// ``XML/UnresolvedAttributes`` value. Attribute values that required entity
  /// expansion are stored in an internal buffer rather than pointing back into
  /// the source; callers receive the same `Span<XML.Byte>` API regardless.
  public struct ResolvedAttributes: ~Escapable {
    package enum Reference {
      case input(SourceRange)
      case buffer(Range<Int>)
    }

    package struct Record {
      package let name: SourceRange
      package let colon: Int?
      package let value: Reference
      package let namespace: Reference?

      package init(name: SourceRange, colon: Int?, value: Reference, namespace: Reference?) {
        self.name = name
        self.colon = colon
        self.value = value
        self.namespace = namespace
      }
    }

    private let source: Span<Byte>
    package let range: SourceRange
    private let buffer: [Byte]
    private let records: [Record]

    @_lifetime(borrow source)
    package init(source: borrowing Span<Byte>, range: SourceRange,
                 buffer: consuming [Byte], records: consuming [Record]) {
      self.source = copy source
      self.range = range
      self.buffer = consume buffer
      self.records = consume records
    }

    /// The number of attributes in the list.
    public var count: Int {
      @inline(__always) get { records.count }
    }

    /// `true` when the element has no attributes.
    public var isEmpty: Bool {
      @inline(__always) get { records.isEmpty }
    }

    /// Valid indices for accessing attributes by position.
    public var indices: Range<Int> {
      @inline(__always) get { records.indices }
    }

    /// Returns a view onto the qualified name of the attribute at `index`.
    @inline(__always)
    @_lifetime(borrow self)
    public func name(at index: Int) -> XML.QualifiedNameView {
      let record = records[index]
      return XML.QualifiedNameView(unvalidated: source,
                                   range: record.name.absolute(in: range),
                                   colon: record.colon)
    }

    /// Returns the namespace URI of the attribute at `index`, or `nil` if the
    /// attribute is in no namespace.
    @inline(__always)
    @_lifetime(borrow self)
    public func namespace(at index: Int) -> Span<XML.Byte>? {
      guard let reference = records[index].namespace else { return nil }
      return span(for: reference)
    }

    /// Returns the normalised value of the attribute at `index`.
    @inline(__always)
    @_lifetime(borrow self)
    public func value(at index: Int) -> Span<XML.Byte> {
      span(for: records[index].value)
    }

    @inline(__always)
    @_lifetime(borrow self)
    private func span(for reference: Reference) -> Span<Byte> {
      switch reference {
      case let .input(range):
        return source.extracting(range.absolute(in: self.range))
      case let .buffer(range):
        return buffer.span.extracting(range)
      }
    }
  }
}
