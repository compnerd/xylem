// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import DOMParser
internal import XMLCore

extension XPath.Expression {
  // MARK: - Location path evaluation

  internal func evaluate(path: borrowing XPath.LocationPath,
                         in document: borrowing Document,
                         context: borrowing XPath.Context) throws(XPath.Error) -> [Document.Reference] {
    var current: [Document.Reference] = path.absolute ? [document.root] : [context.node]
    var next: [Document.Reference] = []
    var index = path.steps.startIndex
    while let step = step(in: path, at: &index) {
      next.removeAll(keepingCapacity: true)
      try visit(step: step, from: current, in: document, context: context) { next.append($0) }
      if next.count > 1, step.axis.reverse {
        next.sort { order($0, $1) }
      }
      swap(&current, &next)
    }
    return current
  }

  // MARK: - Count without materialising

  internal func count(_ expression: Node,
                      in document: borrowing Document,
                      context: borrowing XPath.Context) throws(XPath.Error) -> Int {
    guard case .path(let path) = expression else {
      return try evaluate(expression, in: document, context: context).nodes.count
    }
    return try count(path, in: document, context: context)
  }

  // Counts matching nodes without materialising the result array on the final
  // step. Single-step paths from a single origin use a counter closure with
  // zero heap activity; multi-step paths materialise intermediates as normal.
  private func count(_ path: borrowing XPath.LocationPath,
                     in document: borrowing Document,
                     context: borrowing XPath.Context) throws(XPath.Error) -> Int {
    let from: Document.Reference = path.absolute ? document.root : context.node
    var index = path.steps.startIndex
    guard let step = step(in: path, at: &index) else { return 0 }
    let remaining = path.steps[index...]

    if remaining.isEmpty {
      return try count(step, from: from, in: document, context: context)
    }

    var current: [Document.Reference] = [from]
    var trail = [step] + remaining
    let last = trail.removeLast()

    if !trail.isEmpty {
      let path = XPath.LocationPath(absolute: false, steps: trail)
      current = try evaluate(path: path, in: document, context: context)
    }

    if current.count == 1 {
      return try count(last, from: current[0], in: document, context: context)
    }

    var total = 0
    try visit(step: last, from: current, in: document, context: context) { _ in total += 1 }
    return total
  }

  private func count(_ step: borrowing XPath.Step, from node: Document.Reference,
                     in document: borrowing Document,
                     context: borrowing XPath.Context) throws(XPath.Error) -> Int {
    var total = 0
    try visit(step: step, from: node, in: document, context: context) { _ in total += 1 }
    return total
  }

  // MARK: - Lazy axis traversal

  @inline(__always)
  private func visit(axis: XPath.Axis,
                     test: borrowing XPath.NodeTest,
                     from node: Document.Reference,
                     in document: borrowing Document,
                     context: borrowing XPath.Context,
                     _ body: (Document.Reference) -> Void) {
    switch axis {
    case .child:
      guard node.attribute == nil else { return }
      if let hash = test.hash {
        var cursor = document.nodes[Int(node.index)].children.first
        while cursor >= 0 {
          let element = document.nodes[Int(cursor)]
          if element.kind == .element, element.name.hash == hash, element.namespace.absent {
            body(Document.Reference(index: Int(cursor)))
          }
          cursor = element.sibling.next
        }
      } else {
        var current = document.firstChild(of: node)
        while let child = current {
          if matches(test: test, node: child, in: document, context: context) { body(child) }
          current = document.nextSibling(of: child)
        }
      }

    case .descendant:
      descend(from: node, in: document, test: test, context: context, body)

    case .descendantOrSelf:
      if matches(test: test, node: node, in: document, context: context) { body(node) }
      descend(from: node, in: document, test: test, context: context, body)

    case .`self`:
      if matches(test: test, node: node, in: document, context: context) { body(node) }

    case .parent:
      if let parent = document.parent(of: node),
         matches(test: test, node: parent, in: document, context: context) {
        body(parent)
      }

    case .ancestor, .ancestorOrSelf:
      var current: Document.Reference? = axis == .ancestorOrSelf ? node : document.parent(of: node)
      while let ancestor = current {
        if matches(test: test, node: ancestor, in: document, context: context) { body(ancestor) }
        current = document.parent(of: ancestor)
      }

    case .attribute:
      var current = document.firstAttribute(of: node)
      while let attribute = current {
        if matches(test: test, node: attribute, in: document, context: context) { body(attribute) }
        current = document.nextAttribute(after: attribute)
      }

    case .followingSibling:
      var current = document.nextSibling(of: node)
      while let sibling = current {
        if matches(test: test, node: sibling, in: document, context: context) { body(sibling) }
        current = document.nextSibling(of: sibling)
      }

    case .precedingSibling:
      var current = document.previousSibling(of: node)
      while let sibling = current {
        if matches(test: test, node: sibling, in: document, context: context) { body(sibling) }
        current = document.previousSibling(of: sibling)
      }

    case .following:
      var cursor: Document.Reference? = node
      while let current = cursor {
        var sibling = document.nextSibling(of: current)
        while let node = sibling {
          if matches(test: test, node: node, in: document, context: context) { body(node) }
          descend(from: node, in: document, test: test, context: context, body)
          sibling = document.nextSibling(of: node)
        }
        cursor = document.parent(of: current)
      }

    case .preceding:
      precede(node, test: test, in: document, context: context, body)

    case .namespace:
      break // Namespace nodes cannot be implemented here: DOMParser discards namespace-binding
            // scopes (start/endMapping callbacks are stubs). Requires DOMParser changes.
    }
  }

  // Stackless pre-order DFS using parent links to backtrack (no stack allocation).
  // Fast path for `.name(nil, _, hash)`: checks kind+hash from the arena node
  // before constructing a Reference, skipping matches() dispatch for non-elements.
  @inline(__always)
  private func descend(from root: Document.Reference,
                       in document: borrowing Document,
                       test: borrowing XPath.NodeTest,
                       context: borrowing XPath.Context,
                       _ body: (Document.Reference) -> Void) {
    guard root.attribute == nil else { return }
    let index = Int32(root.index)
    var cursor = document.nodes[Int(root.index)].children.first
    guard cursor >= 0 else { return }

    if let hash = test.hash {
      outer: while true {
        let node = document.nodes[Int(cursor)]
        if node.kind == .element, node.name.hash == hash, node.namespace.absent {
          body(Document.Reference(index: Int(cursor)))
        }
        let child = node.children.first
        if child >= 0 { cursor = child; continue }
        var current = node
        while true {
          let sibling = current.sibling.next
          if sibling >= 0 { cursor = sibling; break }
          let parent = current.parent
          if parent < 0 || parent == index { break outer }
          cursor = parent
          current = document.nodes[Int(cursor)]
        }
      }
    } else {
      outer: while true {
        let ref = Document.Reference(index: Int(cursor))
        if matches(test: test, node: ref, in: document, context: context) { body(ref) }
        let node = document.nodes[Int(cursor)]
        let child = node.children.first
        if child >= 0 { cursor = child; continue }
        var current = node
        while true {
          let sibling = current.sibling.next
          if sibling >= 0 { cursor = sibling; break }
          let parent = current.parent
          if parent < 0 || parent == index { break outer }
          cursor = parent
          current = document.nodes[Int(cursor)]
        }
      }
    }
  }

  private func precede(_ node: Document.Reference, test: borrowing XPath.NodeTest,
                       in document: borrowing Document,
                       context: borrowing XPath.Context,
                       _ body: (Document.Reference) -> Void) {
    var cursor = node
    while let parent = document.parent(of: cursor) {
      var sibling = document.previousSibling(of: cursor)
      while let node = sibling {
        reverse(from: node, test: test, in: document, context: context, body)
        sibling = document.previousSibling(of: node)
      }
      cursor = parent
    }
  }

  @inline(__always)
  private func tail(of root: Document.Reference,
                    in document: borrowing Document) -> Document.Reference {
    var current = root
    while let child = document.lastChild(of: current) {
      current = child
    }
    return current
  }

  private func reverse(from root: Document.Reference,
                       test: borrowing XPath.NodeTest,
                       in document: borrowing Document,
                       context: borrowing XPath.Context,
                       _ body: (Document.Reference) -> Void) {
    var current: Document.Reference? = tail(of: root, in: document)
    while let node = current {
      if matches(test: test, node: node, in: document, context: context) { body(node) }
      if node == root { return }
      if let sibling = document.previousSibling(of: node) {
        current = tail(of: sibling, in: document)
      } else {
        current = document.parent(of: node)
      }
    }
  }

  // MARK: - Materialised matching (for steps with predicates)

  private func gather(axis: XPath.Axis, test: borrowing XPath.NodeTest, from node: Document.Reference,
                      in document: borrowing Document,
                      context: borrowing XPath.Context) -> [Document.Reference] {
    var result: [Document.Reference] = []
    visit(axis: axis, test: test, from: node, in: document, context: context) { result.append($0) }
    return result
  }

  // MARK: - Step application

  // Fuses descendant-or-self::node()/child::X into descendant::X to avoid
  // intermediate node-set materialisation.
  private func step(in path: borrowing XPath.LocationPath,
                    at index: inout Array<XPath.Step>.Index) -> XPath.Step? {
    guard index < path.steps.endIndex else { return nil }
    var step = path.steps[index]
    index = path.steps.index(after: index)
    if case .node = step.test,
       step.axis == .descendantOrSelf, step.predicates.isEmpty,
       index < path.steps.endIndex,
       path.steps[index].axis == .child {
      step = XPath.Step(axis: .descendant,
                        test: path.steps[index].test,
                        predicates: path.steps[index].predicates)
      index = path.steps.index(after: index)
    }
    return step
  }

  private func visit(step: borrowing XPath.Step,
                     from nodes: [Document.Reference],
                     in document: borrowing Document,
                     context: borrowing XPath.Context,
                     _ body: (Document.Reference) -> Void) throws(XPath.Error) {
    if nodes.count == 1 {
      try visit(step: step, from: nodes[0], in: document, context: context, body)
      return
    }

    // Disjoint axes (child, attribute, self) never produce overlapping results
    // from distinct origin nodes — skip the deduplication set entirely.
    if step.axis.disjoint {
      for node in nodes {
        try visit(step: step, from: node, in: document, context: context, body)
      }
      return
    }

    var seen: Set<Document.Reference> = []
    seen.reserveCapacity(nodes.count)
    for node in nodes {
      try visit(step: step, from: node, in: document, context: context) {
        if seen.insert($0).inserted { body($0) }
      }
    }
  }

  private func visit(step: borrowing XPath.Step,
                     from node: Document.Reference,
                     in document: borrowing Document,
                     context: borrowing XPath.Context,
                     _ body: (Document.Reference) -> Void) throws(XPath.Error) {
    if step.predicates.isEmpty {
      visit(axis: step.axis, test: step.test, from: node, in: document, context: context, body)
    } else if !step.positional {
      try visit(matching: step, from: node, in: document, context: context, body)
    } else {
      let candidates = gather(axis: step.axis, test: step.test, from: node, in: document,
                              context: context)
      let filtered = try apply(predicates: step.predicates, to: candidates,
                               in: document, context: context)
      filtered.forEach(body)
    }
  }

  private func visit(matching step: borrowing XPath.Step,
                     from node: Document.Reference,
                     in document: borrowing Document,
                     context: borrowing XPath.Context,
                     _ body: (Document.Reference) -> Void) throws(XPath.Error) {
    var deferred: XPath.Error?
    visit(axis: step.axis, test: step.test, from: node, in: document, context: context) { node in
      guard deferred == nil else { return }
      do throws(XPath.Error) {
        if try accepts(step.predicates, on: node, in: document, context: context) { body(node) }
      } catch {
        deferred = error
      }
    }
    if let deferred { throw deferred }
  }

  // MARK: - Node test matching

  private func matches(test: borrowing XPath.NodeTest,
                       node: Document.Reference,
                       in document: borrowing Document,
                       context: borrowing XPath.Context) -> Bool {
    switch test {
    case .node:    return true
    case .text:
      return document.kind(of: node).textual
    case .comment: return document.kind(of: node) == .comment

    case .any(namespace: nil):
      let kind = document.kind(of: node)
      return kind == .element || kind == .attribute

    case .processing(target: let target):
      let view = document.view(of: node)
      guard view.kind == .processingInstruction else { return false }
      guard let target else { return true }
      guard let name = view.name else { return false }
      return name.local == target

    case .any(namespace: let prefix?):
      let view = document.view(of: node)
      guard view.kind == .element || view.kind == .attribute,
            view.name != nil,
            let binding = self.namespaces[prefix],
            let namespace = view.namespace else {
        return false
      }
      return namespace == binding

    case .name(let prefix, let local, let hash):
      let required: String?
      if let prefix {
        guard let binding = self.namespaces[prefix] else { return false }
        required = binding
      } else {
        required = nil
      }
      if node.attribute == nil {
        return document.matches(element: hash, local: local, namespace: required, of: node)
      }
      return document.matches(attribute: hash, local: local, namespace: required, of: node)
    }
  }

  // MARK: - Predicate application

  // Only valid for non-positional predicates (no position()/last()/numeric literals).
  private func accepts(_ predicates: [Node],
                       on node: Document.Reference,
                       in document: borrowing Document,
                       context inherited: borrowing XPath.Context) throws(XPath.Error) -> Bool {
    var context: XPath.Context? = nil
    for predicate in predicates {
      // Fast path: a single-step relative path with no sub-predicates is evaluated
      // directly via visit(), skipping the intermediate array allocations that
      // evaluate(path:) would incur.  Covers the common [@attr] and [child] patterns.
      if case .path(let path) = predicate,
         !path.absolute, path.steps.count == 1, path.steps[0].predicates.isEmpty {
        var found = false
        let step = path.steps[0]
        visit(axis: step.axis, test: step.test, from: node, in: document, context: inherited) { _ in
          found = true
        }
        if !found { return false }
      } else {
        if context == nil {
          context = XPath.Context(node: node, sharing: inherited._vars)
        }
        if try !evaluate(predicate, in: document, context: context!).boolean { return false }
      }
    }
    return true
  }

  internal func apply(predicates: [Node],
                      to candidates: [Document.Reference],
                      in document: borrowing Document,
                      context inherited: borrowing XPath.Context) throws(XPath.Error) -> [Document.Reference] {
    var current = candidates
    for predicate in predicates {
      if current.isEmpty { return [] }
      let size = current.count
      var next: [Document.Reference] = []
      next.reserveCapacity(size)
      for (index, node) in current.enumerated() {
        let context = XPath.Context(node: node, position: index + 1, size: size, sharing: inherited._vars)
        let value = try evaluate(predicate, in: document, context: context)
        let keep = switch value {
        case .number(let number): number == Double(index + 1)
        default: value.boolean
        }
        if keep { next.append(node) }
      }
      current = next
    }
    return current
  }

  private func order(_ lhs: Document.Reference, _ rhs: Document.Reference) -> Bool {
    switch (lhs.attribute, rhs.attribute) {
    case let (.some(lhs), .some(rhs)):
      if lhs.element != rhs.element { return lhs.element < rhs.element }
      return lhs.position < rhs.position
    case let (.some(lhs), .none):
      return lhs.element <= Int(rhs.index)
    case let (.none, .some(rhs)):
      return Int(lhs.index) < rhs.element
    case (.none, .none):
      return lhs.index < rhs.index
    }
  }
}
