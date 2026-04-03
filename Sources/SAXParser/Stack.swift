// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>
// SPDX-License-Identifier: BSD-3-Clause

internal struct Stack<Element>: ~Copyable {
  private var storage: UnsafeMutablePointer<Element>?
  public private(set) var count: Int = 0
  public private(set) var capacity: Int = 0

  public var isEmpty: Bool {
    @inline(__always) get { count == 0 }
  }

  internal var last: Element? {
    @inline(__always) get {
      guard count > 0 else { return nil }
      return storage.unsafelyUnwrapped[count - 1]
    }
  }

  public init() {}

  deinit {
    if let storage = storage {
      storage.deinitialize(count: count)
      storage.deallocate()
    }
  }

  @inline(__always)
  internal mutating func push(_ element: Element) {
    if count == capacity { grow() }
    storage.unsafelyUnwrapped.advanced(by: count).initialize(to: element)
    count += 1
  }

  @inline(__always)
  @discardableResult
  internal mutating func pop() -> Element? {
    guard count > 0 else { return nil }
    count -= 1
    return storage.unsafelyUnwrapped.advanced(by: count).move()
  }

  @_effects(notEscapingself.value**)
  private mutating func grow() {
    let capacity = max(self.capacity * 2, 16)
    let buffer = UnsafeMutablePointer<Element>.allocate(capacity: capacity)
    if let storage {
      buffer.moveInitialize(from: storage, count: count)
      storage.deallocate()
    }
    storage = buffer
    self.capacity = capacity
  }
}
