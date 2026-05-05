// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

public import XMLCore

// MARK: - NodeView

/// A scoped, non-copyable cursor onto a single node in a `Document`.
///
/// `NodeView` borrows the owning `Document` — it cannot outlive it.  All
/// properties and navigation steps return values whose lifetimes are bounded
/// by the same document, enforced statically by the compiler.
///
/// Obtain a `NodeView` from a `Document` via ``Document/view(of:)``.  The
/// copyable ``Document/Reference`` is still available for stable handles
/// that need to be stored in collections or compared across traversals.
///
/// ```swift
/// var node = document.view(of: document.root).firstChild
/// while let n = node {
///     if n.kind == .element { print(n.name?.local ?? "-") }
///     node = n.nextSibling
/// }
/// ```
public struct NodeView: ~Copyable, ~Escapable {
  // Three spans borrowed from the Document's internal arenas.  Copying them
  // into the view (via @_lifetime(copy …)) lets navigation produce new
  // NodeViews without re-borrowing the Document at each step.
  private let storage: Span<XML.Byte>
  private let nodes: Span<Document.Node>
  private let attributes: Span<Document.Attribute>

  /// The stable index handle for the node this view refers to.
  public let reference: Document.Reference

  @available(*, deprecated, renamed: "reference")
  public var ref: Document.Reference { reference }

  @inline(__always)
  private var attribute: (element: Int, position: Int)? {
    reference.attribute
  }

  @inline(__always)
  private var record: Document.Attribute? {
    guard let attribute else { return nil }
    let base = Int(nodes[attribute.element].attributes.base)
    return attributes[base + attribute.position]
  }

  @inline(__always)
  private var node: Document.Node {
    nodes[Int(reference.index)]
  }

  @inline(__always)
  @_lifetime(borrow self)
  private func qualified(_ slice: Document.Slice, colon: Int32) -> XML.QualifiedNameView? {
    guard slice.present else { return nil }
    return XML.QualifiedNameView(unvalidated: storage,
                                  range: SourceRange(slice.range),
                                  colon: colon >= 0 ? Int(colon) : nil)
  }

  @inline(__always)
  @_lifetime(borrow self)
  private func span(_ slice: Document.Slice) -> Span<XML.Byte>? {
    guard slice.present else { return nil }
    return storage.extracting(slice.range)
  }

  @inline(__always)
  @_lifetime(copy self)
  private func view(_ index: Int32) -> NodeView? {
    guard let reference = Document.Reference(index) else { return nil }
    return NodeView(reference, from: self)
  }

  // MARK: - Init from Document

  @_lifetime(borrow document)
  internal init(_ reference: Document.Reference, in document: borrowing Document) {
    self.reference = reference
    self.storage = document.storage.span
    self.nodes = document.nodes.span
    self.attributes = document.attributes.span
  }

  // Navigation init: produces a sibling/child/parent view sharing the same
  // document lifetime.  `copy` requires a local `let` binding — it cannot be
  // applied directly to a property access on a borrowing parameter.
  @_lifetime(copy source)
  private init(_ reference: Document.Reference, from source: borrowing NodeView) {
    let s = source.storage
    let n = source.nodes
    let a = source.attributes
    self.reference = reference
    self.storage = copy s
    self.nodes = copy n
    self.attributes = copy a
  }

  // MARK: - Node properties

  /// The structural kind of the node this view refers to.
  public var kind: Document.NodeKind {
    attribute == nil ? node.kind : .attribute
  }

  /// The source location where this node was parsed, or `nil` for attribute
  /// nodes or if location tracking was not available.
  public var location: XML.Location? {
    guard attribute == nil else { return nil }
    let location = node.location
    guard location.line > 0 else { return nil }
    return XML.Location(line: Int(location.line), offset: Int(location.offset))
  }

  /// The qualified name for element, PI, attribute, and DOCTYPE nodes; `nil`
  /// for text, comment, CDATA, and document nodes.
  public var name: XML.QualifiedNameView? {
    @_lifetime(borrow self) get {
      if let record { return qualified(record.name.spelling, colon: record.colon) }
      return qualified(node.name.spelling, colon: node.colon)
    }
  }

  /// Text content for text, comment, and CDATA nodes; PI data for processing
  /// instructions; the DOCTYPE public identifier; the attribute value for
  /// attribute nodes; `nil` for element and document nodes.
  public var value: Span<XML.Byte>? {
    @_lifetime(borrow self) get {
      if let record { return span(record.value) }
      return span(node.value)
    }
  }

  /// The namespace URI for element or attribute nodes; `nil` if unqualified
  /// or for all other node kinds.
  public var namespace: Span<XML.Byte>? {
    @_lifetime(borrow self) get {
      if let record { return span(record.namespace) }
      return span(node.namespace)
    }
  }

  /// The DOCTYPE system identifier; `nil` for all other node kinds.
  public var systemID: Span<XML.Byte>? {
    @_lifetime(borrow self) get {
      if attribute == nil { return span(node.extra) }
      return nil
    }
  }

  // MARK: - Attributes

  /// The number of attributes on this node; always 0 for non-element nodes.
  public var attributeCount: Int {
    attribute == nil ? Int(node.attributes.count) : 0
  }

  /// Returns a view onto the attribute at `index` (0-based).
  /// - Precondition: `index < attributeCount`
  @_lifetime(copy self)
  public func attribute(at index: Int) -> AttributeView {
    let base = Int(node.attributes.base)
    return AttributeView(attributes[base + index], storage: storage)
  }

  // MARK: - Tree navigation

  /// A view onto the parent node, or `nil` for the document root.
  public var parent: NodeView? {
    @_lifetime(copy self) get {
      if let attribute {
        return NodeView(Document.Reference(index: attribute.element), from: self)
      }
      guard let parent = Document.Reference(node.parent) else { return nil }
      return NodeView(parent, from: self)
    }
  }

  /// A view onto the first child node, or `nil` if the node has no children.
  public var firstChild: NodeView? {
    @_lifetime(copy self) get {
      if attribute == nil { return view(node.children.first) }
      return nil
    }
  }

  /// A view onto the last child node, or `nil` if the node has no children.
  public var lastChild: NodeView? {
    @_lifetime(copy self) get {
      if attribute == nil { return view(node.children.last) }
      return nil
    }
  }

  /// A view onto the next sibling in document order, or `nil` if this is the
  /// last child of its parent.
  public var nextSibling: NodeView? {
    @_lifetime(copy self) get {
      if attribute == nil { return view(node.sibling.next) }
      return nil
    }
  }

  /// A view onto the previous sibling in document order, or `nil` if this is
  /// the first child of its parent.
  public var previousSibling: NodeView? {
    @_lifetime(copy self) get {
      if attribute == nil { return view(node.sibling.previous) }
      return nil
    }
  }
}
