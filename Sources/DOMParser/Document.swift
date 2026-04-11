// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

package import XMLCore

/// A self-contained DOM tree produced by `DOMParser`.
///
/// All content bytes are stored in a single flat `storage` array — one
/// contiguous allocation for the entire document.  Nodes are stored in a
/// parallel flat arena; there are no per-node heap allocations.
///
/// Use ``Reference`` as a stable, copyable handle — suitable for
/// collections, sets, and long-lived bookmarks.  Use ``view(of:)`` to obtain
/// a ``NodeView`` cursor for efficient, property-style content access.
public struct Document: ~Copyable, ~Escapable {
  @inline(__always)
  private func node(_ reference: Reference) -> Node {
    nodes[Int(reference.index)]
  }

  // MARK: - Public types

  /// The structural kind of a node in the document tree.
  public enum NodeKind: UInt8 {
    /// The invisible root that contains the document element and its siblings.
    case document
    /// An element node: `<tag …>`.
    case element
    /// A run of character data between markup.
    case text
    /// A comment: `<!-- … -->`.
    case comment
    /// A CDATA section: `<![CDATA[ … ]]>`.
    case cdata
    /// A processing instruction: `<?target data?>`.
    case processingInstruction
    /// A document type declaration: `<!DOCTYPE …>`.
    case dtd
    /// An attribute of an element node.
    case attribute
  }

  /// A lightweight, copyable handle to a node or attribute.  Valid only for
  /// the `Document` instance that produced it; stable for the document's
  /// lifetime.
  ///
  /// Regular nodes store the node index directly in `index`.
  /// Attribute references set bit 63 as a tag, with bits 62–16 holding the
  /// element index and bits 15–0 holding the attribute position:
  /// `index = TagBit | (element << 16) | position`
  public struct Reference: Equatable, Hashable {
    private static let TagBit: UInt64 = 1 << 63
    private static let Shift: UInt64 = 16
    private static let Mask: UInt64 = (1 << Shift) - 1  // 0xffff

    package let index: UInt64

    package init(index: Int) { self.index = UInt64(index) }

    internal init?(_ index: Int32) {
      guard index >= 0 else { return nil }
      self.index = UInt64(index)
    }

    internal init(element: Int, position: Int) {
      assert(position >= 0 && UInt64(position) <= Self.Mask)
      index = Self.TagBit | (UInt64(element) << Self.Shift) | UInt64(position)
    }

    package var attribute: (element: Int, position: Int)? {
      guard index & Self.TagBit != 0 else { return nil }
      let bits = index & ~Self.TagBit
      return (element: Int(bits >> Self.Shift), position: Int(bits & Self.Mask))
    }
  }

  // MARK: - Entry point

  /// A reference to the document node — the invisible root of the tree.
  public var root: Reference { Reference(index: 0) }

  // MARK: - Node queries

  /// Returns the structural kind of `node`.
  public func kind(of node: Reference) -> NodeKind {
    node.attribute == nil ? self.node(node).kind : .attribute
  }

  // MARK: - Tree navigation (returns stable Reference handles)

  /// Returns the parent of `node`, or `nil` for the document root.
  public func parent(of node: Reference) -> Reference? {
    if let attribute = node.attribute { return Reference(index: attribute.element) }
    return Reference(self.node(node).parent)
  }

  /// Returns the first child of `node`, or `nil` if the node has no children.
  public func firstChild(of node: Reference) -> Reference? {
    guard node.attribute == nil else { return nil }
    return Reference(self.node(node).children.first)
  }

  /// Returns the last child of `node`, or `nil` if the node has no children.
  public func lastChild(of node: Reference) -> Reference? {
    guard node.attribute == nil else { return nil }
    return Reference(self.node(node).children.last)
  }

  /// Returns the next sibling of `node` in document order, or `nil` if `node`
  /// is the last child of its parent.
  ///
  /// Always returns `nil` for attribute references.
  public func nextSibling(of node: Reference) -> Reference? {
    guard node.attribute == nil else { return nil }
    return Reference(self.node(node).sibling.next)
  }

  /// Returns the previous sibling of `node` in document order, or `nil` if
  /// `node` is the first child of its parent.
  ///
  /// Always returns `nil` for attribute references.
  public func previousSibling(of node: Reference) -> Reference? {
    guard node.attribute == nil else { return nil }
    return Reference(self.node(node).sibling.previous)
  }

  // MARK: - Attribute navigation

  /// Returns a reference to the first attribute of `node`, or `nil` if the
  /// node has no attributes or is itself an attribute reference.
  public func firstAttribute(of node: Reference) -> Reference? {
    guard node.attribute == nil else { return nil }
    guard self.node(node).attributes.count > 0 else { return nil }
    return Reference(element: Int(node.index), position: 0)
  }

  /// Returns a reference to the attribute that follows `node` in attribute
  /// order, or `nil` if `node` is the last attribute.
  public func nextAttribute(after node: Reference) -> Reference? {
    guard let (element, position) = node.attribute else { return nil }
    let next = position + 1
    guard next < Int(nodes[element].attributes.count) else { return nil }
    return Reference(element: element, position: next)
  }

  // MARK: - Cursor

  /// Returns a ``NodeView`` cursor onto `node`, borrowing this document.
  ///
  /// The cursor gives property-style access to the node's name, value,
  /// namespace, attributes, and child/sibling navigation.  It cannot outlive
  /// the `Document`; use ``Reference`` when you need a stable handle.
  @_lifetime(borrow self)
  public borrowing func view(of node: Reference) -> NodeView {
    NodeView(node, in: self)
  }

  // MARK: - Internal storage

  package var storage: [XML.Byte]  // flat byte store for all content
  package var nodes: [Node]
  package var attributes: [Attribute]
  // Element lookup by ID attribute value.
  // Populated at parse time from unqualified `id` and `xml:id` attributes.
  package var ids: [String: Reference]

  @_lifetime(immortal)
  internal init(storage: consuming [XML.Byte], nodes: consuming [Node],
                attributes: consuming [Attribute], ids: consuming [String: Reference] = [:]) {
    self.storage = consume storage
    self.nodes = consume nodes
    self.attributes = consume attributes
    self.ids = consume ids
  }
}
