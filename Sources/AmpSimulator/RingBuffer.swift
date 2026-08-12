import Foundation
import os

/// Single-producer/single-consumer float ring buffer used to bridge the input
/// tap's callback (driven by the input device) and the output source node's
/// render block (driven by the output device). A short os_unfair_lock guards
/// each write/read call; contention windows are on the order of microseconds,
/// which is an accepted pragmatic tradeoff for this MVP rather than a fully
/// lock-free structure.
final class FloatRingBuffer {
  private var buffer: [Float]
  private let capacity: Int
  private var writeIndex = 0
  private var readIndex = 0
  private var storedCount = 0
  private var lock = os_unfair_lock()

  init(capacity: Int) {
    self.capacity = max(1, capacity)
    self.buffer = [Float](repeating: 0, count: self.capacity)
  }

  /// Copies `count` samples in. If the buffer is full, oldest samples are
  /// overwritten (favors keeping up with the input device over ever blocking).
  func write(_ samples: UnsafePointer<Float>, count: Int) {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    for i in 0..<count {
      buffer[writeIndex] = samples[i]
      writeIndex = (writeIndex + 1) % capacity
      if storedCount < capacity {
        storedCount += 1
      } else {
        readIndex = (readIndex + 1) % capacity
      }
    }
  }

  /// Copies up to `count` samples out, zero-filling any shortfall (underrun).
  func read(into output: UnsafeMutablePointer<Float>, count: Int) {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    let available = min(count, storedCount)
    for i in 0..<available {
      output[i] = buffer[readIndex]
      readIndex = (readIndex + 1) % capacity
    }
    storedCount -= available
    if available < count {
      for i in available..<count {
        output[i] = 0
      }
    }
  }
}
