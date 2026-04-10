// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

/// Namespace for XPath 1.0 types, errors, and expression evaluation.
public enum XPath {
  /// A byte offset within a source string.
  public struct Location: Equatable, Sendable {
    /// The zero-based byte offset.
    public let offset: Int

    public init(offset: Int) {
      self.offset = offset
    }
  }

  /// Errors thrown during XPath expression parsing or evaluation.
  public enum Error: Swift.Error {
    /// The expression string is not valid XPath 1.0 syntax.
    case invalidExpression(String, at: Location? = nil)
    /// A function was called with the wrong number of arguments or with
    /// arguments of an incompatible type.
    case typeError(String)
    /// The expression references a function name that is not defined.
    case unknownFunction(String)
  }
}
