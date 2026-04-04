// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal import XMLCore

internal struct NamespaceResolver: ~Copyable, ~Escapable {
  // MARK: - Types

  internal typealias Reference = XML.ResolvedAttributes.Reference
  private typealias Record = XML.ResolvedAttributes.Record

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

  // MARK: - Storage

  private let source: Span<XML.Byte>
  private var bindings: [Binding] = []
  private var arena = Arena()
  private var defaultNamespace: Int?
  private var generation: UInt32 = 0
  private var scopes = Stack<Int>()
  private var attributes: (records: DoubleBuffer<Record>, visited: ProbeSet) = (.init(), .init())

  @_lifetime(borrow source)
  internal init(source: borrowing Span<XML.Byte>) {
    self.source = copy source
    arena.reserve(capacity: max(64, source.count >> 4))
    let prefix = arena.intern("xml")
    let uri = arena.intern("http://www.w3.org/XML/1998/namespace")
    bindings.append(Binding(prefix: prefix, hash: FNVHasher.hash("xml"), uri: uri))
  }
}

// MARK: - Resolution

extension NamespaceResolver {
  internal mutating func mappings(for attributes: borrowing XML.UnresolvedAttributes) throws(XML.Error) -> Range<Int> {
    if attributes.isEmpty {
      scopes.push(-1)
      self.attributes.records.front.removeAll(keepingCapacity: true)
      return bindings.count ..< bindings.count
    }

    let base = bindings.count
    scopes.push(base)
    if attributes.namespaced {
      try resolve(qualified: attributes)
    } else {
      try resolve(unqualified: attributes)
    }
    return base ..< bindings.count
  }

  private mutating func resolve(unqualified attributes: borrowing XML.UnresolvedAttributes) throws(XML.Error) {
    let bytes = attributes.bytes
    let records = attributes.records

    self.attributes.records.cycle(capacity: attributes.count)

    if attributes.count <= 4 {
      // For small attribute lists use O(n²) linear scan for duplicate detection
      // — avoids hash-table initialisation and FNV hashing.  For the typical
      // element with 1–2 attributes this eliminates ~5–6 ns of overhead.
      for index in records.indices {
        let attribute = records[index]
        for prior in 0 ..< index {
          if bytes.extracting(attribute.name) == bytes.extracting(records[prior].name) {
            throw .invalidAttribute
          }
        }
        try append(attribute, from: bytes)
      }
    } else {
      self.attributes.visited.reset(count: attributes.count)
      for index in records.indices {
        let attribute = records[index]
        let name = bytes.extracting(attribute.name)
        try insert(name, at: index, in: records, bytes: bytes)
        try append(attribute, from: bytes)
      }
    }
  }

  private mutating func resolve(qualified attributes: borrowing XML.UnresolvedAttributes) throws(XML.Error) {
    let bytes = attributes.bytes
    let records = attributes.records
    let source = attributes.range
    self.attributes.records.cycle(capacity: attributes.count)
    advance()
    self.attributes.visited.reset(count: attributes.count)

    for index in records.indices {
      let attribute = records[index]
      let name = bytes.extracting(attribute.name)
      try insert(name, at: index, in: records, bytes: bytes)

      if !attribute.declaration {
        try XML.QualifiedName.validate(name, colon: attribute.colon)
        try append(attribute, from: bytes)
      } else {
        try declare(prefix: attribute.prefix?.absolute(in: source),
                    uri: try intern(binding: attribute, bytes: bytes, source: source))
      }
    }

    self.attributes.visited.reset(count: self.attributes.records.front.count)
    for index in self.attributes.records.front.indices {
      let record = self.attributes.records.front[index]
      let namespace = if let colon = record.colon,
             let binding = try binding(of: bytes.extracting(record.name), colon: colon, attribute: true) {
          reference(for: binding, sourceCount: bytes.count)
        } else {
          nil as XML.ResolvedAttributes.Reference?
        }
      try unique(record: record, for: bytes, at: index, namespace: namespace)
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
    guard base >= 0 else { return 0 ..< 0 }
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
    let hash = FNVHasher.hash(prefix)
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
    let part = local(name: record.name, colon: record.colon, in: bytes)
    // Capture records and storage as local lets so the closure retains each
    // array once (vs calling the computed-property getter on every invocation).
    // attributes.records and attributes.visited are distinct tuple elements so
    // mutating visited does not conflict with reading records/store here.
    let records = self.attributes.records.front
    let storage = self.attributes.records.store.bytes
    guard self.attributes.visited.insert(index,
                                         hash: FNVHasher.hash(namespace, local: part, in: bytes, storage: storage.span),
                                         equals: {
                                           let other = records[$0]
                                           guard part == local(name: other.name, colon: other.colon, in: bytes) else {
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
                                         hash: FNVHasher.hash(name),
                                         equals: { name == bytes.extracting(records[$0].name) }) == nil else {
      throw .invalidAttribute
    }
  }

  private func validate(prefix: XML.ResolvedAttributes.Reference?,
                        uri reference: XML.ResolvedAttributes.Reference) throws(XML.Error) -> UInt64 {
    let uri = span(for: reference)
    if uri == StaticString("http://www.w3.org/2000/xmlns/") { throw .invalidAttribute }

    guard let prefix else {
      if uri == StaticString("http://www.w3.org/XML/1998/namespace") { throw .invalidAttribute }
      return 0
    }

    let namespace = span(for: prefix)
    if namespace == StaticString("xmlns") { throw .invalidAttribute }
    do {
      try XML.QualifiedName.validate(namespace)
    } catch {
      throw .invalidAttribute
    }

    if namespace == StaticString("xml") {
      guard uri == StaticString("http://www.w3.org/XML/1998/namespace") else { throw .invalidAttribute }
      return FNVHasher.hash(namespace)
    }

    guard !uri.isEmpty else { throw .invalidAttribute }
    if uri == StaticString("http://www.w3.org/XML/1998/namespace") { throw .invalidAttribute }
    return FNVHasher.hash(namespace)
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
