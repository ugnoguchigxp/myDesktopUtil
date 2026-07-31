import Foundation

public struct BoundedIdentifierSet: Sendable {
  public let capacity: Int
  private var order: [String]
  private var values: Set<String>

  public init(capacity: Int, existing: [String] = []) {
    self.capacity = max(1, capacity)
    var newestFirst: [String] = []
    var uniqueValues: Set<String> = []
    for value in existing.reversed() where uniqueValues.insert(value).inserted {
      newestFirst.append(value)
      if newestFirst.count == self.capacity {
        break
      }
    }
    order = Array(newestFirst.reversed())
    values = uniqueValues
  }

  public var count: Int {
    values.count
  }

  public var allValues: [String] {
    order
  }

  public func contains(_ value: String) -> Bool {
    values.contains(value)
  }

  @discardableResult
  public mutating func insert(_ value: String) -> Bool {
    guard values.insert(value).inserted else {
      return false
    }
    order.append(value)
    if order.count > capacity {
      let removed = order.removeFirst()
      values.remove(removed)
    }
    return true
  }

  @discardableResult
  public mutating func remove(_ value: String) -> Bool {
    guard values.remove(value) != nil else {
      return false
    }
    order.removeAll { $0 == value }
    return true
  }
}

public struct BoundedFIFO<Element: Sendable>: Sendable {
  public let capacity: Int
  private var storage: [Element] = []

  public init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  public var count: Int {
    storage.count
  }

  @discardableResult
  public mutating func append(_ value: Element) -> Bool {
    guard storage.count < capacity else {
      return false
    }
    storage.append(value)
    return true
  }

  public mutating func popFirst() -> Element? {
    guard !storage.isEmpty else {
      return nil
    }
    return storage.removeFirst()
  }
}
