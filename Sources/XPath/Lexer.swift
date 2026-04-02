// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import XMLCore

extension XPath {
  internal struct Lexer {
    private let bytes: [XML.Byte]
    private var index: Int = 0

    internal init(_ expression: String) {
      self.bytes = Array(expression.utf8)
    }

    // Consume the next token, discarding it.
    @inline(__always)
    internal mutating func skip() throws(XPath.Error) { _ = try next() }

    // Return current token without advancing.
    internal mutating func peek() throws(XPath.Error) -> Token {
      let saved = index
      let token = try next()
      index = saved
      return token
    }

    // [28] ExprToken ::= '(' | ')' | '[' | ']' | '.' | '..' | '@' | ',' | '::'
    //                  | NameTest | NodeType | Operator | FunctionName
    //                  | AxisName | Literal | Number | VariableReference
    internal mutating func next() throws(XPath.Error) -> Token {
      spaces()
      guard index < bytes.count else { return .end }

      let byte = bytes[index]

      switch byte {
      case UInt8(ascii: "/"):
        advance()
        if index < bytes.count, bytes[index] == UInt8(ascii: "/") {
          advance()
          return .doubleSlash
        }
        return .slash

      case UInt8(ascii: "."):
        advance()
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
          advance()
          return .dotDot
        }
        // Could be the start of a decimal number: .5
        if index < bytes.count, bytes[index].isASCIIDigit {
          return try fraction(integer: 0)
        }
        return .dot

      case UInt8(ascii: "@"): advance(); return .at
      case UInt8(ascii: "*"): advance(); return .star
      case UInt8(ascii: "["): advance(); return .lbracket
      case UInt8(ascii: "]"): advance(); return .rbracket
      case UInt8(ascii: "("): advance(); return .lparen
      case UInt8(ascii: ")"): advance(); return .rparen
      case UInt8(ascii: ","): advance(); return .comma
      case UInt8(ascii: "|"): advance(); return .pipe
      case UInt8(ascii: "+"): advance(); return .plus
      case UInt8(ascii: "-"): advance(); return .minus
      case UInt8(ascii: "$"): advance(); return .dollar

      case UInt8(ascii: "="):
        advance()
        return .eq

      case UInt8(ascii: "!"):
        advance()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else {
          throw .invalidExpression("expected '=' after '!'")
        }
        advance()
        return .neq

      case UInt8(ascii: "<"):
        advance()
        if index < bytes.count, bytes[index] == UInt8(ascii: "=") { advance(); return .lte }
        return .lt

      case UInt8(ascii: ">"):
        advance()
        if index < bytes.count, bytes[index] == UInt8(ascii: "=") { advance(); return .gte }
        return .gt

      case UInt8(ascii: "\""), UInt8(ascii: "'"):
        return try quoted(quote: byte)

      case _ where byte.isASCIIDigit:
        return try number()

      case UInt8(ascii: ":"):
        advance()
        guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
          throw .invalidExpression("bare ':' is not valid; use '::'")
        }
        advance()
        return .doubleColon

      default:
        guard (byte.isXMLASCIINameStartChar && byte != UInt8(ascii: ":")) || byte > 0x7f else {
          throw .invalidExpression("unexpected character '\(UnicodeScalar(byte))'")
        }
        return try name()
      }
    }

    // MARK: - Helpers

    @inline(__always)
    private mutating func advance(_ distance: Int = 1) {
      index += distance
    }

    @inline(__always)
    // [39] ExprWhitespace ::= (#x20 | #x9 | #xD | #xA)+
    private mutating func spaces() {
      while index < bytes.count, bytes[index].isXMLASCIIWhitespace { advance() }
    }

    // [29] Literal ::= '"' [^"]* '"' | "'" [^']* "'"
    private mutating func quoted(quote: UInt8) throws(XPath.Error) -> Token {
      advance() // consume opening quote
      let start = index
      while index < bytes.count, bytes[index] != quote { advance() }
      guard index < bytes.count else { throw .invalidExpression("unterminated string literal") }
      let string = String(bytes.span.extracting(start ..< index))
      advance() // consume closing quote
      return .string(string)
    }

    // [30] Number ::= Digits ('.' Digits?)? | '.' Digits
    // [31] Digits ::= [0-9]+
    private mutating func number() throws(XPath.Error) -> Token {
      var value: Double = 0
      while index < bytes.count, bytes[index].isASCIIDigit {
        value = value * 10 + Double(bytes[index] - UInt8(ascii: "0"))
        advance()
      }
      if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        advance()
        return try fraction(integer: value)
      }
      return .number(value)
    }

    private mutating func fraction(integer: Double) throws(XPath.Error) -> Token {
      var frac: Double = 0
      var place: Double = 0.1
      while index < bytes.count, bytes[index].isASCIIDigit {
        frac += Double(bytes[index] - UInt8(ascii: "0")) * place
        place *= 0.1
        advance()
      }
      return .number(integer + frac)
    }

    private mutating func name() throws(XPath.Error) -> Token {
      let start = index
      advance()
      while index < bytes.count {
        let byte = bytes[index]
        if byte == UInt8(ascii: ":"),
           index + 1 < bytes.count,
           bytes[index + 1] == UInt8(ascii: ":") {
          break
        }
        if byte == UInt8(ascii: ":"),
           index + 1 < bytes.count,
           bytes[index + 1] == UInt8(ascii: "*") {
          advance(2)
          break
        }

        if byte < 0x80 {
          guard byte.isXMLASCIINameChar else { break }
          advance()
          continue
        }

        do throws(XML.Error) {
          try advance(XML.Name.scan(bytes.span.extracting(index...)).bytes)
        } catch {
          throw .invalidExpression("invalid XML name")
        }
        break
      }
      return .name(String(bytes.span.extracting(start ..< index)))
    }
  }
}
