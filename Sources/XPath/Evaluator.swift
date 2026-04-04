// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import DOMParser
internal import XMLCore

extension XPath.Expression {
  internal func evaluate(_ expression: Node,
                         in document: borrowing Document,
                         context: borrowing XPath.Context) throws(XPath.Error) -> XPath.Value {
    switch expression {
    case let .string(string): return .string(string)
    case let .number(number): return .number(number)
    case let .bool(boolean): return .bool(boolean)
    case let .variable(name):
      guard let value = variable(named: name, context: context) else {
        throw .typeError("unbound variable '\(name)'")
      }
      return value

    case let .path(path):
      return try .set(evaluate(path: path, in: document, context: context))

    case let .compose(primary, path):
      let bases = try evaluate(primary, in: document, context: context).nodes
      guard !bases.isEmpty else { return .set([]) }
      // Common case: single base node — no deduplication set needed.
      if bases.count == 1 {
        let scoped = XPath.Context(node: bases[0], sharing: context._vars)
        return try .set(evaluate(path: path, in: document, context: scoped))
      }
      var result: [Document.Reference] = []
      var seen: Set<Document.Reference> = []
      result.reserveCapacity(bases.count)
      seen.reserveCapacity(bases.count)
      for node in bases {
        let scoped = XPath.Context(node: node, sharing: context._vars)
        for match in try evaluate(path: path, in: document, context: scoped)
          where seen.insert(match).inserted {
          result.append(match)
        }
      }
      return .set(result)

    case let .filter(primary, predicates):
      let base = try evaluate(primary, in: document, context: context)
      guard case let .set(candidates) = base else { return base }
      return try .set(apply(predicates: predicates, to: candidates, in: document, context: context))

    case let .union(lhs, rhs):
      let left  = try evaluate(lhs, in: document, context: context).nodes
      let right = try evaluate(rhs, in: document, context: context).nodes
      return .set(left.union(with: right))

    case let .negate(operand):
      return try .number(-(evaluate(operand, in: document, context: context).numeric))

    case let .binary(operation, lhs, rhs):
      return try evaluate(binary: operation, lhs, rhs, in: document, context: context)

    case let .function(name, arguments):
      return try evaluate(function: name, arguments: arguments, in: document, context: context)
    }
  }

  // MARK: - Binary operators

  private func evaluate(binary operation: XPath.BinaryOperation, _ lhs: Node, _ rhs: Node,
                        in document: borrowing Document,
                        context: borrowing XPath.Context) throws(XPath.Error) -> XPath.Value {
    switch operation {
    case .and:
      if try !evaluate(lhs, in: document, context: context).boolean { return .bool(false) }
      return try .bool(evaluate(rhs, in: document, context: context).boolean)

    case .or:
      if try evaluate(lhs, in: document, context: context).boolean { return .bool(true) }
      return try .bool(evaluate(rhs, in: document, context: context).boolean)

    case .eq, .neq:
      // Fast path: @attr = 'literal' — scan attribute list and compare bytes directly,
      // avoiding path evaluation array allocations and String construction.
      if case let .path(path) = lhs,
         !path.absolute, path.steps.count == 1,
         path.steps[0].axis == .attribute, path.steps[0].predicates.isEmpty,
         let hash = path.steps[0].test.hash,
         case let .string(literal) = rhs {
        let matched = document.attribute(of: context.node, hash: hash,
                                         equals: literal)
        return .bool(operation == .eq ? matched : !matched)
      }
      let lhs = try evaluate(lhs, in: document, context: context)
      let rhs = try evaluate(rhs, in: document, context: context)
      return .bool(compare(operation, lhs, rhs, in: document))

    case .lt, .lte, .gt, .gte:
      // Fast path: number(singleChildStep) OP numericLiteral — find first matching
      // child directly from the arena, skipping path evaluation array allocations.
      if case let .function("number", arguments) = lhs, arguments.count == 1,
         case let .path(path) = arguments[0],
         !path.absolute, path.steps.count == 1,
         path.steps[0].axis == .child, path.steps[0].predicates.isEmpty,
         context.node.attribute == nil,
         let hash = path.steps[0].test.hash,
         case let .number(threshold) = rhs {
        var value = Double.nan
        var cursor = document.nodes[Int(context.node.index)].children.first
        while cursor >= 0 {
          let node = document.nodes[Int(cursor)]
          if node.kind == .element, node.name.hash == hash, node.namespace.absent {
            value = document.number(of: Document.Reference(index: Int(cursor)))
            break
          }
          cursor = node.sibling.next
        }
        let lhs: XPath.Value = .number(value)
        let rhs: XPath.Value = .number(threshold)
        return .bool(compare(operation, lhs, rhs, in: document))
      }
      let lhs = try evaluate(lhs, in: document, context: context)
      let rhs = try evaluate(rhs, in: document, context: context)
      return .bool(compare(operation, lhs, rhs, in: document))

    case .add, .subtract, .multiply, .divide, .mod:
      let lhs = number(of: try evaluate(lhs, in: document, context: context), in: document)
      let rhs = number(of: try evaluate(rhs, in: document, context: context), in: document)
      return switch operation {
      case .add: .number(lhs + rhs)
      case .subtract: .number(lhs - rhs)
      case .multiply: .number(lhs * rhs)
      case .divide: .number(lhs / rhs)
      case .mod: .number(lhs.truncatingRemainder(dividingBy: rhs))
      default: fatalError("unreachable")
      }
    }
  }

  private func compare(_ operation: XPath.BinaryOperation, _ lhs: XPath.Value, _ rhs: XPath.Value,
                       in document: borrowing Document) -> Bool {
    if case let .set(nodes) = lhs {
      return compare(nodes, operation, rhs, in: document, nodeSetOnLeft: true)
    }
    if case let .set(nodes) = rhs {
      return compare(nodes, operation, lhs, in: document, nodeSetOnLeft: false)
    }
    return compareScalars(operation, lhs, rhs, in: document)
  }

  @inline(__always)
  internal func string(_ expression: Node,
                       in document: borrowing Document,
                       context: borrowing XPath.Context) throws(XPath.Error) -> String {
    try evaluate(expression, in: document, context: context).string(in: document)
  }

  @inline(__always)
  private func number(of value: XPath.Value, in document: borrowing Document) -> Double {
    value.number(in: document)
  }

  private func compare(_ nodes: [Document.Reference],
                       _ operation: XPath.BinaryOperation,
                       _ other: XPath.Value,
                       in document: borrowing Document,
                       nodeSetOnLeft: Bool) -> Bool {
    switch (operation, other) {
    case (.eq, .bool(let rhs)), (.neq, .bool(let rhs)):
      return compare(operation, !nodes.isEmpty, rhs)

    case (.eq, .number(let rhs)), (.neq, .number(let rhs)):
      for node in nodes {
        if compare(operation, document.number(of: node), rhs) {
          return true
        }
      }
      return false

    case (.eq, .string(let rhs)), (.neq, .string(let rhs)):
      for node in nodes {
        if compare(operation, document.string(of: node), rhs) {
          return true
        }
      }
      return false

    case (.eq, .set(let rhs)), (.neq, .set(let rhs)):
      for lhs in nodes {
        let left = document.string(of: lhs)
        for rhs in rhs {
          if compare(operation, left, document.string(of: rhs)) { return true }
        }
      }
      return false

    case (.lt, .set(let rhs)), (.lte, .set(let rhs)), (.gt, .set(let rhs)), (.gte, .set(let rhs)):
      for lhs in nodes {
        let left = document.number(of: lhs)
        for rhs in rhs {
          if compare(operation, left, document.number(of: rhs)) { return true }
        }
      }
      return false

    default:
      let other = number(of: other, in: document)
      for node in nodes {
        let value = document.number(of: node)
        if compare(operation, nodeSetOnLeft ? value : other, nodeSetOnLeft ? other : value) {
          return true
        }
      }
      return false
    }
  }

  @inline(__always)
  private func compare(_ operation: XPath.BinaryOperation, _ lhs: Bool, _ rhs: Bool) -> Bool {
    switch operation {
    case .eq: lhs == rhs
    case .neq: lhs != rhs
    default: fatalError("non-equality operator in boolean compare")
    }
  }

  @inline(__always)
  private func compare(_ operation: XPath.BinaryOperation, _ lhs: String, _ rhs: String) -> Bool {
    switch operation {
    case .eq: lhs == rhs
    case .neq: lhs != rhs
    default: fatalError("non-equality operator in string compare")
    }
  }

  @inline(__always)
  private func compare(_ operation: XPath.BinaryOperation, _ lhs: Double, _ rhs: Double) -> Bool {
    switch operation {
    case .eq: lhs == rhs
    case .neq: lhs != rhs
    case .lt: lhs < rhs
    case .lte: lhs <= rhs
    case .gt: lhs > rhs
    case .gte: lhs >= rhs
    default: fatalError("non-comparison operator in numeric compare")
    }
  }

  private func compareScalars(_ operation: XPath.BinaryOperation,
                              _ lhs: XPath.Value,
                              _ rhs: XPath.Value,
                              in document: borrowing Document) -> Bool {
    switch operation {
    case .eq, .neq:
      switch (lhs, rhs) {
      case (.bool, _), (_, .bool):
        return compare(operation, lhs.boolean, rhs.boolean)
      case (.number, _), (_, .number):
        return compare(operation, number(of: lhs, in: document), number(of: rhs, in: document))
      default:
        return compare(operation, lhs.string(in: document), rhs.string(in: document))
      }

    case .lt, .lte, .gt, .gte:
      return compare(operation, number(of: lhs, in: document), number(of: rhs, in: document))

    default:
      fatalError("non-comparison operator in compareScalars()")
    }
  }

  private func variable(named raw: borrowing String,
                        context: borrowing XPath.Context) -> XPath.Value? {
    guard let expanded = XML.ExpandedName(expanding: raw, using: namespaces) else { return nil }
    return context.variables[expanded]
  }
}
