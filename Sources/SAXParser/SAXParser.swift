// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

public import XMLCore

/// An event-driven XML parser that calls ``Handler`` callbacks as it reads.
///
/// `SAXParser` streams through the input without building an in-memory tree.
/// Construct one with a handler conforming to ``Handler``, then call
/// ``parse(bytes:)`` to process the document.
///
/// ```swift
/// var parser = SAXParser(handler: MyHandler())
/// try parser.parse(bytes: source)
/// let result = parser.handler.result
/// ```
///
/// The `Processor.Failure == Never` specialisation of ``parse(bytes:)`` avoids
/// per-callback error boxing and should be preferred when handlers do not throw.
public struct SAXParser<Processor: Handler> {
  private struct Declaration: ~Escapable {
    let version: Span<XML.Byte>
    let encoding: Span<XML.Byte>?
    let standalone: Span<XML.Byte>?
  }

  /// The handler that receives parse events.
  public private(set) var handler: Processor
  private var buffer: [XML.Byte] = []

  /// Creates a `SAXParser` that will deliver events to `handler`.
  public init(handler: consuming Processor) {
    self.handler = consume handler
  }

  /// Parses `bytes` as an XML 1.0 document, delivering events to ``handler``.
  ///
  /// - Throws: ``XML/Error`` for well-formedness violations, or
  ///   `Processor.Failure` if a handler callback throws.
  public mutating func parse(bytes: Span<XML.Byte>) throws {
    var parser = Parser(bytes: bytes)
    var namespace = NamespaceResolver(source: bytes)

    handler.location = parser.location
    try handler.start(document: ())

    var location = parser.location
    while let token = try parser.next(location: &location) {
      switch token.value {
      case let .processing(target, data):
        handler.location = location
        if target.equals("xml", insensitive: true) {
          let declaration = try parse(declaration: data)
          try handler.declaration(version: declaration.version,
                                  encoding: declaration.encoding,
                                  standalone: declaration.standalone)
        } else {
          try handler.processing(target: target, data: data)
        }

      case let .comment(content):
        handler.location = location
        try handler.comment(content)

      case let .cdata(content):
        try cdata(content, at: location)

      case let .doctype(name, `public`, system):
        try dtd(name: name, id: (public: `public`, system: system), at: location)

      case let .start(name, attributes, closed):
        let mappings = try namespace.mappings(for: attributes)
        let element = try namespace.resolve(name)
        try start(mappings: mappings, in: namespace, at: location)

        handler.location = location
        try handler.start(element: element.name,
                          namespace: namespace.namespace(of: element),
                          attributes: namespace.resolve(attributes))

        if closed {
          handler.location = location
          try handler.end(element: element.name,
                          namespace: namespace.namespace(of: element))
          try end(mappings: &namespace, location: location)
        }

      case let .end(name):
        let element = try namespace.resolve(name)
        handler.location = location
        try handler.end(element: element.name,
                        namespace: namespace.namespace(of: element))
        try end(mappings: &namespace, location: location)

      case let .text(text):
        handler.location = location
        if token.processed {
          try handler.characters(text)
        } else if try buffer.replace(expanding: text) {
          let expanded = buffer
          try handler.characters(expanded.span)
        } else {
          try handler.characters(text)
        }
      }
    }

    handler.location = parser.location
    try handler.end(document: ())
  }

  @inline(__always)
  private mutating func cdata(_ content: borrowing Span<XML.Byte>,
                              at location: XML.Location) throws {
    handler.location = location
    try handler.character(data: content)
  }

  @inline(__always)
  private mutating func dtd(name: borrowing Span<XML.Byte>,
                            id: (public: Span<XML.Byte>?, system: Span<XML.Byte>?),
                            at location: XML.Location) throws {
    handler.location = location
    try handler.start(dtd: name, id: id)
    handler.location = location
    try handler.end(dtd: ())
  }

  @inline(__always)
  private mutating func start(mappings bindings: Range<Int>,
                              in namespace: borrowing NamespaceResolver,
                              at location: XML.Location) throws {
    guard !bindings.isEmpty else { return }
    for binding in bindings {
      handler.location = location
      try handler.start(mapping: namespace.prefix(for: binding),
                        uri: namespace.uri(for: binding))
    }
  }

  @inline(__always)
  private mutating func end(mappings namespace: inout NamespaceResolver,
                            location: XML.Location) throws {
    let bindings = try namespace.popScope()
    guard !bindings.isEmpty else { return }
    for binding in bindings.reversed() {
      handler.location = location
      try handler.end(mapping: namespace.prefix(for: binding))
    }
    namespace.remove(bindings: bindings)
  }

  // [23] XMLDecl      ::= '<?xml' VersionInfo EncodingDecl? SDDecl? S? '?>'
  // [24] VersionInfo  ::= S 'version' Eq ("'" VersionNum "'" | '"' VersionNum '"')
  // [80] EncodingDecl ::= S 'encoding' Eq ('"' EncName '"' | "'" EncName "'")
  // [32] SDDecl       ::= S 'standalone' Eq (("'" ('yes' | 'no') "'") | ('"' ('yes' | 'no') '"'))
  @_lifetime(borrow data)
  private func parse(declaration data: Span<XML.Byte>?) throws(XML.Error) -> Declaration {
    guard let data else { throw .invalidAttribute }

    var version: Span<XML.Byte>?
    var encoding: Span<XML.Byte>?
    var standalone: Span<XML.Byte>?

    var iterator = XML.AttributeIterator(bytes: data)
    while let (nameRange, valueRange, _) = try iterator.next() {
      let name = data.extracting(nameRange)
      let value = data.extracting(valueRange)
      if name == StaticString("version") {
        guard version == nil else { throw .invalidAttribute }
        version = value
      } else if name == StaticString("encoding") {
        guard encoding == nil else { throw .invalidAttribute }
        encoding = value
      } else if name == StaticString("standalone") {
        guard standalone == nil else { throw .invalidAttribute }
        standalone = value
      } else {
        throw .invalidAttribute
      }
    }

    guard let version else { throw .invalidAttribute }
    guard version == StaticString("1.0") else { throw .invalidAttribute }
    if let standalone {
      guard standalone == StaticString("yes") || standalone == StaticString("no") else {
        throw .invalidAttribute
      }
    }

    return Declaration(version: version, encoding: encoding, standalone: standalone)
  }
}

private struct Parser: ~Copyable, ~Escapable {
  private struct State: ~Copyable {
    private var elements = Stack<SourceRange>()
    private var seenDeclaration = false
    private var seenDoctype = false
    private var seenRoot = false
    private var finishedRoot = false
    private var seenToken = false

    fileprivate var isComplete: Bool {
      seenRoot && finishedRoot && elements.isEmpty
    }

    @inline(__always)
    private static func space(_ bytes: borrowing Span<XML.Byte>) -> Bool {
      for i in 0 ..< bytes.count {
        if !bytes[i].isXMLASCIIWhitespace { return false }
      }
      return true
    }

    mutating func validate(_ token: Located<XML.Token>,
                           in bytes: borrowing Span<XML.Byte>) throws(XML.Error) {
      switch token.value {
      case let .processing(target, _):
        if target.equals("xml", insensitive: true) {
          guard !seenToken, !seenDeclaration else { throw .invalidName }
          seenDeclaration = true
        }

      case .comment:
        break

      case .doctype:
        guard !seenRoot, elements.isEmpty, !finishedRoot, !seenDoctype else {
          throw .invalidDocument
        }
        seenDoctype = true

      case .cdata:
        guard seenRoot, !elements.isEmpty else { throw .invalidDocument }

      case let .start(name, _, closed):
        guard !finishedRoot else { throw .invalidDocument }
        seenRoot = true
        if !closed {
          elements.push(Self.range(token.source, length: name.count))
        } else if elements.isEmpty {
          finishedRoot = true
        }

      case let .end(name):
        guard let last = elements.last, name == bytes.extracting(last) else {
          throw .invalidDocument
        }
        elements.pop()
        if elements.isEmpty {
          finishedRoot = true
        }

      case let .text(text):
        if elements.isEmpty, !Self.space(text) {
          throw .invalidDocument
        }
      }

      seenToken = true
    }

    private static func range(_ source: SourceRange, length: Int) -> SourceRange {
      SourceRange(source.lowerBound + 1 ..< source.lowerBound + 1 + length)
    }
  }

  private var lexer: XML.Lexer
  private var state = State()

  @_lifetime(borrow bytes)
  fileprivate init(bytes: Span<XML.Byte>) {
    self.lexer = XML.Lexer(bytes: bytes, cursor: bytes.sniff)
  }

  fileprivate var location: XML.Location {
    lexer.location
  }

  @_lifetime(self: copy self)
  @_lifetime(&self)
  mutating func next(location: inout XML.Location) throws(XML.Error) -> Located<XML.Token>? {
    location = lexer.location
    let bytes = lexer.bytes
    let token: Located<XML.Token>? = try lexer.next()
    guard let token else {
      guard state.isComplete else { throw .invalidDocument }
      return nil
    }

    try state.validate(token, in: bytes)
    return token
  }
}

// MARK: - Failure == Never (no error boxing on handler calls)

extension SAXParser where Processor.Failure == Never {
  /// Parses `bytes` as an XML 1.0 document, delivering events to ``handler``.
  ///
  /// - Throws: ``XML/Error`` for well-formedness violations.
  // The body is intentionally duplicated from the generic overload so the
  // compiler can eliminate per-callback error boxing when Failure == Never.
  // Do not fold the two paths together without measuring SIL.
  public mutating func parse(bytes: Span<XML.Byte>) throws(XML.Error) {
    var parser = Parser(bytes: bytes)
    var namespace = NamespaceResolver(source: bytes)

    handler.location = parser.location
    handler.start(document: ())

    var location = parser.location
    while let token = try parser.next(location: &location) {
      switch token.value {
      case let .processing(target, data):
        handler.location = location
        if target.equals("xml", insensitive: true) {
          let declaration = try parse(declaration: data)
          handler.declaration(version: declaration.version,
                              encoding: declaration.encoding,
                              standalone: declaration.standalone)
        } else {
          handler.processing(target: target, data: data)
        }

      case let .comment(content):
        handler.location = location
        handler.comment(content)

      case let .cdata(content):
        cdata(content, at: location)

      case let .doctype(name, `public`, system):
        dtd(name: name, id: (public: `public`, system: system), at: location)

      case let .start(name, attributes, closed):
        let mappings = try namespace.mappings(for: attributes)
        let element = try namespace.resolve(name)
        start(mappings: mappings, in: namespace, at: location)

        handler.location = location
        handler.start(element: element.name,
                      namespace: namespace.namespace(of: element),
                      attributes: namespace.resolve(attributes))

        if closed {
          handler.location = location
          handler.end(element: element.name,
                      namespace: namespace.namespace(of: element))
          try end(mappings: &namespace, location: location)
        }

      case let .end(name):
        let element = try namespace.resolve(name)
        handler.location = location
        handler.end(element: element.name,
                    namespace: namespace.namespace(of: element))
        try end(mappings: &namespace, location: location)

      case let .text(text):
        handler.location = location
        if token.processed {
          handler.characters(text)
        } else if try buffer.replace(expanding: text) {
          let expanded = buffer
          handler.characters(expanded.span)
        } else {
          handler.characters(text)
        }
      }
    }

    handler.location = parser.location
    handler.end(document: ())
  }

  @inline(__always)
  private mutating func cdata(_ content: borrowing Span<XML.Byte>,
                              at location: XML.Location) {
    handler.location = location
    handler.character(data: content)
  }

  @inline(__always)
  private mutating func dtd(name: borrowing Span<XML.Byte>,
                            id: (public: Span<XML.Byte>?, system: Span<XML.Byte>?),
                            at location: XML.Location) {
    handler.location = location
    handler.start(dtd: name, id: id)
    handler.location = location
    handler.end(dtd: ())
  }

  @inline(__always)
  private mutating func start(mappings bindings: Range<Int>,
                              in namespace: borrowing NamespaceResolver,
                              at location: XML.Location) {
    guard !bindings.isEmpty else { return }
    for binding in bindings {
      handler.location = location
      handler.start(mapping: namespace.prefix(for: binding),
                    uri: namespace.uri(for: binding))
    }
  }

  @inline(__always)
  private mutating func end(mappings namespace: inout NamespaceResolver,
                            location: XML.Location) throws(XML.Error) {
    let bindings = try namespace.popScope()
    guard !bindings.isEmpty else { return }
    for binding in bindings.reversed() {
      handler.location = location
      handler.end(mapping: namespace.prefix(for: binding))
    }
    namespace.remove(bindings: bindings)
  }
}
