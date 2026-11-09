import Foundation

/// 滑动窗口吞吐计。
///
/// 直接使用「累计字节 / 总耗时」得到的平均速度在长任务中反应迟钝，
/// 这里保留最近若干秒的采样点，用窗口内的增量推算瞬时速度，同时记录峰值。
final class SpeedMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(time: Date, bytes: Int64)] = []
    private let window: TimeInterval
    private var peak: Double = 0
    private var startTime: Date?

    init(window: TimeInterval = 5) {
        self.window = window
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        peak = 0
        startTime = nil
        lock.unlock()
    }

    func record(cumulativeBytes: Int64) {
        lock.lock()
        let now = Date()
        if startTime == nil { startTime = now }
        samples.append((now, cumulativeBytes))

        let cutoff = now.addingTimeInterval(-window * 2)
        while let first = samples.first, first.time < cutoff {
            samples.removeFirst()
        }

        // 以「自起始以来的平均吞吐」作为峰值下界。短任务可能在滑动窗口产生第一个
        // 有效采样之前就结束，若只依赖窗口采样，峰值会错误地停在 0。
        if let start = startTime {
            let elapsed = now.timeIntervalSince(start)
            if elapsed > 0.01 {
                let average = Double(cumulativeBytes) / elapsed
                if average > peak { peak = average }
            }
        }
        lock.unlock()
    }

    /// 窗口内的平均速度（字节/秒）。
    func currentSpeed() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let last = samples.last else { return 0 }
        let windowStart = last.time.addingTimeInterval(-window)
        guard let base = samples.first(where: { $0.time >= windowStart }) ?? samples.first else {
            return 0
        }
        let interval = last.time.timeIntervalSince(base.time)
        guard interval > 0.05 else { return 0 }
        let delta = last.bytes - base.bytes
        guard delta > 0 else { return 0 }
        let speed = Double(delta) / interval
        if speed > peak { peak = speed }
        return speed
    }

    var peakSpeed: Double {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}
