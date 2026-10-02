// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

import Testing
import XMLCore
import DOMParser

private enum DOMFixtureError: Error {
  case missingRootElement
  case missingDocumentType
  case missingNodeValue
  case missingTextNode
  case unexpectedNodeCount
}

extension Span where Element == XML.Byte {
  @inline(__always)
  internal var string: String {
    withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
  }
}

extension Optional where Wrapped == Span<XML.Byte> {
  @inline(__always)
  internal var string: String? {
    if let self { return self.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) } }
    return nil
  }
}

extension Optional where Wrapped == XML.QualifiedNameView {
  @inline(__always)
  internal var string: String? {
    if let self { return self.bytes.string }
    return nil
  }
}

@inline(__always)
private func withDocument<Result>(_ xml: String,
                                  _ body: (borrowing Document) throws -> Result) throws -> Result {
  let bytes = Array(xml.utf8)
  let document = try DOMParser.parse(bytes: bytes.span)
  return try body(document)
}

@inline(__always)
private func parse(_ xml: String) throws {
  _ = try withDocument(xml) { _ in () }
}

@inline(__always)
private func isXMLWhitespace(_ string: String) -> Bool {
  string.utf8.allSatisfy {
    $0 == UInt8(ascii: " ")
      || $0 == UInt8(ascii: "\t")
      || $0 == UInt8(ascii: "\n")
      || $0 == UInt8(ascii: "\r")
  }
}

@inline(__always)
private func children(of node: Document.Reference,
                      in document: borrowing Document) -> [Document.Reference] {
  var children: [Document.Reference] = []
  var current = document.firstChild(of: node)
  while let child = current {
    children.append(child)
    current = document.nextSibling(of: child)
  }
  return children
}

@inline(__always)
private func children(of node: Document.Reference,
                      kind: Document.NodeKind,
                      in document: borrowing Document) -> [Document.Reference] {
  children(of: node, in: document).filter { document.kind(of: $0) == kind }
}

@inline(__always)
private func topLevelElement(in document: borrowing Document) throws -> Document.Reference {
  for child in children(of: document.root, in: document) where document.kind(of: child) == .element {
    return child
  }
  throw DOMFixtureError.missingRootElement
}

@inline(__always)
private func topLevelDTD(in document: borrowing Document) throws -> Document.Reference {
  for child in children(of: document.root, in: document) where document.kind(of: child) == .dtd {
    return child
  }
  throw DOMFixtureError.missingDocumentType
}

@inline(__always)
private func nonWhitespaceTopLevelChildren(in document: borrowing Document) -> [Document.Reference] {
  children(of: document.root, in: document).filter { child in
    guard document.kind(of: child) == .text else { return true }
    return !(nodeValue(of: child, in: document).map(isXMLWhitespace) ?? true)
  }
}

@inline(__always)
private func firstChildText(of element: Document.Reference,
                            in document: borrowing Document) throws -> String {
  for child in children(of: element, in: document) where document.kind(of: child) == .text {
    guard let value = nodeValue(of: child, in: document) else { break }
    return value
  }
  throw DOMFixtureError.missingTextNode
}

private func attributes(of element: Document.Reference,
                        in document: borrowing Document) -> [String:(namespace: String?, value: String)] {
  var attributes: [String:(namespace: String?, value: String)] = [:]
  var current = document.firstAttribute(of: element)
  while let attribute = current {
    let view = document.view(of: attribute)
    guard let name = view.name, let value = view.value else {
      current = document.nextAttribute(after: attribute)
      continue
    }
    attributes[name.bytes.string] = (namespace: view.namespace.string, value: value.string)
    current = document.nextAttribute(after: attribute)
  }
  return attributes
}

@inline(__always)
private func nodeName(of node: Document.Reference,
                      in document: borrowing Document) -> String? {
  let view = document.view(of: node)
  return view.name.string
}

@inline(__always)
private func nodeValue(of node: Document.Reference,
                       in document: borrowing Document) -> String? {
  let view = document.view(of: node)
  return view.value.string
}

private func content(of node: Document.Reference, in document: borrowing Document)
    -> (name: String?, local: String?, value: String?, namespace: String?) {
  let name = document.name(of: node)
  return (name: name.string, local: name?.local.string,
          value: document.value(of: node).string,
          namespace: document.namespace(of: node).string)
}

@Suite("DOMParser")
internal struct DOMParserTests {
  @Test("preserves top-level markup and mixed element content")
  internal func mixedStructure() throws {
    try withDocument(
      """
      <?xml version="1.0"?>
      <!--lead--><?meta x?><!DOCTYPE root SYSTEM "urn:test">
      <root xmlns="urn:default" xmlns:p="urn:p" a="1" p:b="2">t<![CDATA[c]]><!--x--><?q r?><child/></root><!--tail-->
      """
    ) { document in
      let topText = children(of: document.root, kind: .text, in: document)
      #expect(topText.allSatisfy { nodeValue(of: $0, in: document).map(isXMLWhitespace) ?? true })

      let top = nonWhitespaceTopLevelChildren(in: document)
      #expect(top.map { document.kind(of: $0) } == [.comment, .processingInstruction, .dtd, .element, .comment])

      let dtd = document.view(of: try topLevelDTD(in: document))
      #expect(dtd.name.string == "root")
      #expect(dtd.value.string == nil)
      #expect(dtd.systemID.string == "urn:test")

      let root = try topLevelElement(in: document)
      let view = document.view(of: root)
      #expect(view.name.string == "root")
      #expect(view.namespace.string == "urn:default")

      let attrs = attributes(of: root, in: document)
      #expect(attrs.count == 2)
      #expect(attrs["a"]?.namespace == nil)
      #expect(attrs["a"]?.value == "1")
      #expect(attrs["p:b"]?.namespace == "urn:p")
      #expect(attrs["p:b"]?.value == "2")

      let content = children(of: root, in: document)
      #expect(content.map { document.kind(of: $0) } == [.text, .cdata, .comment, .processingInstruction, .element])
      guard content.count == 5 else { throw DOMFixtureError.unexpectedNodeCount }
      #expect(nodeValue(of: content[0], in: document) == "t")
      #expect(nodeValue(of: content[1], in: document) == "c")
      #expect(nodeValue(of: content[2], in: document) == "x")
      #expect(nodeName(of: content[3], in: document) == "q")
      #expect(nodeValue(of: content[3], in: document) == "r")
      #expect(nodeName(of: content[4], in: document) == "child")
    }
  }

  @Test("normalizes attribute whitespace and expands predefined entities")
  internal func normalizedAttributeValues() throws {
    try withDocument(
      """
      <r a="x&#x41;&#65;&lt;&gt;&amp;&apos;&quot;y" ws="a&#x09;b&#x0A;c&#x0D;d&#x0D;&#x0A;e"/>
      """
    ) { document in
      let root = try topLevelElement(in: document)
      let attrs = attributes(of: root, in: document)
      #expect(attrs["a"]?.value == "xAA<>&'\"y")
      #expect(attrs["ws"]?.value == "a b c d  e")
    }
  }

  @Test("applies default namespace to elements only")
  internal func defaultNamespaceDoesNotApplyToAttributes() throws {
    try withDocument("<r xmlns='urn:r' xmlns:p='urn:p' a='1' p:x='2'/>") { document in
      let root = try topLevelElement(in: document)
      let view = document.view(of: root)

      #expect(view.namespace.string == "urn:r")

      let attrs = attributes(of: root, in: document)
      #expect(attrs["a"]?.namespace == nil)
      #expect(attrs["p:x"]?.namespace == "urn:p")
    }
  }

  @Test("direct content accessors match node and attribute views")
  internal func directAccessorsMatchViews() throws {
    try withDocument(
      """
      <?xml version="1.0"?>
      <!DOCTYPE r PUBLIC "-//pub" "sys.dtd">
      <r xmlns='urn:r' xmlns:p='urn:p' a='1' p:x='&amp;2'><!--c--><?pi data?>t&lt;<![CDATA[d]]><p:e/></r>
      """
    ) { document in
      var nodes: [Document.Reference] = []
      var pending = children(of: document.root, in: document)
      while !pending.isEmpty {
        let node = pending.removeFirst()
        nodes.append(node)
        var attribute = document.firstAttribute(of: node)
        while let current = attribute {
          nodes.append(current)
          attribute = document.nextAttribute(after: current)
        }
        pending.append(contentsOf: children(of: node, in: document))
      }
      #expect(Set(nodes.map { document.kind(of: $0) })
                == [.dtd, .element, .attribute, .comment, .processingInstruction, .text, .cdata])

      for node in nodes {
        let direct = content(of: node, in: document)
        let view = document.view(of: node)
        let name = view.name
        let local = name?.local.string
        let value = view.value.string
        let namespace = view.namespace.string
        #expect(direct.name == name.string)
        #expect(direct.local == local)
        #expect(direct.value == value)
        #expect(direct.namespace == namespace)
      }

      let top = content(of: document.root, in: document)
      #expect(top.name == nil)
      #expect(top.value == nil)

      let root = try topLevelElement(in: document)
      let element = content(of: root, in: document)
      #expect(element.name == "r")
      #expect(element.value == nil)
      #expect(element.namespace == "urn:r")

      guard let a = document.firstAttribute(of: root),
            let x = document.nextAttribute(after: a) else {
        Issue.record("missing attributes")
        return
      }
      let unqualified = content(of: a, in: document)
      #expect(unqualified.value == "1")
      #expect(unqualified.namespace == nil)
      let qualified = content(of: x, in: document)
      #expect(qualified.name == "p:x")
      #expect(qualified.local == "x")
      #expect(qualified.value == "&2")
      #expect(qualified.namespace == "urn:p")

      let children = children(of: root, in: document)
      #expect(children.map { document.kind(of: $0) }
                == [.comment, .processingInstruction, .text, .cdata, .element])
      #expect(children.map { content(of: $0, in: document).value }
                == ["c", "data", "t<", "d", nil])
    }
  }

  @Test("rejects undeclared namespace prefixes")
  internal func rejectsUndeclaredPrefix() {
    #expect(throws: XML.Error.self) { try parse("<p:r/>") }
  }

  @Test("rejects invalid QName forms with multiple colons")
  internal func rejectsMultipleColonQNames() {
    #expect(throws: XML.Error.self) { try parse("<r xmlns:a='urn:u'><a:b:c/></r>") }
    #expect(throws: XML.Error.self) { try parse("<r xmlns:a='urn:u' a:b:c='1'/>") }
  }

  @Test("rejects duplicate attribute names")
  internal func rejectsDuplicateQualifiedAttributes() {
    #expect(throws: XML.Error.self) { try parse("<r a='1' a='2'/>") }
  }

  @Test("rejects duplicate expanded-name attributes")
  internal func rejectsDuplicateExpandedAttributes() {
    #expect(throws: XML.Error.self) { try parse("<r xmlns:a='urn:u' xmlns:b='urn:u' a:x='1' b:x='2'/>") }
  }

  @Test("rejects invalid bindings for reserved XML namespaces")
  internal func rejectsReservedNamespaceViolations() {
    #expect(throws: XML.Error.self) { try parse("<r xmlns:xml='urn:not-xml'/>") }
    #expect(throws: XML.Error.self) { try parse("<r xmlns:p='http://www.w3.org/XML/1998/namespace'/>") }
  }

  @Test("rejects malformed namespace declaration prefixes")
  internal func rejectsMalformedNamespaceDeclarationPrefixes() {
    #expect(throws: XML.Error.self) { try parse("<r xmlns:='urn:u'/>") }
    #expect(throws: XML.Error.self) { try parse("<r xmlns:1p='urn:u'/>") }
    #expect(throws: XML.Error.self) { try parse("<r xmlns:a:b='urn:u'/>") }
  }

  @Test("rejects mismatched end tags")
  internal func rejectsMismatchedEndTags() {
    #expect(throws: XML.Error.self) { try parse("<a></b>") }
  }

  @Test("rejects multiple root elements")
  internal func rejectsMultipleRoots() {
    #expect(throws: XML.Error.self) { try parse("<a/><b/>") }
  }

  @Test("rejects non-whitespace outside the document element")
  internal func rejectsTopLevelCharacterData() {
    #expect(throws: XML.Error.self) { try parse("x<a/>") }
  }

  @Test("rejects misplaced XML declaration")
  internal func rejectsMisplacedDeclaration() {
    #expect(throws: XML.Error.self) { try parse(" \n<?xml version='1.0'?><a/>") }
  }

  @Test("rejects forbidden ']]>' in element character data")
  internal func rejectsCDataTerminatorInText() {
    #expect(throws: XML.Error.self) { try parse("<a>]]></a>") }
  }

  @Test("rejects malformed comments")
  internal func rejectsMalformedComments() {
    #expect(throws: XML.Error.self) { try parse("<a><!-- bad -- nope --></a>") }
  }

  @Test("rejects invalid numeric character references")
  internal func rejectsInvalidCharacterReferences() {
    #expect(throws: XML.Error.self) { try parse("<a>&#0;</a>") }
    #expect(throws: XML.Error.self) { try parse("<a>&#4294967296;</a>") }
  }

  @Test("accepts compact XML declaration permutations")
  internal func xmlDeclarationAcceptanceMatrix() throws {
    for xml in [
      "<?xml version='1.0'?><r/>",
      "<?xml version='1.0' encoding='UTF-8'?><r/>",
      "<?xml version='1.0' standalone='yes'?><r/>",
      "<?xml version='1.0' standalone='no'?><r/>",
      "<?xml version='1.0' encoding='UTF-8' standalone='yes'?><r/>",
    ] {
      try parse(xml)
    }
  }

  @Test("rejects malformed XML declarations")
  internal func xmlDeclarationRejectionMatrix() {
    for xml in [
      "<?xml encoding='UTF-8'?><r/>",
      "<?xml version='1.0' version='1.0'?><r/>",
      "<?xml version='1.1'?><r/>",
      "<?xml version='1.0' bogus='1'?><r/>",
      "<?xml version='1.0' standalone='maybe'?><r/>",
    ] {
      #expect(throws: XML.Error.self) { try parse(xml) }
    }
  }

  @Test("expands UTF-8 character references at XML Char boundaries")
  internal func characterReferenceBoundaryAcceptance() throws {
    try withDocument(
      """
      <r>&#x9;&#xA;&#xD;&#x20;&#xD7FF;&#xE000;&#xFFFD;&#x10000;&#x10FFFF;</r>
      """
    ) { document in
      let root = try topLevelElement(in: document)
      let text = try firstChildText(of: root, in: document)
      let scalars = [0x09, 0x0a, 0x0d, 0x20, 0xd7ff, 0xe000, 0xfffd, 0x0001_0000, 0x0010_ffff]
      let expected = String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init)))
      #expect(text == expected)
    }
  }

  @Test("rejects disallowed UTF-8 character references")
  internal func characterReferenceBoundaryRejection() {
    for xml in [
      "<r>&#xD800;</r>",
      "<r>&#xDFFF;</r>",
      "<r>&#xFFFE;</r>",
      "<r>&#xFFFF;</r>",
      "<r>&#x110000;</r>",
      "<r>&#55296;</r>",
    ] {
      #expect(throws: XML.Error.self) { try parse(xml) }
    }
  }

  @Test("accepts representative XML Name grammar boundaries")
  internal func nameBoundaryAcceptance() throws {
    for xml in [
      "<a/>",
      "<_a-1.2/>",
      "<\u{03b1}/>",
      "<a\u{0301}/>",
      "<\u{10000}n/>",
    ] {
      try parse(xml)
    }
  }

  @Test("rejects invalid XML Name starts")
  internal func nameBoundaryRejection() {
    for xml in [
      "<1a/>",
      "<.a/>",
      "<\u{0301}a/>",
      "<-a/>",
    ] {
      #expect(throws: XML.Error.self) { try parse(xml) }
    }
  }

  @Test("rejects additional document-structure edge cases")
  internal func documentStructureRejectionMatrix() {
    for xml in [
      "</r>",
      "<r>",
      "<!DOCTYPE r><!DOCTYPE r><r/>",
      "<r/><!DOCTYPE r>",
      "<r/>tail",
    ] {
      #expect(throws: XML.Error.self) { try parse(xml) }
    }
  }

  @Test("internal subset general entities should expand in element content",
        .disabled("DTD internal subset support is not implemented yet"))
  internal func generalEntityExpansionFromInternalSubset() throws {
    try withDocument("<!DOCTYPE r [<!ENTITY e 'ok'>]><r>&e;</r>") { document in
      let root = try topLevelElement(in: document)
      guard let first = children(of: root, in: document).first,
            let value = nodeValue(of: first, in: document) else {
        throw DOMFixtureError.missingNodeValue
      }
      #expect(value == "ok")
    }
  }

  @Test("internal subset should support parameter entities inside declarations",
        .disabled("DTD internal subset support is not implemented yet"))
  internal func parameterEntitiesInInternalSubset() throws {
    try withDocument(
      """
      <!DOCTYPE r [
        <!ENTITY % pe "ok">
        <!ENTITY e "%pe;">
      ]>
      <r>&e;</r>
      """
    ) { document in
      let root = try topLevelElement(in: document)
      guard let first = children(of: root, in: document).first,
            let value = nodeValue(of: first, in: document) else {
        throw DOMFixtureError.missingNodeValue
      }
      #expect(value == "ok")
    }
  }

  @Test("internal subset default attributes should be materialized on elements",
        .disabled("DTD internal subset support is not implemented yet"))
  internal func internalSubsetDefaultAttributes() throws {
    try withDocument(
      """
      <!DOCTYPE r [
        <!ATTLIST r mode CDATA "safe">
      ]>
      <r/>
      """
    ) { document in
      let root = try topLevelElement(in: document)
      let attrs = attributes(of: root, in: document)
      #expect(attrs["mode"]?.value == "safe")
      #expect(attrs["mode"]?.namespace == nil)
    }
  }

  @Test("internal subset entities should expand inside attribute values",
        .disabled("DTD internal subset support is not implemented yet"))
  internal func internalSubsetEntityInAttributeValue() throws {
    try withDocument(
      """
      <!DOCTYPE r [
        <!ENTITY e "safe">
      ]>
      <r mode="&e;"/>
      """
    ) { document in
      let root = try topLevelElement(in: document)
      let attrs = attributes(of: root, in: document)
      #expect(attrs["mode"]?.value == "safe")
    }
  }
}
