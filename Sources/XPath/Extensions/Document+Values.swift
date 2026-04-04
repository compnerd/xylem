// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import XMLCore
internal import DOMParser

extension Document {
  // XPath string-value of a node per XPath 1.0 section 5.
  internal func string(of handle: Reference) -> String {
    if let attribute = attribute(of: handle) {
      return string(attribute.value)
    }

    let node = nodes[Int(handle.index)]
    switch node.kind {
    case .element, .document:
      guard let first = reference(node.children.first) else { return "" }
      // Fast path: single text or cdata child; return directly from storage.
      if node.children.first == node.children.last {
        let child = nodes[Int(first.index)]
        if child.kind.textual,
           child.value.present {
          return string(child.value)
        }
      }
      var current = first
      var utf8: [XML.Byte] = []
      utf8.reserveCapacity(64)
      outer: while true {
        let node = nodes[Int(current.index)]
        if node.kind.textual,
           node.value.present {
          span(node.value).withUnsafeBufferPointer { utf8.append(contentsOf: $0) }
        }
        if let child = reference(node.children.first) {
          current = child
          continue
        }
        while true {
          let node = nodes[Int(current.index)]
          if let sibling = reference(node.sibling.next) { current = sibling; break }
          guard let parent = reference(node.parent), parent != handle else { break outer }
          current = parent
        }
      }
      return String(utf8.span)
    default:
      guard node.value.present else { return "" }
      return string(node.value)
    }
  }

  @inline(__always)
  internal func number(of handle: Reference) -> Double {
    if let attribute = attribute(of: handle) {
      guard attribute.value.present else { return .nan }
      return number(attribute.value)
    }

    let node = nodes[Int(handle.index)]
    switch node.kind {
    case .element, .document:
      return Double(string(of: handle).trimmed()) ?? .nan
    default:
      guard node.value.present else { return .nan }
      return number(node.value)
    }
  }
}
