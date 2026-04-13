// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import XMLCore

internal struct NamespaceResolver: ~Copyable, ~Escapable {
  // MARK: - Types

  internal typealias Reference = XML.ResolvedAttributes.Reference
  internal typealias Record = XML.ResolvedAttributes.Record

  internal struct Element: ~Escapable {
    internal let namespace: Reference?
    internal let name: XML.QualifiedNameView

    @_lifetime(borrow name)
    internal init(name: borrowing Span<XML.Byte>, colon: Int?, namespace: Reference?) {
      self.namespace = namespace
      self.name = XML.QualifiedNameView(unvalidated: name, colon: colon)
    }
  }

  private struct Binding {
    fileprivate let prefix: Reference?
    fileprivate let hash: UInt64
    fileprivate let uri: Reference
    fileprivate var reference: Reference? = nil
    fileprivate var generation: UInt32 = 0
  }

  internal struct AttributeResolutionState {
    internal var records = DoubleBuffer<Record>()
    internal var visited = ProbeSet()

    @inline(__always)
    internal mutating func clear() {
      guard !records.front.isEmpty else { return }
      records.front.removeAll(keepingCapacity: true)
    }
  }

  // MARK: - Storage

  private let source: Span<XML.Byte>
  private var bindings: [Binding] = []
  private var arena = Arena()
  private var defaultNamespace: Int?
  private var generation: UInt32 = 0
  private var scopes = Stack<Int>()
  internal var attributes = AttributeResolutionState()

  @_lifetime(borrow source)
  internal init(source: borrowing Span<XML.Byte>) {
    self.source = copy source
    arena.reserve(capacity: max(64, source.count >> 4))
    let prefix = arena.intern("xml")
    let uri = arena.intern("http://www.w3.org/XML/1998/namespace")
    bindings.append(Binding(prefix: prefix, hash: FNV1a.hash64("xml"), uri: uri))
  }
}

// MARK: - Resolution

extension NamespaceResolver {
  private enum Style {
    case linear
    case hashed
  }

  internal mutating func mappings(for attributes: borrowing XML.UnresolvedAttributes) throws(XML.Error) -> Range<Int> {
    let bindings = bindings.count

    scopes.push(bindings)

    if attributes.isEmpty {
      self.attributes.clear()
      return bindings ..< bindings
    }

    if attributes.namespaced {
      try resolve(qualified: attributes)
    } else {
      try resolve(unqualified: attributes)
    }
    return bindings ..< self.bindings.count
  }

  private mutating func resolve(unqualified attributes: borrowing XML.UnresolvedAttributes) throws(XML.Error) {
    let bytes = attributes.bytes
    let records = attributes.records
    let style: Style = attributes.count > 4 ? .hashed : .linear

    self.attributes.records.cycle(capacity: attributes.count)
    if style == .hashed {
      self.attributes.visited.reset(count: attributes.count)
    }

    for index in records.indices {
      let attribute = records[index]
      let name = bytes.extracting(attribute.name)
      try check(unique: name, in: records, to: index, style: style, bytes: bytes)
      try append(attribute, from: bytes)
    }
  }

  private mutating func resolve(qualified attributes: borrowing XML.UnresolvedAttributes) throws(XML.Error) {
    let bytes = attributes.bytes
    let records = attributes.records
    var style: Style = attributes.count > 4 ? .hashed : .linear

    self.attributes.records.cycle(capacity: attributes.count)
    advance()
    if style == .hashed {
      self.attributes.visited.reset(count: attributes.count)
    }

    let source = attributes.range
    for index in records.indices {
      let attribute = records[index]
      let name = bytes.extracting(attribute.name)
      try check(unique: name, in: records, to: index, style: style, bytes: bytes)
      try emit(attribute, named: name, in: bytes, source: source)
    }

    style = self.attributes.records.front.count > 4 ? .hashed : .linear
    if style == .hashed {
      self.attributes.visited.reset(count: self.attributes.records.front.count)
    }

    for index in self.attributes.records.front.indices {
      let record = self.attributes.records.front[index]
      let namespace = try bind(record, in: bytes)
      try check(unique: record, namespace: namespace, to: index, style: style, in: bytes)
      let updated = XML.ResolvedAttributes.Record(name: record.name, colon: record.colon,
                                                  value: record.value, namespace: namespace)
      self.attributes.records.front[index] = updated
    }
  }
}

// MARK: - API

extension NamespaceResolver {
  @_lifetime(borrow name)
  internal func resolve(_ name: borrowing Span<XML.Byte>) throws(XML.Error) -> Element {
    let colon = name.first(UInt8(ascii: ":"))
    if let colon { try XML.QualifiedName.validate(name, colon: colon) }

    // Fast path: an unprefixed name with no default namespace cannot resolve to
    // a namespace, so skip the binding lookup and namespace resolution.
    if colon == nil, defaultNamespace == nil {
      return Element(name: name, colon: colon, namespace: nil)
    }

    let namespace = if let binding = try binding(of: name, colon: colon, attribute: false) {
        bindings[binding].uri
      } else {
        nil as XML.ResolvedAttributes.Reference?
      }
    return Element(name: name, colon: colon, namespace: namespace)
  }

  internal mutating func popScope() throws(XML.Error) -> Range<Int> {
    guard let base = scopes.pop() else { throw .invalidDocument }
    return base ..< bindings.count
  }

  @_lifetime(self: copy self)
  internal mutating func remove(bindings range: Range<Int>) {
    guard !range.isEmpty else { return }
    if let defaultNamespace, range.contains(defaultNamespace) {
      uninstall(defaultBinding: defaultNamespace)
    }
    bindings.removeSubrange(range)
  }

  @inline(__always)
  @_lifetime(borrow self)
  internal func prefix(for binding: Int) -> Span<XML.Byte>? {
    guard let prefix = bindings[binding].prefix else { return nil }
    return span(for: prefix)
  }

  @inline(__always)
  @_lifetime(borrow self)
  internal func uri(for binding: Int) -> Span<XML.Byte> {
    span(for: bindings[binding].uri)
  }

  @inline(__always)
  @_lifetime(borrow self)
  internal func namespace(of element: borrowing Element) -> Span<XML.Byte>? {
    guard let namespace = element.namespace else { return nil }
    return span(for: namespace)
  }
}

// MARK: - Helpers

extension NamespaceResolver {
  @inline(__always)
  private mutating func check(unique name: borrowing Span<XML.Byte>,
                              in records: borrowing Span<XML.UnresolvedAttributes.Record>,
                              to index: Int,
                              style: Style,
                              bytes: borrowing Span<XML.Byte>) throws(XML.Error) {
    switch style {
    case .linear:
      for prior in 0 ..< index {
        if name == bytes.extracting(records[prior].name) {
          throw .invalidAttribute
        }
      }
    case .hashed:
      try insert(name, at: index, in: records, bytes: bytes)
    }
  }

  @inline(__always)
  private mutating func emit(_ attribute: XML.UnresolvedAttributes.Record,
                             named name: borrowing Span<XML.Byte>,
                             in bytes: borrowing Span<XML.Byte>,
                             source: SourceRange) throws(XML.Error) {
    if attribute.declaration {
      try declare(prefix: attribute.prefix?.absolute(in: source),
                  uri: try intern(binding: attribute, bytes: bytes, source: source))
    } else {
      try XML.QualifiedName.validate(name, colon: attribute.colon)
      try append(attribute, from: bytes)
    }
  }

  @inline(__always)
  private mutating func bind(_ record: XML.ResolvedAttributes.Record,
                             in bytes: borrowing Span<XML.Byte>) throws(XML.Error) -> Reference? {
    if let colon = record.colon,
       let binding = try binding(of: bytes.extracting(record.name), colon: colon, attribute: true) {
      return reference(for: binding, sourceCount: bytes.count)
    }
    return nil
  }

  @inline(__always)
  private mutating func check(unique record: XML.ResolvedAttributes.Record,
                              namespace: Reference?,
                              to count: Int,
                              style: Style,
                              in bytes: borrowing Span<XML.Byte>) throws(XML.Error) {
    switch style {
    case .linear:
      let name = local(name: record.name, colon: record.colon, in: bytes)
      for index in 0 ..< count {
        let prior = self.attributes.records.front[index]
        guard name == local(name: prior.name, colon: prior.colon, in: bytes) else { continue }
        if Bytes.equal(namespace, prior.namespace, in: bytes, storage: self.attributes.records.store.bytes.span) {
          throw .invalidAttribute
        }
      }
    case .hashed:
      try unique(record: record, for: bytes, at: count, namespace: namespace)
    }
  }

  @inline(__always)
  @_lifetime(borrow self)
  private func span(for reference: XML.ResolvedAttributes.Reference) -> Span<XML.Byte> {
    switch reference {
    case let .input(range): source.extracting(range)
    case let .buffer(range): arena.span(for: range)
    }
  }

  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func intern(binding record: XML.UnresolvedAttributes.Record,
                               bytes: borrowing Span<XML.Byte>,
                               source: SourceRange) throws(XML.Error) -> XML.ResolvedAttributes.Reference {
    try record.normalize(in: bytes, source: source, into: &arena)
  }

  @inline(__always)
  @_lifetime(borrow self, borrow attributes)
  internal func resolve(_ attributes: borrowing XML.UnresolvedAttributes) -> XML.ResolvedAttributes {
    XML.ResolvedAttributes(source: attributes.source,
                               range: attributes.range,
                               buffer: self.attributes.records.store.bytes,
                               records: self.attributes.records.front)
  }

  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func advance() {
    if generation == .max {
      generation = 1
      for index in bindings.indices {
        bindings[index].reference = nil
        bindings[index].generation = 0
      }
    } else {
      generation &+= 1
    }
  }

  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func reference(for binding: Int, sourceCount: Int) -> XML.ResolvedAttributes.Reference {
    if bindings[binding].generation == generation,
       let cached = bindings[binding].reference {
      return cached
    }

    self.attributes.records.store.reserve(capacity: sourceCount)
    let source = self.source
    let uri = bindings[binding].uri
    let reference: XML.ResolvedAttributes.Reference
    switch uri {
    case let .input(range):
      reference = self.attributes.records.store.intern(source.extracting(range))
    case let .buffer(range):
      let bytes = arena.bytes
      reference = self.attributes.records.store.intern(bytes.span.extracting(range))
    }
    bindings[binding].reference = reference
    bindings[binding].generation = generation
    return reference
  }

  @_lifetime(self: copy self)
  private mutating func declare(prefix: SourceRange?,
                                uri: XML.ResolvedAttributes.Reference) throws(XML.Error) {
    let prefix: XML.ResolvedAttributes.Reference? = prefix.map { .input($0) }
    let hash = try validate(prefix: prefix, uri: uri)
    install(Binding(prefix: prefix, hash: hash, uri: uri))
  }

  @_lifetime(self: copy self)
  private mutating func append(_ attribute: XML.UnresolvedAttributes.Record,
                               from bytes: borrowing Span<XML.Byte>,
                               namespace: Reference? = nil) throws(XML.Error) {
    let value = try attribute.normalize(in: bytes, into: &self.attributes.records.store)
    self.attributes.records.front.append(Record(name: attribute.name,
                                                colon: attribute.colon,
                                                value: value,
                                                namespace: namespace))
  }

  private func binding(prefix: borrowing Span<XML.Byte>) -> Int? {
    let hash = FNV1a.hash64(prefix)
    for index in bindings.indices.reversed() {
      let binding = bindings[index]
      guard binding.hash == hash, let candidate = binding.prefix else { continue }
      if span(for: candidate) == prefix {
        return index
      }
    }
    return nil
  }

  private func binding(of name: borrowing Span<XML.Byte>, colon: Int?,
                       attribute: Bool) throws(XML.Error) -> Int? {
    guard let colon else {
      guard !attribute else { return nil }
      guard let defaultNamespace else { return nil }
      let index = Int(defaultNamespace)
      return uri(for: index).isEmpty ? nil : index
    }
    let prefix = name.extracting(0 ..< colon)
    guard let binding = binding(prefix: prefix) else { throw .invalidName }
    return binding
  }

  @_lifetime(self: copy self)
  private mutating func unique(record: XML.ResolvedAttributes.Record,
                               for bytes: borrowing Span<XML.Byte>,
                               at index: Int,
                               namespace: XML.ResolvedAttributes.Reference?) throws(XML.Error) {
    let name = local(name: record.name, colon: record.colon, in: bytes)
    // Capture once so the probe closure does not repeatedly hit tuple accessors.
    let records = self.attributes.records.front
    let storage = self.attributes.records.store.bytes
    guard self.attributes.visited.insert(index,
                                         hash: hash(namespace: namespace, local: name, in: bytes, storage: storage.span),
                                         equals: {
                                           let other = records[$0]
                                           guard name == local(name: other.name, colon: other.colon, in: bytes) else {
                                             return false
                                           }
                                           return Bytes.equal(namespace, other.namespace, in: bytes, storage: storage.span)
                                         }) == nil else {
      throw .invalidAttribute
    }
  }

  @_lifetime(self: copy self)
  private mutating func insert(_ name: borrowing Span<XML.Byte>,
                               at index: Int,
                               in records: borrowing Span<XML.UnresolvedAttributes.Record>,
                               bytes: borrowing Span<XML.Byte>) throws(XML.Error) {
    guard self.attributes.visited.insert(index,
                                         hash: FNV1a.hash64(name),
                                         equals: { name == bytes.extracting(records[$0].name) }) == nil else {
      throw .invalidAttribute
    }
  }

  private func validate(prefix: XML.ResolvedAttributes.Reference?,
                        uri reference: XML.ResolvedAttributes.Reference) throws(XML.Error) -> UInt64 {
    let uri = span(for: reference)
    if uri == StaticString("http://www.w3.org/2000/xmlns/") { throw .invalidAttribute }
    let xml = uri == StaticString("http://www.w3.org/XML/1998/namespace")

    guard let prefix else {
      guard !xml else { throw .invalidAttribute }
      return 0
    }

    let name = span(for: prefix)
    if name == StaticString("xmlns") { throw .invalidAttribute }
    do {
      try XML.QualifiedName.validate(name)
    } catch {
      throw .invalidAttribute
    }

    if name == StaticString("xml") {
      guard xml else { throw .invalidAttribute }
    } else {
      guard !uri.isEmpty, !xml else { throw .invalidAttribute }
    }

    return FNV1a.hash64(name)
  }

  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func install(_ binding: consuming Binding) {
    let binding = consume binding
    if binding.prefix == nil { defaultNamespace = bindings.count }
    bindings.append(binding)
  }

  @inline(__always)
  @_lifetime(self: copy self)
  private mutating func uninstall(defaultBinding index: Int) {
    assert(bindings[index].prefix == nil)
    assert(defaultNamespace == index)
    var current = index
    while current > 0 {
      current -= 1
      if bindings[current].prefix == nil {
        defaultNamespace = current
        return
      }
    }
    defaultNamespace = nil
  }
}

@inline(__always)
@_lifetime(borrow source)
private func local(name: SourceRange, colon: Int?,
                   in source: borrowing Span<XML.Byte>) -> Span<XML.Byte> {
  let name = source.extracting(name)
  guard let colon else { return name }
  return name.extracting((colon + 1)...)
}
