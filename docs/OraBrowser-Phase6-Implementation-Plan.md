# Phase 6 Design Specification: Persistence, Recovery, and Observability

Tài liệu này đặc tả chi tiết kiến trúc, thiết kế và kế hoạch triển khai cho **Phase 6: Persistence, Recovery, and Observability**.

Mục tiêu của Phase 6 là làm cho hệ thống Catalog Workspace trở nên cực kỳ bền bỉ (resilient), có khả năng tự phục hồi khi có sự cố (crash, sleep/wake, thay đổi màn hình) và cung cấp các công cụ quan sát (observability) để chẩn đoán hiệu suất và đo lường lượng bộ nhớ RAM đã tiết kiệm được.

---

## 1. Kiến trúc Tự Phục hồi & Giảm tải (Recovery & Power Management)

```text
       macOS System Events (Sleep/Wake/Display Change)
                            │
                            ▼
                  SystemNotificationMonitor
                            │
            (willSleep / didWake / didChangeScreen)
                            ▼
                  CatalogWindowManager ◄──────────► ResourceManager
                            │
            (Suspend / Evict All / Resume)
```

### 1.1 Quản lý trạng thái Sleep / Wake (Nguồn điện)
Khi macOS chuẩn bị đi vào chế độ ngủ (Sleep):
- Lưu trữ tất cả các thay đổi URL/Layout chưa được lưu vào SwiftData.
- Đưa tất cả các Catalog nền về trạng thái L4 (Deep Hibernation) hoặc L3 (Snapshotted) ngay lập tức để giảm tải điện năng.
- Tạm dừng timer chu kỳ của `ResourceManager`.
Khi macOS thức dậy (Wake):
- Khôi phục timer chu kỳ của `ResourceManager`.
- Tự động tải lại trang hoạt động chính (L0 Active).

### 1.2 Crash Backoff (Chống lặp vòng vô hạn)
- Nếu Web Content Process (`WKWebView`) bị đổ vỡ (crashed) liên tục:
  - Ghi nhận số lần crash của trang (`crashCount`) trong một khoảng thời gian (10 giây).
  - Nếu `crashCount` > 3: Dừng tự động nạp lại (reload), hiển thị lớp phủ báo lỗi (`.crashed` state) kèm nút "Reload" thủ công để tránh quá tải CPU/RAM của hệ thống.
  - Chuyển LifecycleState sang `.crashed`.

---

## 2. Thiết kế các cấu phần mới

### 2.1 [SystemNotificationMonitor.swift](file:///Users/trungkientn/Dev2/MacOS/OraBrowser/ora/Core/Utilities/SystemNotificationMonitor.swift)
```swift
import Cocoa
import OSLog

@MainActor
final class SystemNotificationMonitor {
    private let logger = Logger(subsystem: "com.orabrowser.app", category: "SystemNotificationMonitor")
    
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    var onDisplayChange: (() -> Void)?

    init() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleDisplayChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleSleep() {
        logger.info("System preparing to sleep")
        onSleep?()
    }

    @objc private func handleWake() {
        logger.info("System woke up")
        onWake?()
    }

    @objc private func handleDisplayChange() {
        logger.info("Display configuration changed")
        onDisplayChange?()
    }
}
```

### 2.2 Crash Tracker & Backoff trong [CatalogWindowManager.swift](file:///Users/trungkientn/Dev2/MacOS/OraBrowser/ora/Features/Catalog/Windowing/CatalogWindowManager.swift)
Chúng ta sẽ bổ sung struct `CrashHistory` và theo dõi trực tiếp trong Manager:
```swift
private struct CrashHistory {
    var timestamps: [Date] = []
    
    mutating func recordCrash(within window: TimeInterval = 10.0) -> Bool {
        let now = Date()
        timestamps.append(now)
        timestamps = timestamps.filter { now.timeIntervalSince($0) <= window }
        return timestamps.count > 3 // Trả về true nếu bị crash quá 3 lần trong 10s
    }
}
```

---

## 3. Observability & Diagnostics

Chúng ta bổ sung thêm hệ thống ghi nhận **Metrics** để tính toán RAM đã tiết kiệm được:
- Mỗi Catalog L4/L5 tiết kiệm được khoảng `estimatedCost` (mặc định 150MB - 300MB RAM).
- Trình bày thông tin chẩn đoán qua API để phục vụ cho debug hoặc hiển thị panel chẩn đoán.

---

## 4. Kế hoạch Kiểm thử (Verification Plan)

### Kiểm thử Tự động (Automated Tests)
- Viết `CrashBackoffTests.swift` mô phỏng việc `PageLease` bị crash liên tục 4 lần để đảm bảo hệ thống chuyển trạng thái `.crashed` và ngắt reload vòng lặp.
- Viết `SystemNotificationTests.swift` mô phỏng sự kiện Sleep để kiểm tra xem `ResourceManager` có tạm dừng và đưa các trang nền vào trạng thái tối ưu điện năng hay không.

### Kiểm thử Thủ công (Manual Verification)
- Ép crash một trang web bằng cách dùng Activity Monitor giết tiến trình WebContent (hoặc điều hướng đến trang `chrome://crash` nếu có).
- Xác minh xem trang web có tự động phục hồi trong 3 lần đầu và dừng lại báo lỗi ở lần thứ 4 hay không.
