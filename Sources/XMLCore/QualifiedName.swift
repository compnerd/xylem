// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

extension XML {
  /// A non-owning view onto a qualified XML name within a source span.
  ///
  /// The name bytes are borrowed from the enclosing input buffer. Split the
  /// name into ``prefix`` and ``local`` parts via the two computed properties;
  /// both return sub-spans of the same underlying storage.
  ///
  /// When you need to store a name beyond the source buffer's lifetime, copy
  /// it into a ``XML/QualifiedName``.
  public struct QualifiedNameView: ~Escapable {
    /// The raw UTF-8 bytes of the full qualified name, including any prefix.
    public let bytes: Span<Byte>

    /// The byte offset of the `:` separator, or `nil` for unqualified names.
    public let colon: Int?

    /// The namespace prefix — the portion before the `:` — or `nil` for
    /// unqualified names.
    public var prefix: Span<Byte>? {
      @_lifetime(borrow self) get {
        guard let colon else { return nil }
        return bytes.extracting(0 ..< colon)
      }
    }

    /// The local part of the name — the portion after the `:`, or the full
    /// name when no prefix is present.
    public var local: Span<Byte> {
      @_lifetime(borrow self) get {
        if let colon { return bytes.extracting((colon + 1)...) }
        return bytes
      }
    }

    /// Creates a view after validating that `bytes` is a well-formed XML
    /// qualified name.
    ///
    /// - Throws: ``XML/Error/invalidName`` if `bytes` is not a valid
    ///   `QName` per the XML Namespaces 1.0 production.
    @_lifetime(borrow bytes)
    public init(validating bytes: borrowing Span<Byte>, colon: Span<Byte>.Index? = nil) throws(Error) {
      self.bytes = copy bytes
      self.colon = try QualifiedName.scan(bytes, colon: colon)
    }

    @_lifetime(copy bytes)
    package init(unvalidated bytes: borrowing Span<Byte>, colon: Span<Byte>.Index? = nil) {
      self.bytes = copy bytes
      self.colon = colon
    }

    @_lifetime(borrow bytes)
    package init(unvalidated bytes: borrowing Span<Byte>, range: SourceRange, colon: Int?) {
      self.bytes = bytes.extracting(range)
      self.colon = colon
    }
  }
}

extension XML {
  /// An owned, copyable qualified XML name.
  ///
  /// Unlike ``XML/QualifiedNameView``, `QualifiedName` owns its byte storage
  /// and can outlive the source document buffer. Use it when you need to store
  /// a name in a collection, dictionary key, or other long-lived structure.
  public struct QualifiedName {
    private let storage: [Byte]

    /// The byte offset of the `:` separator, or `nil` for unqualified names.
    public let colon: Int?

    // ':' is ASCII (0x3a) and cannot appear as a UTF-8 continuation byte.
    @inline(__always)
    private static func split(_ bytes: borrowing Span<Byte>) throws(Error) -> Int? {
      var colon: Int? = nil
      for index in 0 ..< bytes.count where bytes[index] == UInt8(ascii: ":") {
        guard colon == nil else { throw .invalidName }
        colon = index
      }
      return colon
    }

    @inline(__always)
    private static func validate(_ bytes: borrowing Span<Byte>, at offset: Int) throws(Error) {
      let first = bytes[offset]
      if first < 0x80 {
        guard first.isXMLASCIINameStartChar,
              first != UInt8(ascii: ":") else {
          throw .invalidName
        }
      } else {
        guard let decoded = try bytes.decodeScalar(at: offset),
              decoded.scalar.isXMLNameStartChar else {
          throw .invalidName
        }
      }
    }

    // Namespaces in XML 1.0 §3:
    // [7] QName   ::= PrefixedName | UnprefixedName
    // [8] PrefixedName   ::= Prefix ':' LocalPart
    // [9] UnprefixedName ::= LocalPart
    // [6] NCName  ::= Name - (Char* ':' Char*)
    @inline(__always)
    package static func scan(_ bytes: borrowing Span<Byte>, colon: Span<Byte>.Index? = nil) throws(Error) -> Int? {
      guard let colon = if let colon { colon } else { try QualifiedName.split(bytes) } else {
        guard !bytes.isEmpty, try Name.scan(bytes).bytes == bytes.count else {
          throw .invalidName
        }
        return nil
      }

      let prefix = bytes.extracting(0 ..< colon)
      guard !prefix.isEmpty,
            prefix.first(UInt8(ascii: ":")) == nil,
            try Name.scan(prefix).bytes == prefix.count else {
        throw .invalidName
      }

      let local = bytes.extracting((colon + 1)...)
      guard !local.isEmpty,
            local.first(UInt8(ascii: ":")) == nil,
            try Name.scan(local).bytes == local.count else {
        throw .invalidName
      }

      return colon
    }

    // Fast path for names already lexed as XML Name.
    @inline(__always)
    package static func validate(_ name: borrowing Span<Byte>,
                                 colon: Span<Byte>.Index?) throws(Error) {
      guard let colon else { return }
      guard colon > 0, colon + 1 < name.count else { throw .invalidName }

      try validate(name, at: colon + 1)
      for index in (colon + 1) ..< name.count where name[index] == UInt8(ascii: ":") {
        throw .invalidName
      }
    }

    // Fast path for NCName already lexed as XML Name.
    @inline(__always)
    package static func validate(_ name: borrowing Span<Byte>) throws(Error) {
      guard !name.isEmpty else { throw .invalidName }
      try validate(name, at: 0)
      guard name.first(UInt8(ascii: ":")) == nil else { throw .invalidName }
    }

    /// The namespace prefix, or `nil` for unqualified names.
    public var prefix: Span<Byte>? {
      @_lifetime(borrow self) get {
        guard let colon else { return nil }
        return bytes.extracting(0 ..< colon)
      }
    }

    /// The local part of the name.
    public var local: Span<Byte> {
      @_lifetime(borrow self) get {
        if let colon { return bytes.extracting((colon + 1)...) }
        return bytes
      }
    }

    /// The full qualified name bytes, including any prefix.
    public var bytes: Span<Byte> {
      @_lifetime(borrow self) get {
        storage.span
      }
    }

    package init(materializing name: borrowing QualifiedNameView) {
      self.storage = name.bytes.withUnsafeBufferPointer(Array.init)
      self.colon = name.colon
    }

    /// Creates an owned `QualifiedName` after validating `bytes`.
    ///
    /// - Throws: ``XML/Error/invalidName`` if the bytes are not a valid XML
    ///   qualified name.
    public init(validating bytes: borrowing Span<Byte>, colon: Span<Byte>.Index? = nil) throws(Error) {
      self.init(materializing: try QualifiedNameView(validating: bytes, colon: colon))
    }

  }
}
