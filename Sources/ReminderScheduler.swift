import Foundation

/// 每到整点（xx:00:00）触发一次喝水提醒。
/// 用 1 秒轮询而不是一次性 Timer，睡眠唤醒、改系统时间后依然可靠。
final class ReminderScheduler {
    var onFire: (() -> Void)?
    var isEnabled: Bool = true
    var quietHoursEnabled: Bool = false
    private var timer: Timer?
    private var lastFiredKey: String?
    private let calendar = Calendar.current

    func start() {
        stop()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        check(now: Date())
    }

    func check(now: Date) {
        guard isEnabled else { return }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard let hour = c.hour, let minute = c.minute else { return }
        guard minute == 0 else { return }

        let key = String(format: "%04d-%02d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, hour)
        guard key != lastFiredKey else { return }
        lastFiredKey = key

        if quietHoursEnabled && isQuiet(hour: hour) { return }
        onFire?()
    }

    func isQuiet(hour: Int) -> Bool {
        // 23:00–07:00
        hour >= 23 || hour < 7
    }
}
