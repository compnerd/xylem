// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

// MARK: - XML.Lexer

extension XML {
  package struct Lexer: ~Copyable, ~Escapable {
    package let bytes: Span<Byte>
    private var tracker = LocationTracker()
    private var cursor: Span<Byte>.Index
    private var attributes: [XML.UnresolvedAttributes.Record] = []

    package var location: XML.Location {
      @inline(__always) get { tracker.location(at: cursor) }
    }

    @_lifetime(borrow input)
    package init(bytes input: Span<Byte>, cursor: Span<Byte>.Index = 0) {
      self.bytes = input
      self.cursor = cursor
    }

    @_lifetime(self: copy self)
    @_lifetime(&self)
    package mutating func next() throws(XML.Error) -> Token? {
      try next()?.value
    }

    // [1]  document ::= prolog element Misc*
    // [43] content  ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
    // Returns the next token by dispatching on '<' (markup) vs character data.
    @_lifetime(self: copy self)
    @_lifetime(&self)
    package mutating func next() throws(XML.Error) -> Located<XML.Token>? {
      guard cursor < bytes.count else { return nil }
      if bytes[cursor] == UInt8(ascii: "<") {
        return try markup()
      }
      return try text()
    }
  }
}

// MARK: - Lexer Cursor

extension XML.Lexer {
  // Advance by one byte, tracking newlines for location.
  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func step() {
    switch bytes[cursor] {
    case UInt8(ascii: "\r"):
      tracker.newline(at: cursor)
    case UInt8(ascii: "\n"):
      if cursor >= 1 && bytes[cursor - 1] != UInt8(ascii: "\r") {
        tracker.newline(at: cursor)
      }
    default:
      break
    }
    cursor += 1
  }

  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func advance() throws(XML.Error) {
    guard cursor < bytes.count else { throw .unexpectedEOF }
    guard bytes[cursor] < 0x80 else {
      guard let decoded = try bytes.decodeScalar(at: cursor) else { throw .unexpectedEOF }
      cursor += decoded.stride
      return
    }
    step()
  }

  @_lifetime(self: copy self)
  private mutating func advance(to target: Span<XML.Byte>.Index) {
    while cursor < target {
      // Bulk-skip non-newline bytes — only call step() on CR/LF.
      var position = cursor
      while position < target
          && bytes[position] != UInt8(ascii: "\r")
          && bytes[position] != UInt8(ascii: "\n") {
        position += 1
      }
      cursor = position
      if cursor < target { step() }
    }
  }
}

// MARK: - Lexer Scanners

extension XML.Lexer {
  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func consume(_ byte: XML.Byte) throws(XML.Error) {
    guard cursor < bytes.count else { throw .unexpectedEOF }
    guard bytes[cursor] == byte else { throw .invalidCharacter }
    step()
  }

  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func consume(_ string: StaticString) throws(XML.Error) {
    precondition(string.hasPointerRepresentation)
    try string.withUTF8Buffer({ buffer -> Result<Void, XML.Error> in
      guard cursor + buffer.count <= bytes.count else { return .failure(.unexpectedEOF) }
      for index in 0 ..< buffer.count {
        guard bytes[cursor + index] == buffer[index] else { return .failure(.invalidCharacter) }
      }
      cursor += buffer.count
      return .success(())
    }).get()
  }

  // Scalar fast-path: advance past a run of character data stopping at `stop`,
  // `<`, `&`, or any byte outside printable ASCII.  Called from attribute() with
  // the quote character; attribute values are typically short (1–16 bytes) so
  // SIMD/SWAR setup would cost more than the scan itself.
  // (b &- 0x20) > 0x5f catches b < 0x20 (wraps high) and b > 0x7f (overflow).
  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func run(stop: XML.Byte) {
    while cursor < bytes.count {
      let byte = bytes[cursor]
      let sentinel = byte == stop || byte == UInt8(ascii: "<") || byte == UInt8(ascii: "&")
      let control = (byte &- 0x20) > 0x5f
      if sentinel || control { break }
      cursor += 1
    }
  }

  // Bulk scanner for text nodes: SIMD16 → SWAR → scalar.
  //   1. SIMD16 (ldr q / movdqu): 16 bytes per iteration via NEON/SSE2.
  //   2. SWAR: 8 bytes per iteration for the 8–15 byte remainder.
  //   3. Scalar tail for the final < 8 bytes or after any early break.
  // Stop byte is `]` (0x5d); the compiler constant-folds the SIMD splat and
  // the SWAR broadcast.  A local `offset` var is used inside the SIMD closure
  // so it does not capture `self` mutably, avoiding an exclusivity conflict
  // with the shared borrow on `self.bytes`.
  //
  // hasByte(w, c) = ((w ^ broadcast(c)) &- ones) & ~(w ^ broadcast(c))
  //   High bit set in each lane where w[lane] == c.  False positives are safe —
  //   the scalar tail corrects them.  False negatives would be bugs.
  @_lifetime(self: copy self)
  private mutating func run() {
    let ones:  UInt64 = 0x0101_0101_0101_0101  // unit in each byte lane
    let highs: UInt64 = 0x8080_8080_8080_8080  // MSB in each byte lane

    let vStop  = SIMD16<UInt8>(repeating: UInt8(ascii: "]"))  // 0x5d
    let vLT    = SIMD16<UInt8>(repeating: UInt8(ascii: "<"))  // 0x3c
    let vAmp   = SIMD16<UInt8>(repeating: UInt8(ascii: "&"))  // 0x26
    let vShift = SIMD16<UInt8>(repeating: 0x20)
    let vLimit = SIMD16<UInt8>(repeating: 0x5f)

    var offset = cursor
    bytes.withUnsafeBufferPointer { buffer in
      guard let base = UnsafeRawPointer(buffer.baseAddress) else { return }

      // SIMD: 16 bytes per iteration using unaligned loads.
      while buffer.count - offset >= 16 {
        let chunk = base.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
        let sentinels = (chunk .== vStop) .| (chunk .== vLT) .| (chunk .== vAmp)
        let reject = (chunk &- vShift) .> vLimit
        if any(sentinels .| reject) { break }
        offset += 16
      }

      // SWAR: 8 bytes per iteration using a single unaligned load.
      while buffer.count - offset >= 8 {
        let word = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        let xStop: UInt64 = word ^ 0x5d5d_5d5d_5d5d_5d5d  // ']' = 0x5d
        let xLT:   UInt64 = word ^ 0x3c3c_3c3c_3c3c_3c3c  // '<' = 0x3c
        let xAmp:  UInt64 = word ^ 0x2626_2626_2626_2626  // '&' = 0x26
        let sentinels: UInt64 = ((xStop &- ones) & ~xStop)
                              | ((xLT   &- ones) & ~xLT  )
                              | ((xAmp  &- ones) & ~xAmp )
        // High bits mark bytes outside printable ASCII (either control or non-ASCII).
        let reject: UInt64 = word | ((word &- 0x2020_2020_2020_2020) & ~word)
        guard (sentinels | reject) & highs == 0 else { break }
        offset += 8
      }
    }
    cursor = offset
    // Scalar tail.
    while cursor < bytes.count {
      let byte = bytes[cursor]
      let sentinel = byte == UInt8(ascii: "]")
                  || byte == UInt8(ascii: "<")
                  || byte == UInt8(ascii: "&")
      let control = (byte &- 0x20) > 0x5f
      if sentinel || control { break }
      cursor += 1
    }
  }

  // [3] S ::= (#x20 | #x9 | #xD | #xA)+
  @discardableResult
  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func spaces() -> Bool {
    let start = cursor
    while cursor < bytes.count, bytes[cursor] < 0x80, bytes[cursor].isXMLASCIIWhitespace {
      switch bytes[cursor] {
      case UInt8(ascii: "\r"), UInt8(ascii: "\n"):
        step()
      default:
        cursor += 1
      }
    }
    return cursor > start
  }

  // [5] Name ::= NameStartChar (NameChar)*
  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func name() throws(XML.Error) -> Range<Span<XML.Byte>.Index> {
    guard cursor < bytes.count else { throw .invalidName }

    let start = cursor
    cursor += try XML.Name.scan(bytes.extracting(start...)).bytes
    return start ..< cursor
  }

  @inline(__always)
  private func matches(_ terminator: StaticString) -> Bool {
    bytes.matches(terminator, at: cursor)
  }

  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func consume(until terminator: StaticString) throws(XML.Error) -> Range<Span<XML.Byte>.Index> {
    guard terminator.utf8CodeUnitCount > 0 else { return cursor ..< cursor }
    let byte = terminator.withUTF8Buffer { $0[0] }

    let start = cursor
    while true {
      guard let index = bytes.extracting(cursor...).first(byte) else {
        advance(to: bytes.count)
        throw .unexpectedEOF
      }
      advance(to: cursor + index)
      if matches(terminator) { return start ..< cursor }
      step()
    }
  }

  // [11] SystemLiteral ::= ('"' [^"]* '"') | ("'" [^']* "'")
  // [12] PubidLiteral  ::= '"' PubidChar* '"' | "'" (PubidChar - "'")* "'"
  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func quoted() throws(XML.Error) -> Range<Span<XML.Byte>.Index> {
    guard cursor < bytes.count else { throw .unexpectedEOF }
    let quote = bytes[cursor]
    guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { throw .invalidCharacter }
    step()
    let range = try consume(until: quote == UInt8(ascii: "\"") ? "\"" : "'")
    step()
    return range
  }

  @inline(__always)
  private func source(from start: Int) -> SourceRange {
    SourceRange(start ..< cursor)
  }
}

// MARK: - Lexer DTD Helpers

extension XML.Lexer {
  @_lifetime(self: copy self)
  private mutating func skip(comment terminator: StaticString) throws(XML.Error) {
    _ = try consume(until: terminator)
    try consume(terminator)
  }

  // [75] ExternalID ::= 'SYSTEM' S SystemLiteral | 'PUBLIC' S PubidLiteral S SystemLiteral
  @_lifetime(self: copy self)
  private mutating func externalID() throws(XML.Error) -> (public: Range<Span<XML.Byte>.Index>?, system: Range<Span<XML.Byte>.Index>?)? {
    var `public`: Range<Span<XML.Byte>.Index>?

    if matches("PUBLIC") {
      try consume("PUBLIC")
      guard spaces() else { throw .invalidCharacter }
      `public` = try quoted()
    } else if matches("SYSTEM") {
      try consume("SYSTEM")
    } else {
      return nil
    }

    guard spaces() else { throw .invalidCharacter }

    let system = try quoted()
    spaces()
    return (`public`, system)
  }

  // [28b] intSubset   ::= (markupdecl | DeclSep)*
  // [29]  markupdecl  ::= elementdecl | AttlistDecl | EntityDecl | NotationDecl | PI | Comment
  // [28a] DeclSep     ::= PEReference | S
  // Skips balanced internal subset content without full grammar validation.
  @_lifetime(self: copy self)
  private mutating func subset() throws(XML.Error) {
    try advance()
    while cursor < bytes.count {
      switch bytes[cursor] {
      case UInt8(ascii: "<") where bytes.matches("<!--", at: cursor):
        try consume("<!--")
        try skip(comment: "-->")
      case UInt8(ascii: "<") where bytes.matches("<?", at: cursor):
        try consume("<?")
        try skip(comment: "?>")
      case UInt8(ascii: "["):
        try subset()
      case UInt8(ascii: "]"):
        try advance()
        return
      case UInt8(ascii: "\""), UInt8(ascii: "'"):
        _ = try quoted()
      default:
        try advance()
      }
    }
    throw .unexpectedEOF
  }
}

// MARK: - Lexer Tokens

extension XML.Lexer {
  @inline(__always)
  @_lifetime(borrow self)
  private func token(start markup: Int,
                     name: SourceRange,
                     attributes range: SourceRange,
                     namespaced: Bool,
                     closed: Bool) -> Located<XML.Token> {
    Located(value: .start(name: bytes.extracting(name),
                          attributes: XML.UnresolvedAttributes(source: bytes,
                                                               range: range,
                                                               records: self.attributes,
                                                               namespaced: namespaced),
                          closed: closed),
            source: source(from: markup))
  }

  // [16] PI       ::= '<?' PITarget (S (Char* - (Char* '?>' Char*)))? '?>'
  // [17] PITarget ::= Name - (('X' | 'x') ('M' | 'm') ('L' | 'l'))
  @_lifetime(self: copy self)
  @_lifetime(&self)
  private mutating func processing() throws(XML.Error) -> Located<XML.Token>? {
    let start = cursor
    try consume("<?")
    let target = try bytes.extracting(name())
    let data = if spaces() {
      try bytes.extracting(consume(until: "?>"))
    } else {
      nil as Span<XML.Byte>?
    }
    try consume("?>")

    return Located(value: .processing(target: target, data: data),
                   source: source(from: start))
  }

  // [15] Comment ::= '<!--' ((Char - '-') | ('-' (Char - '-')))* '-->'
  @_lifetime(self: copy self)
  @_lifetime(&self)
  private mutating func comment() throws(XML.Error) -> Located<XML.Token>? {
    let markup = cursor
    try consume("<!--")
    let comment = cursor
    while cursor < bytes.count {
      guard let offset = bytes.extracting(cursor...).first(UInt8(ascii: "-")) else {
        throw .unexpectedEOF
      }
      let dash = cursor + offset
      guard dash + 2 < bytes.count else { throw .unexpectedEOF }
      guard bytes[dash + 1] == UInt8(ascii: "-") else {
        advance(to: dash + 1)
        continue
      }
      guard bytes[dash + 2] == UInt8(ascii: ">") else { throw .invalidCharacter }
      let content = bytes.extracting(comment ..< dash)
      advance(to: dash)
      cursor += 3
      return Located(value: .comment(content),
                     source: source(from: markup))
    }
    throw .unexpectedEOF
  }

  // [18] CDSect  ::= CDStart CData CDEnd
  // [19] CDStart ::= '<![CDATA['
  // [20] CData   ::= (Char* - (Char* ']]>' Char*))
  // [21] CDEnd   ::= ']]>'
  @_lifetime(self: copy self)
  @_lifetime(&self)
  private mutating func cdata() throws(XML.Error) -> Located<XML.Token>? {
    let start = cursor
    try consume("<![CDATA[")
    let data = cursor
    while cursor < bytes.count {
      guard let offset = bytes.extracting(cursor...).first(UInt8(ascii: "]")) else {
        throw .unexpectedEOF
      }
      let bracket = cursor + offset
      guard bracket + 2 < bytes.count else { throw .unexpectedEOF }
      guard bytes[bracket + 1] == UInt8(ascii: "]"),
            bytes[bracket + 2] == UInt8(ascii: ">") else {
        advance(to: bracket + 1)
        continue
      }
      let content = bytes.extracting(data ..< bracket)
      advance(to: bracket)
      cursor += 3
      return Located(value: .cdata(content),
                     source: source(from: start))
    }
    throw .unexpectedEOF
  }

  // [28]  doctypedecl ::= '<!DOCTYPE' S Name (S ExternalID)? S? ('[' intSubset ']' S?)? '>'
  // [75]  ExternalID  ::= 'SYSTEM' S SystemLiteral | 'PUBLIC' S PubidLiteral S SystemLiteral
  // [28b] intSubset   ::= (markupdecl | DeclSep)*
  @_lifetime(self: copy self)
  @_lifetime(&self)
  private mutating func doctype() throws(XML.Error) -> Located<XML.Token>? {
    let start = cursor
    try consume("<!DOCTYPE")
    guard spaces() else { throw .invalidCharacter }
    let name = try bytes.extracting(name())
    spaces()
    let ids = try externalID() ?? (nil, nil)

    guard cursor < bytes.count else { throw .unexpectedEOF }
    if bytes[cursor] == UInt8(ascii: "[") {
      try subset()
      spaces()
    }

    try consume(UInt8(ascii: ">"))
    let `public`: Span<XML.Byte>? = if let range = ids.public { bytes.extracting(range) } else { nil }
    let system: Span<XML.Byte>? = if let range = ids.system { bytes.extracting(range) } else { nil }
    return Located(value: .doctype(name: name, public: `public`, system: system),
                   source: source(from: start))
  }

  // [42] ETag ::= '</' Name S? '>'
  @_lifetime(self: copy self)
  @_lifetime(&self)
  private mutating func end() throws(XML.Error) -> Located<XML.Token>? {
    let start = cursor
    try consume("</")
    let name = try bytes.extracting(name())
    spaces()
    try consume(UInt8(ascii: ">"))
    return Located(value: .end(name: name), source: source(from: start))
  }

  // [41] Attribute ::= Name Eq AttValue
  // [25] Eq        ::= S? '=' S?
  // [10] AttValue  ::= '"' ([^<&"] | Reference)* '"' | "'" ([^<&'] | Reference)* "'"
  @_lifetime(self: copy self)
  private mutating func attribute(at start: Int, namespaced: inout Bool) throws(XML.Error)
      -> XML.UnresolvedAttributes.Record {
    let attribute = try name()
    let name = bytes.extracting(attribute)
    let colon = name.first(UInt8(ascii: ":"))
    let declaration: Bool
    let prefix: SourceRange?
    if name == StaticString("xmlns") {
      namespaced = true
      (declaration, prefix) = (true, nil)
    } else if let colon, name.extracting(0 ..< colon) == StaticString("xmlns") {
      declaration = true
      namespaced = true
      prefix = SourceRange(attribute.lowerBound + colon + 1 - start ..< attribute.upperBound - start)
    } else {
      (declaration, prefix) = (false, nil)
      namespaced = namespaced || colon != nil
    }

    spaces()
    guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "=") else { throw .invalidCharacter }
    step()
    spaces()

    guard cursor < bytes.count else { throw .unexpectedEOF }
    let quote = bytes[cursor]
    guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { throw .invalidCharacter }
    step()

    let valueStart = cursor
    var processed = true
    while true {
      run(stop: quote)
      guard cursor < bytes.count else { throw .unexpectedEOF }
      let byte = bytes[cursor]
      if byte == quote { break }
      switch byte {
      case UInt8(ascii: "<"):
        throw .invalidCharacter
      case UInt8(ascii: "&"), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
        processed = false
        step()
      case _ where byte > 0x7f:
        guard let decoded = try bytes.decodeScalar(at: cursor),
              decoded.scalar.isXMLChar else { throw .invalidCharacter }
        cursor += decoded.stride
      default:
        throw .invalidCharacter
      }
    }
    let valueEnd = cursor

    step()
    return XML.UnresolvedAttributes.Record(name: SourceRange(attribute.lowerBound - start ..< attribute.upperBound - start),
                                           colon: colon,
                                           value: SourceRange(valueStart - start ..< valueEnd - start),
                                           processed: processed,
                                           declaration: declaration,
                                           prefix: prefix)
  }

  // [40] STag         ::= '<' Name (S Attribute)* S? '>'
  // [44] EmptyElemTag ::= '<' Name (S Attribute)* S? '/>'
  @_lifetime(self: copy self)
  @_lifetime(&self)
  private mutating func start() throws(XML.Error) -> Located<XML.Token>? {
    let start = cursor
    try consume(UInt8(ascii: "<"))
    let name = try SourceRange(name())
    spaces()
    let attributes = cursor

    if !self.attributes.isEmpty {
      self.attributes.removeAll(keepingCapacity: true)
    }

    // Fast path for unattributed tags: avoid buffer swap entirely.
    guard cursor < bytes.count else { throw .unexpectedEOF }
    if bytes[cursor] == UInt8(ascii: ">") || bytes[cursor] == UInt8(ascii: "/") {
      let closed = bytes[cursor] == UInt8(ascii: "/")
      let range = SourceRange(attributes ..< cursor)
      step()  // consume '>' or '/'
      if closed { try consume(UInt8(ascii: ">")) }
      return token(start: start, name: name, attributes: range,
                   namespaced: false, closed: closed)
    }

    var namespaced = false
    var requiresSpace = false

    while cursor < bytes.count {
      let spaced = spaces()
      guard cursor < bytes.count else { throw .unexpectedEOF }
      let byte = bytes[cursor]
      switch byte {
      case UInt8(ascii: ">"), UInt8(ascii: "/"):
        let closed = byte == UInt8(ascii: "/")
        let range = SourceRange(attributes ..< cursor)
        step()  // consume '>' or '/'
        if closed { try consume(UInt8(ascii: ">")) }
        return token(start: start, name: name, attributes: range,
                     namespaced: namespaced, closed: closed)
      default:
        if requiresSpace, !spaced { throw .invalidCharacter }
        let record = try attribute(at: attributes, namespaced: &namespaced)
        self.attributes.append(record)
        requiresSpace = true
      }
    }
    throw .unexpectedEOF
  }

  // [43] content  ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
  // [39] element  ::= EmptyElemTag | STag content ETag
  // Dispatches on the byte after '<' to select the appropriate production.
  @_lifetime(self: copy self)
  @_lifetime(&self)
  private mutating func markup() throws(XML.Error) -> Located<XML.Token>? {
    guard cursor + 1 < bytes.count else { throw .unexpectedEOF }
    switch bytes[cursor + 1] {
    case UInt8(ascii: "?"):
      return try processing()
    case UInt8(ascii: "/"):
      return try end()
    case UInt8(ascii: "!"):
      guard cursor + 2 < bytes.count else { throw .unexpectedEOF }
      switch bytes[cursor + 2] {
      case UInt8(ascii: "-"):
        return try comment()  // <!--
      case UInt8(ascii: "["):
        return try cdata()    // <![CDATA[
      default:
        return try doctype()
      }
    default:
      return try start()
    }
  }

  // [14] CharData ::= [^<&]* - ([^<&]* ']]>' [^<&]*)
  // [2]  Char     ::= #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]
  @_lifetime(self: copy self)
  @_lifetime(&self)
  private mutating func text() throws(XML.Error) -> Located<XML.Token>? {
    let start = cursor
    var processed = true
    while cursor < bytes.count {
      run()
      guard cursor < bytes.count else { break }
      let byte = bytes[cursor]
      switch byte {
      case UInt8(ascii: "<"):
        return Located(value: .text(bytes.extracting(start ..< cursor)),
                       source: source(from: start),
                       processed: processed)
      case UInt8(ascii: "&"):
        processed = false
        cursor += 1
      case UInt8(ascii: "]"):
        // Per XML 1.0 §2.4, ']]>' is forbidden in character data.
        if cursor + 2 < bytes.count,
           bytes[cursor + 1] == UInt8(ascii: "]"),
           bytes[cursor + 2] == UInt8(ascii: ">") {
          throw .invalidCharacter
        }
        cursor += 1
      case _ where byte > 0x7f:
        guard let decoded = try bytes.decodeScalar(at: cursor) else {
          throw .unexpectedEOF
        }
        // [2]: U+FFFE and U+FFFF are not Chars.
        guard decoded.scalar.value != 0xfffe, decoded.scalar.value != 0xffff else {
          throw .invalidCharacter
        }
        cursor += decoded.stride
      default:
        // [2]: the only legal ASCII control chars are #x9 (#xA, #xD).
        guard byte.isXMLASCIIWhitespace else { throw .invalidCharacter }
        step()
      }
    }
    return Located(value: .text(bytes.extracting(start ..< cursor)),
                   source: source(from: start),
                   processed: processed)
  }
}
