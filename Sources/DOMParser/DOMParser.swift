// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import SAXParser
public import XMLCore

/// Parses an XML byte span and builds an in-memory ``Document``.
///
/// `DOMParser` is a namespace for the static ``parse(bytes:)`` entry point.
/// It has no instance state; all parsing is done in a single call.
///
/// ```swift
/// let document = try DOMParser.parse(bytes: source)
/// let root = document.view(of: document.root)
/// ```
public struct DOMParser {
  private init() {}

  /// Parses `bytes` and returns a fully-built ``Document``.
  ///
  /// All content is written into the document's flat storage buffer during
  /// the parse; no per-node heap allocation occurs. Content that appears
  /// verbatim in the source and content that required transformation (e.g.
  /// entity-expanded attribute values) are stored in the same buffer —
  /// callers see a uniform `Span<XML.Byte>` API regardless.
  ///
  /// - Throws: ``XML/Error`` if the bytes are not well-formed XML 1.0.
  public static func parse(bytes: borrowing Span<XML.Byte>) throws -> Document {
    var parser = SAXParser(handler: Builder(reserving: bytes.count))
    try parser.parse(bytes: bytes)
    let builder = parser.handler
    return Document(storage: builder.storage,
                    nodes: builder.nodes,
                    attributes: builder.attributes,
                    ids: builder.ids)
  }
}

// MARK: - Builder
//
// Builder is a plain Copyable + Escapable struct so it can conform to
// Handler.  It accumulates the flat arrays that Document will own; the Document
// is assembled by DOMParser.parse after the SAXParser finishes.
//
// Failure == Never so the SAXParser uses its optimised (no error-boxing) path.

private struct Builder: Handler {
  fileprivate var location: XML.Location?

  fileprivate var storage: [XML.Byte] = []
  fileprivate var nodes: [Document.Node] = [Document.Node(kind: .document)]
  fileprivate var attributes: [Document.Attribute] = []
  fileprivate var ids: [String:Document.Reference] = [:]

  private var stack: [Int32] = []

  fileprivate init(reserving capacity: Int) {
    storage.reserveCapacity(capacity)
    nodes.reserveCapacity(max(8, capacity >> 5))
    attributes.reserveCapacity(capacity >> 4)
    ids.reserveCapacity(max(4, capacity >> 7))
    stack.reserveCapacity(max(32, capacity >> 4))
  }

  // MARK: - Handler

  fileprivate mutating func start(document _: Void) {
    push(0)  // the document root is always node 0
  }

  fileprivate mutating func end(document _: Void) {
    pop()
  }

  fileprivate mutating func start(element name: XML.QualifiedNameView,
                                  namespace uri: Span<XML.Byte>?,
                                  attributes: XML.ResolvedAttributes) {
    let index = append(element: name, namespace: uri, attributes: attributes)
    push(index)
  }

  fileprivate mutating func end(element _: XML.QualifiedNameView, namespace _: Span<XML.Byte>?) {
    pop()
  }

  fileprivate mutating func characters(_ data: Span<XML.Byte>) {
    append(data, kind: .text)
  }

  fileprivate mutating func character(data: Span<XML.Byte>) {
    append(data, kind: .cdata)
  }

  fileprivate mutating func comment(_ content: Span<XML.Byte>) {
    append(content, kind: .comment)
  }

  fileprivate mutating func processing(target: Span<XML.Byte>, data: Span<XML.Byte>?) {
    var node = Document.Node(kind: .processingInstruction)
    node.name = (store(target), FNV1a.hash32(target))
    if let data { node.value = store(data) }
    _ = append(node)
  }

  fileprivate mutating func start(dtd name: Span<XML.Byte>,
                                  id: (public: Span<XML.Byte>?, system: Span<XML.Byte>?)) {
    var node = Document.Node(kind: .dtd)
    node.name = (store(name), 0)
    if let pub = id.public { node.value = store(pub) }
    if let sys = id.system { node.extra = store(sys) }
    _ = append(node)
  }

  // MARK: - Helpers

  @inline(__always)
  private mutating func push(_ index: Int32) {
    stack.append(index)
  }

  @inline(__always)
  private mutating func pop() {
    stack.removeLast()
  }

  private mutating func append(_ node: consuming Document.Node) -> Int32 {
    if let location {
      node.location = (UInt32(location.line), UInt32(location.offset))
    }
    let index = Int32(nodes.count)
    nodes.append(node)
    if let parent = stack.last { link(child: index, to: parent) }
    return index
  }

  private mutating func append(_ value: borrowing Span<XML.Byte>, kind: Document.NodeKind) {
    _ = append(Document.Node(kind: kind, value: store(value)))
  }

  private mutating func append(element name: borrowing XML.QualifiedNameView,
                               namespace uri: Span<XML.Byte>?,
                               attributes: borrowing XML.ResolvedAttributes) -> Int32 {
    var node = Document.Node(kind: .element)
    node.name = (store(name.bytes), FNV1a.hash32(name.local))
    node.colon = name.colon.map(Int32.init) ?? -1
    let base = Int32(self.attributes.count)
    node.namespace = slice(uri)

    intern(attributes)
    node.attributes = (base: base, count: Int32(self.attributes.count) - base)
    let id = append(node)
    for index in attributes.indices {
      let name = attributes.name(at: index)
      if identifies(name) {
        let value = attributes.value(at: index)
        if !value.isEmpty { ids[String(value)] = Document.Reference(index: Int(id)) }
      }
    }
    return id
  }

  private mutating func intern(_ attributes: borrowing XML.ResolvedAttributes) {
    for index in attributes.indices {
      self.attributes.append(attribute(named: attributes.name(at: index),
                                       namespace: attributes.namespace(at: index),
                                       value: attributes.value(at: index)))
    }
  }

  private mutating func attribute(named name: borrowing XML.QualifiedNameView,
                                  namespace uri: Span<XML.Byte>?,
                                  value: borrowing Span<XML.Byte>) -> Document.Attribute {
    return Document.Attribute(name: (store(name.bytes), FNV1a.hash32(name.local)),
                              colon: name.colon.map(Int32.init) ?? -1,
                              namespace: slice(uri),
                              value: store(value))
  }

  @inline(__always)
  private func identifies(_ name: borrowing XML.QualifiedNameView) -> Bool {
    let prefix = name.prefix
    return name.local == StaticString("id")
      && (prefix == nil || prefix == StaticString("xml"))
  }

  @inline(__always)
  private mutating func slice(_ span: borrowing Span<XML.Byte>?) -> Document.Slice {
    let span = copy span
    if let span { return store(span) }
    return .absent
  }

  @inline(__always)
  private mutating func link(child: Int32, to parent: Int32) {
    nodes[Int(child)].parent = parent

    let index = Int(parent)
    if nodes[index].children.last < 0 {
      nodes[index].children.first = child
    } else {
      let last = Int(nodes[index].children.last)
      nodes[last].sibling.next = child
      nodes[Int(child)].sibling.previous = Int32(last)
    }
    nodes[index].children.last = child
  }

  // Appends `span` to the flat storage buffer and returns a `Slice`
  // pointing to it.
  @inline(__always)
  private mutating func store(_ span: borrowing Span<XML.Byte>) -> Document.Slice {
    let start = storage.count
    span.withUnsafeBufferPointer { storage.append(contentsOf: $0) }
    return Document.Slice(start: Int32(start), count: Int32(span.count))
  }
}

// MARK: - Node convenience init

extension Document.Node {
  fileprivate init(kind: Document.NodeKind, value: Document.Slice) {
    self.init(kind: kind)
    self.value = value
  }
}
