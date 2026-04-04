// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import XMLCore
internal import DOMParser

extension Document {
  @inline(__always)
  private func entry(_ node: Reference) -> Node? {
    guard node.attribute == nil else { return nil }
    return nodes[Int(node.index)]
  }

  @inline(__always)
  private func qualified(_ node: Reference) -> (spelling: Slice, colon: Int32)? {
    if let attribute = attribute(of: node) {
      return (attribute.name.spelling, attribute.colon)
    }

    guard let node = entry(node) else { return nil }
    guard node.name.spelling.present else { return nil }
    return (node.name.spelling, node.colon)
  }

  @inline(__always)
  internal func matches(element hash: UInt32, local localName: String,
                        namespace required: String?,
                        of node: Reference) -> Bool {
    guard let node = entry(node) else { return false }
    guard node.kind == .element, node.name.spelling.present, node.name.hash == hash else { return false }
    guard local(node.name.spelling, colon: node.colon) == localName else { return false }
    guard let required else { return node.namespace.absent }
    guard node.namespace.present else { return false }
    return span(node.namespace) == required
  }

  @inline(__always)
  internal func attribute(of node: Reference, hash: UInt32,
                          equals value: String) -> Bool {
    guard let node = entry(node) else { return false }
    guard node.attributes.base >= 0 else { return false }
    let base = Int(node.attributes.base)
    let count = Int(node.attributes.count)
    for index in 0 ..< count {
      let attribute = attributes[base + index]
      guard attribute.name.hash == hash, attribute.namespace.absent else { continue }
      if span(attribute.value) == value { return true }
    }
    return false
  }

  @inline(__always)
  internal func matches(attribute hash: UInt32, local localName: String,
                        namespace required: String?,
                        of node: Reference) -> Bool {
    guard let attribute = attribute(of: node) else { return false }
    guard attribute.name.hash == hash else { return false }
    guard local(attribute.name.spelling, colon: attribute.colon) == localName else { return false }
    guard let required else { return attribute.namespace.absent }
    guard attribute.namespace.present else { return false }
    return span(attribute.namespace) == required
  }

  internal func name(of node: Reference, type: NameType) -> String? {
    guard let qualified = qualified(node) else { return nil }
    return name(qualified.spelling, colon: qualified.colon, type: type)
  }

  @_lifetime(borrow self)
  internal func namespace(of node: Reference) -> Span<XML.Byte>? {
    if let attribute = attribute(of: node) {
      guard attribute.namespace.present else { return nil }
      return span(attribute.namespace)
    }

    guard let node = entry(node) else { return nil }
    guard node.namespace.present else { return nil }
    return span(node.namespace)
  }

  private func name(_ slice: Slice, colon: Int32, type: NameType) -> String {
    let name = span(slice)
    switch type {
    case .qualified:
      return String(name)
    case .local:
      return String(local(slice, colon: colon))
    }
  }

  @inline(__always)
  @_lifetime(borrow self)
  private func local(_ slice: Slice, colon: Int32) -> Span<XML.Byte> {
    let name = span(slice)
    if colon >= 0 { return name.extracting((Int(colon) + 1)...) }
    return name
  }
}
