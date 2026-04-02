// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

extension XPath {
  internal struct Parser {
    private var lexer: Lexer

    internal init(_ expression: String) {
      self.lexer = Lexer(expression)
    }

    internal mutating func done() throws(XPath.Error) -> Bool {
      try lexer.peek() == .end
    }

    // MARK: - Entry point

    // [14] Expr ::= OrExpr
    internal mutating func expression() throws(XPath.Error) -> Expression.Node {
      try or()
    }

    // MARK: - Boolean operators

    // [21] OrExpr ::= AndExpr | OrExpr 'or' AndExpr
    private mutating func or() throws(XPath.Error) -> Expression.Node {
      var lhs = try and()
      while case .name("or") = try lexer.peek() {
        try lexer.skip()
        lhs = try .binary(.or, lhs, and())
      }
      return lhs
    }

    // [22] AndExpr ::= EqualityExpr | AndExpr 'and' EqualityExpr
    private mutating func and() throws(XPath.Error) -> Expression.Node {
      var lhs = try equality()
      while case .name("and") = try lexer.peek() {
        try lexer.skip()
        lhs = try .binary(.and, lhs, equality())
      }
      return lhs
    }

    // [23] EqualityExpr ::= RelationalExpr | EqualityExpr '=' RelationalExpr | EqualityExpr '!=' RelationalExpr
    private mutating func equality() throws(XPath.Error) -> Expression.Node {
      var lhs = try relational()
      while true {
        let op: BinaryOperation
        switch try lexer.peek() {
        case .eq:  op = .eq
        case .neq: op = .neq
        default:   return lhs
        }
        try lexer.skip()
        lhs = try .binary(op, lhs, relational())
      }
    }

    // [24] RelationalExpr ::= AdditiveExpr | RelationalExpr ('<' | '>' | '<=' | '>=') AdditiveExpr
    private mutating func relational() throws(XPath.Error) -> Expression.Node {
      var lhs = try additive()
      while true {
        let op: BinaryOperation
        switch try lexer.peek() {
        case .lt:  op = .lt
        case .lte: op = .lte
        case .gt:  op = .gt
        case .gte: op = .gte
        default:   return lhs
        }
        try lexer.skip()
        lhs = try .binary(op, lhs, additive())
      }
    }

    // [25] AdditiveExpr ::= MultiplicativeExpr | AdditiveExpr '+' MultiplicativeExpr | AdditiveExpr '-' MultiplicativeExpr
    private mutating func additive() throws(XPath.Error) -> Expression.Node {
      var lhs = try multiplicative()
      while true {
        let op: BinaryOperation
        switch try lexer.peek() {
        case .plus:  op = .add
        case .minus: op = .subtract
        default:     return lhs
        }
        try lexer.skip()
        lhs = try .binary(op, lhs, multiplicative())
      }
    }

    // [26] MultiplicativeExpr ::= UnaryExpr | MultiplicativeExpr ('*' | 'div' | 'mod') UnaryExpr
    private mutating func multiplicative() throws(XPath.Error) -> Expression.Node {
      var lhs = try unary()
      while true {
        let op: BinaryOperation
        switch try lexer.peek() {
        case .star:         op = .multiply
        case .name("div"):  op = .divide
        case .name("mod"):  op = .mod
        default:            return lhs
        }
        try lexer.skip()
        lhs = try .binary(op, lhs, unary())
      }
    }

    // [27] UnaryExpr ::= UnionExpr | '-' UnaryExpr
    private mutating func unary() throws(XPath.Error) -> Expression.Node {
      if case .minus = try lexer.peek() {
        try lexer.skip()
        let operand = try unary()
        return .negate(operand)
      }
      return try union()
    }

    // [18] UnionExpr ::= PathExpr | UnionExpr '|' PathExpr
    private mutating func union() throws(XPath.Error) -> Expression.Node {
      var lhs = try path()
      while case .pipe = try lexer.peek() {
        try lexer.skip()
        lhs = try .union(lhs, path())
      }
      return lhs
    }

    // MARK: - Path expressions

    // [19] PathExpr ::= LocationPath | FilterExpr | FilterExpr '/' RelativeLocationPath | FilterExpr '//' RelativeLocationPath
    private mutating func path() throws(XPath.Error) -> Expression.Node {
      let token = try lexer.peek()

      switch token {
      case .slash, .doubleSlash:
        let path = try path(.absolute)
        return .path(path)
      case .name:
        if try lookahead() == .lparen, !token.isNodeType {
          let filter = try filter()
          return try compose(filter)
        }
        let path = try path(.relative)
        return .path(path)
      case .dot, .dotDot, .at, .star:
        let path = try path(.relative)
        return .path(path)
      default:
        let filter = try filter()
        return try compose(filter)
      }
    }

    private mutating func compose(_ primary: Expression.Node) throws(XPath.Error) -> Expression.Node {
      switch try lexer.peek() {
      case .slash, .doubleSlash:
        .compose(primary, try relativePath())
      default:
        primary
      }
    }

    // [20] FilterExpr ::= PrimaryExpr | FilterExpr Predicate
    private mutating func filter() throws(XPath.Error) -> Expression.Node {
      let primary = try primary()
      let preds = try predicates()
      guard !preds.isEmpty else { return primary }
      return .filter(primary, preds)
    }

    // [15] PrimaryExpr ::= VariableReference | '(' Expr ')' | Literal | Number | FunctionCall
    private mutating func primary() throws(XPath.Error) -> Expression.Node {
      switch try lexer.peek() {
      case .dollar:
        try lexer.skip()
        guard case let .name(name) = try lexer.next() else {
          throw .invalidExpression("expected variable name after '$'")
        }
        return .variable(name)

      case .lparen:
        try lexer.skip()
        let inner = try expression()
        guard case .rparen = try lexer.next() else {
          throw .invalidExpression("expected ')' to close grouped expression")
        }
        return inner

      case .string(let string):
        try lexer.skip()
        return .string(string)

      case .number(let number):
        try lexer.skip()
        return .number(number)

      case .name(let name):
        try lexer.skip()
        guard case .lparen = try lexer.next() else {
          throw .invalidExpression("expected '(' after function name '\(name)'")
        }
        return try call(name: name)

      default:
        throw .invalidExpression("unexpected token in primary expression")
      }
    }

    // [16] FunctionCall ::= FunctionName '(' ( Argument ( ',' Argument )* )? ')'
    // [17] Argument     ::= Expr
    private mutating func call(name: String) throws(XPath.Error) -> Expression.Node {
      var args: [Expression.Node] = []
      if try lexer.peek() != .rparen {
        try args.append(expression())
        while case .comma = try lexer.peek() {
          try lexer.skip()
          try args.append(expression())
        }
      }
      guard case .rparen = try lexer.next() else {
        throw .invalidExpression("expected ')' after function arguments")
      }
      return .function(name, args)
    }

    // MARK: - Location paths

    // [1]  LocationPath         ::= RelativeLocationPath | AbsoluteLocationPath
    // [2]  AbsoluteLocationPath ::= '/' RelativeLocationPath? | AbbreviatedAbsoluteLocationPath
    // [3]  RelativeLocationPath ::= Step | RelativeLocationPath '/' Step | AbbreviatedRelativeLocationPath
    // [10] AbbreviatedAbsoluteLocationPath ::= '//' RelativeLocationPath
    // [11] AbbreviatedRelativeLocationPath ::= RelativeLocationPath '//' Step
    private enum PathKind { case absolute, relative }

    private mutating func path(_ kind: PathKind) throws(XPath.Error) -> LocationPath {
      var steps: [Step] = []

      switch kind {
      case .absolute:
        let tok  = try lexer.next() // consume / or //
        let next = try lexer.peek()
        guard tok == .doubleSlash || !next.terminator else { break }
        try append(to: &steps, after: tok)
      case .relative:
        try steps.append(step())
      }

      try append(path: &steps)

      return LocationPath(absolute: kind == .absolute, steps: steps)
    }

    private mutating func relativePath() throws(XPath.Error) -> LocationPath {
      var steps: [Step] = []

      try append(to: &steps, after: lexer.next())
      try append(path: &steps)

      return LocationPath(absolute: false, steps: steps)
    }

    private mutating func append(to steps: inout [Step],
                                 after token: Token) throws(XPath.Error) {
      if token == .doubleSlash {
        try steps.fuse(step())
      } else {
        try steps.append(step())
      }
    }

    private mutating func append(path steps: inout [Step]) throws(XPath.Error) {
      var token = try lexer.peek()
      while token == .slash || token == .doubleSlash {
        try lexer.skip()
        try append(to: &steps, after: token)
        token = try lexer.peek()
      }
    }

    // [4]  Step                  ::= AxisSpecifier NodeTest Predicate* | AbbreviatedStep
    // [5]  AxisSpecifier         ::= AxisName '::' | AbbreviatedAxisSpecifier
    // [12] AbbreviatedStep       ::= '.' | '..'
    // [13] AbbreviatedAxisSpecifier ::= '@'?
    private mutating func step() throws(XPath.Error) -> Step {
      switch try lexer.peek() {
      case .dot:
        try lexer.skip()
        return Step(axis: .`self`, test: .node, predicates: [])

      case .dotDot:
        try lexer.skip()
        return Step(axis: .parent, test: .node, predicates: [])

      case .at:
        try lexer.skip()
        return try step(axis: .attribute)

      case .name(let n):
        if let axis = Axis(name: n), try lookahead() == .doubleColon {
          try lexer.skip() // axis name
          try lexer.skip() // ::
          return try step(axis: axis)
        }

      default: break
      }
      return try step(axis: .child)
    }

    private mutating func step(axis: Axis) throws(XPath.Error) -> Step {
      let test  = try test()
      let preds = try predicates()
      return Step(axis: axis, test: test, predicates: preds)
    }

    // MARK: - Node tests

    // [7]  NodeTest ::= NameTest | NodeType '(' ')' | 'processing-instruction' '(' Literal ')'
    // [37] NameTest ::= '*' | NCName ':' '*' | QName
    // [38] NodeType ::= 'comment' | 'text' | 'processing-instruction' | 'node'
    private mutating func test() throws(XPath.Error) -> NodeTest {
      switch try lexer.peek() {
      case .star:
        try lexer.skip()
        return .any()

      case .name(let name):
        try lexer.skip()
        if case .lparen = try lexer.peek() {
          try lexer.skip()
          let result: NodeTest
          switch name {
          case "text":                   result = .text
          case "comment":                result = .comment
          case "node":                   result = .node
          case "processing-instruction":
            if case .string(let target) = try lexer.peek() {
              try lexer.skip()
              result = .processing(target: target)
            } else {
              result = .processing()
            }
          default:
            throw .invalidExpression("unknown node-type function '\(name)()'")
          }
          guard case .rparen = try lexer.next() else {
            throw .invalidExpression("expected ')' after node-type test")
          }
          return result
        }
        return NodeTest(name: name)

      default:
        throw .invalidExpression("expected node test")
      }
    }

    // MARK: - Predicates

    // [8] Predicate     ::= '[' PredicateExpr ']'
    // [9] PredicateExpr ::= Expr
    private mutating func predicates() throws(XPath.Error) -> [Expression.Node] {
      var result: [Expression.Node] = []
      while case .lbracket = try lexer.peek() {
        try result.append(predicate())
      }
      return result
    }

    private mutating func predicate() throws(XPath.Error) -> Expression.Node {
      guard case .lbracket = try lexer.next() else {
        throw .invalidExpression("expected '['")
      }
      let expr = try expression()
      guard case .rbracket = try lexer.next() else {
        throw .invalidExpression("expected ']'")
      }
      return expr
    }

    // MARK: - Utilities

    private mutating func lookahead() throws(XPath.Error) -> Token {
      let saved = lexer
      try lexer.skip()
      let result = try lexer.peek()
      lexer = saved
      return result
    }
  }
}
