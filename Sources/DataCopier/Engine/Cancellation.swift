import Foundation

/// 线程安全的取消标志。
///
/// 拷贝过程中每读写一个数据块都会检查一次，因此取消的响应延迟约等于一个缓冲区的大小
/// （默认 4 MB，通常在毫秒级）。
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var handlers: [UUID: () -> Void] = [:]

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        let pending = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        // 在锁外回调，避免处理器内部再触碰本对象时死锁。
        for handler in pending { handler() }
    }

    /// 注册取消回调，返回用于注销的令牌。
    ///
    /// 长耗时且不可中断的外部操作（例如等待 FFmpeg 子进程）依赖它获得即时响应：
    /// 只看标志位的话，必须等进程自己结束才有机会检测到取消。
    /// 若注册时已处于取消状态，回调会被立即执行一次。
    func addHandler(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        if flag {
            lock.unlock()
            handler()
            return token
        }
        handlers[token] = handler
        lock.unlock()
        return token
    }

    /// 注销取消回调。操作正常结束后必须调用，否则回调会持续持有其捕获的对象。
    func removeHandler(_ token: UUID) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    func check() throws {
        if isCancelled { throw OperationCancelled() }
    }
}

struct OperationCancelled: LocalizedError {
    var errorDescription: String? { "操作已取消" }
}

/// 线程安全的递增计数器，用于向工作线程分发任务索引。
final class WorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

/// 线程安全的结果收集器，用于并发映射时按下标写回结果。
///
/// 并发映射无法直接写入同一个数组（多线程同时写入同一存储属于数据竞争），
/// 这里以加锁字典承接：写入彼此独立，读取统一发生在全部工作线程结束之后。
final class ConcurrentResults<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int: Value] = [:]

    func set(_ value: Value, at index: Int) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    func value(at index: Int) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage[index]
    }
}
