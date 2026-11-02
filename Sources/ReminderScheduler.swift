import AppKit

/// 每到整点（xx:00:00）触发一次喝水提醒。
///
/// 以前是 1 秒轮询对时（常驻 1Hz 唤醒），现在只在下一个整点挂一个单次 Timer，
/// 触发后重新排到下一个整点；系统时间 / 时区变化时重算。
/// 睡眠期间错过的整点不补发（唤醒后如果还在整点 120 秒内，会补一次）。
final class ReminderScheduler: NSObject {
    var onFire: (() -> Void)?
    var quietHoursEnabled = false
    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            reschedule()
        }
    }

    private var timer: Timer?
    private var lastFiredKey: String?
    private var observers: [NSObjectProtocol] = []
    private let calendar = Calendar.current

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSSystemClockDidChange,
                                           object: nil, queue: .main) { [weak self] _ in
            self?.reschedule()
        })
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange,
                                           object: nil, queue: .main) { [weak self] _ in
            self?.reschedule()
        })
        reschedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    deinit { stop() }

    /// 排到下一个整点。
    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        let now = Date()
        guard let next = calendar.nextDate(after: now,
                                           matching: DateComponents(minute: 0, second: 0),
                                           matchingPolicy: .nextTime) else { return }
        let scheduled = Timer(fireAt: next,
                              interval: 0,
                              target: self,
                              selector: #selector(fireTimer),
                              userInfo: nil,
                              repeats: false)
        scheduled.tolerance = 1.0
        RunLoop.main.add(scheduled, forMode: .common)
        timer = scheduled
    }

    @objc private func fireTimer() {
        timer = nil
        check(now: Date())
        reschedule()
    }

    /// 抽出来方便测试：判断当前时刻是否该触发。
    func check(now: Date) {
        guard isEnabled else { return }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        guard let hour = parts.hour, let minute = parts.minute, let second = parts.second else { return }

        let secondsIntoHour = minute * 60 + second
        guard secondsIntoHour <= 120 else { return }

        let key = String(format: "%04d-%02d-%02d-%02d",
                         parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, hour)
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
