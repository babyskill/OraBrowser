# Phase 7 Design Specification: Hardening and Rollout

Tài liệu này đặc tả chi tiết kiến trúc và kế hoạch triển khai cho **Phase 7: Hardening and Rollout**.

Mục tiêu của Phase 7 là gia cố tính ổn định của hệ thống trước khi phát hành chính thức, thiết lập đầy đủ các Feature Flags quản lý từ xa/UserDefaults để kiểm soát quá trình rollout (phát hành từng phần) từ 5% -> 25% -> 100%, và xây dựng một kịch bản kiểm thử chịu tải (Stress/Soak testing) để phát hiện rò rỉ tài nguyên (leak) và đua luồng (race conditions).

---

## 1. Hệ thống Feature Flags

Chúng ta sẽ điều khiển toàn bộ tính năng mới của Catalog Runtime thông qua các Feature Flags trong `ApplicationGraph`:
1. **`catalogRuntime`**: Bật/tắt toàn bộ kiến trúc Catalog và ResourceManager (mặc định: `true`).
2. **`windowPool`**: Bật/tắt bể chứa cửa sổ AppKit (mặc định: `true`).
3. **`deepHibernation`**: Bật/tắt L4 Deep Hibernation và L5 Recycle (mặc định: `true`). Nếu tắt, hệ thống chỉ dừng lại ở mức L3 Snapshotted.
4. **`aiActivityLease`**: Bật/tắt tính năng giữ lease bảo vệ hoạt động AI (mặc định: `true`).

---

## 2. Đặc tả thay đổi mã nguồn

### 2.1 Cập nhật `ApplicationGraph.swift`
Định nghĩa các cờ điều hướng và tiêm các cờ này vào `ResourceManager`:
```swift
var catalogRuntimeEnabled: Bool {
    featureFlag(named: "catalogRuntime", defaultValue: true)
}
var deepHibernationEnabled: Bool {
    featureFlag(named: "deepHibernation", defaultValue: true)
}
var aiActivityLeaseEnabled: Bool {
    featureFlag(named: "aiActivityLease", defaultValue: true)
}
```

### 2.2 Cập nhật `ResourceManager.swift`
- Nhận cờ `deepHibernationEnabled` và `aiActivityLeaseEnabled` qua bộ khởi tạo.
- Trong `evaluateAllStates()`:
  - Nếu `aiActivityLeaseEnabled == true`, kiểm tra `hasActiveLeases`. Nếu không, bỏ qua kiểm tra lease.
  - Khi tính toán `nextLevel`, nếu `deepHibernationEnabled == false`, giới hạn cấp độ cao nhất là `.l3Snapshotted` (tức là không bao giờ hạ cấp xuống L4 hoặc L5).

---

## 3. Kiểm thử chịu tải & Gia cố (Stress/Soak Testing)

Chúng ta sẽ viết bộ kiểm thử chịu tải để giả lập chu kỳ hoạt động lớn:
- Thực hiện mở/đóng/chuyển đổi 100 lần liên tục giữa các catalog trên môi trường chạy test.
- Xác nhận các cửa sổ được trả về pool hoàn hảo, không có ngoại lệ bộ nhớ hoặc treo luồng chính (Main Thread Hang).

---

## 4. Kế hoạch Kiểm thử (Verification Plan)

### Kiểm thử Tự động (Automated Tests)
- Tạo mới tệp `HardeningTests.swift` trong target `oraTests` để thực thi soak test 100 chu kỳ.
- Viết các test cases kiểm chứng khi Feature Flags `deepHibernation` hoặc `aiActivityLease` bị tắt, hệ thống sẽ điều chỉnh hành vi chính xác (không hạ cấp sâu L4/L5, không check lease).

### Kiểm thử Thống kê
- Toàn bộ 38 tests phải vượt qua thành công.
