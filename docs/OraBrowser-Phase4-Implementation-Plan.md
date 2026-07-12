# Phase 4 Design Specification: ResourceManager and L0–L5 Hibernation Policy

Tài liệu này đặc tả chi tiết kiến trúc, thiết kế và kế hoạch triển khai cho **Phase 4: ResourceManager và L0–L5 Hibernation Policy**. 

Mục tiêu cốt lõi của Phase 4 là đưa ra bộ não điều phối tài nguyên toàn cục — `ResourceManager`. Thay vì để mỗi cửa sổ tự quản lý tài nguyên của mình một cách cục bộ, `ResourceManager` sẽ giám sát toàn bộ hoạt động của ứng dụng, áp dụng ngân sách (budget) tài nguyên thích ứng với cấu hình RAM vật lý và mức độ Memory Pressure của hệ thống để đưa ra quyết định ngủ đông (hibernation) hoặc thu hồi (eviction/recycling) tối ưu nhất.

---

## 1. Kiến trúc Tổng quan (High-Level Architecture)

```text
  System Memory/Thermal Signals
              │
              ▼
    ┌──────────────────┐
    │ MemoryPressure   │
    │   Monitor        │
    └─────────┬────────┘
              │
              │ (Pressure Level: Normal/Warning/Critical)
              ▼
    ┌──────────────────┐        ┌──────────────────┐
    │                  │        │                  │
    │  ResourceManager ◄────────┤  CatalogRegistry │
    │     (Actor)      │        │  (Source of Truth│
    │                  ├────────►                  │
    └────┬───────────┬─┘        └──────────────────┘
         │           │
         │           │ (Commands: Acquire/Hibernate/Recycle/Wake)
         ▼           ▼
   ┌───────────┐ ┌───────────┐
   │WindowPool │ │WebRuntime │
   └───────────┘ └───────────┘
```

`ResourceManager` hoạt động như một Actor cô lập để đảm bảo an toàn luồng dữ liệu ngoài Main Thread, phối hợp với ba cấu phần chính:
1. **`PressureMonitor`**: Lắng nghe thay đổi về Memory Pressure từ hệ điều hành macOS.
2. **`ResourcePolicyEngine`**: Chứa thuật toán tính điểm trục xuất (Eviction Score) và chính sách hysteresis chống dao động trạng thái liên tục.
3. **`SnapshotStore`**: Quản lý bộ đệm đĩa cho các ảnh chụp nhanh tĩnh (PNG) của Catalog để khôi phục tức thời.

---

## 2. Đặc tả Hibernation Levels (L0–L5)

Hệ thống quản lý tài nguyên thông qua 6 mức độ từ hoạt động hoàn toàn đến giải phóng triệt để:

| Trạng thái | Điều kiện kích hoạt | Tài nguyên nắm giữ | Hành động thực hiện |
| :--- | :--- | :--- | :--- |
| **L0 Active** | Catalog đang có Focus hoặc tương tác < 2 giây. | Shell Window + Live Page | Hoạt động bình thường, render QoS cao nhất. |
| **L1 Grace** | Catalog bị mất Focus hoặc bị che khuất (Occluded). | Shell Window + Live Page | Ghi nhận mốc thời gian hoạt động cuối, bắt đầu đếm ngược. |
| **L2 Throttled** | Idle quá Grace Period (mặc định 30–90 giây). | Shell Window + Live Page | Ngắt các tiến trình phụ của app, dừng timer của UI nếu có. |
| **L3 Snapshotted** | Idle lâu hơn L2 hoặc có cảnh báo Memory Warning. | Shell Window + Live Page + Snapshot File | Tiến hành chụp lại ảnh tĩnh của Catalog thông qua WKWebView, lưu đĩa. |
| **L4 Deep Hibernation** | Idle lâu (3–10 phút) hoặc Memory Warning tăng. | Shell Window + Snapshot File; **Giải phóng Page** | Detach trang khỏi shell, teardown và giải phóng `PageLease` về `WebRuntime`. |
| **L5 Recycled** | RAM Critical hoặc Pool Overflow. | Metadata lưu SwiftData + Snapshot File | Giải phóng cả `PageLease` lẫn `WindowLease` (Shell trả về `WindowPool` dưới dạng cold). |

---

## 3. Thuật toán Điểm Trục Xuất (Eviction Scoring)

Khi có cảnh báo bộ bộ nhớ hoặc vượt quá ngân sách cửa sổ nóng, `ResourceManager` sẽ tính điểm trục xuất cho các catalog không hoạt động. Catalog có điểm **cao nhất** sẽ bị ưu tiên chuyển sang level sâu hơn (L4/L5):

$$\text{Score} = w_{\text{age}} \cdot \text{Age} + w_{\text{occlusion}} \cdot \text{OccludedTime} + \text{EstimatedCost} + \text{PoolPressure} - w_{\text{pinned}} \cdot \text{IsPinned} - \text{ActivityProtection}$$

Trong đó:
- **`Age`**: Thời gian kể từ lần tương tác cuối.
- **`OccludedTime`**: Thời gian bị che khuất hoàn toàn.
- **`EstimatedCost`**: Ước tính dung lượng RAM tiêu thụ (dựa trên loại trang hoặc tần suất sử dụng).
- **`IsPinned`**: Trạng thái Ghim của Catalog (ngăn không cho trục xuất).
- **`ActivityProtection`**: Bảo vệ đặc biệt (ví dụ: đang tải xuống tệp tin, đang phát âm thanh, hoặc đang thực hiện stream AI).

---

## 4. Thiết kế các Tệp mã nguồn mới

Chúng ta sẽ đặt toàn bộ mã nguồn của hệ thống quản lý tài nguyên này dưới thư mục mới: [ora/Features/Catalog/ResourceManager/](file:///Users/trungkientn/Dev2/MacOS/OraBrowser/ora/Features/Catalog/ResourceManager/).

### 4.1 [ResourceManager.swift](file:///Users/trungkientn/Dev2/MacOS/OraBrowser/ora/Features/Catalog/ResourceManager/ResourceManager.swift)
```swift
import Foundation
import OSLog

public enum HibernationLevel: Int, Codable, Sendable {
    case l0Active = 0
    case l1Grace = 1
    case l2Throttled = 2
    case l3Snapshotted = 3
    case l4DeepHibernation = 4
    case l5Recycled = 5
}

public actor ResourceManager {
    // Theo dõi trạng thái chi tiết của từng Catalog
    public struct CatalogResourceState: Sendable {
        let catalogID: CatalogID
        var level: HibernationLevel
        var lastInteractionAt: Date
        var isOccluded: Bool
        var isKey: Bool
        var isPinned: Bool
        var hasActiveActivity: Bool // Download, media...
        var estimatedCost: Double
        var generation: Int
    }
    
    // ...
}
```

### 4.2 [ResourcePolicyEngine.swift](file:///Users/trungkientn/Dev2/MacOS/OraBrowser/ora/Features/Catalog/ResourceManager/ResourcePolicyEngine.swift)
- Quản lý 3 cấu hình ngân sách: Saver (8GB RAM), Balanced (16GB RAM) và Performance (32GB+ RAM).
- Tính toán điểm trục xuất dựa trên các thuộc tính của `CatalogResourceState`.

### 4.3 [PressureMonitor.swift](file:///Users/trungkientn/Dev2/MacOS/OraBrowser/ora/Features/Catalog/ResourceManager/PressureMonitor.swift)
- Đăng ký lắng nghe tín hiệu memory pressure của macOS bằng `DispatchSource.makeMemoryPressureSource`.
- Chuyển giao các sự kiện `normal`, `warning`, `critical` về `ResourceManager` để hạ thấp hoặc tăng tốc độ co dãn pool.

### 4.4 [SnapshotStore.swift](file:///Users/trungkientn/Dev2/MacOS/OraBrowser/ora/Features/Catalog/ResourceManager/SnapshotStore.swift)
- Đảm nhận lưu trữ ảnh chụp PNG vật lý của WebView vào thư mục `Application Support/CatalogWorkspace/snapshots/` bằng cơ chế ghi đè nguyên tử (atomic replace) và dọn dẹp theo thời gian hết hạn (TTL).

---

## 5. Tích hợp và Đồng bộ hóa

1. **`CatalogWindowManager`**:
   - Khi nhận các sự kiện từ cửa sổ như `didBecomeKey`, `didResignKey`, `didMoveOrResize`, và sự kiện thay đổi occlusion mới, `CatalogWindowManager` sẽ đẩy các sự kiện này vào `ResourceManager`.
   - Các hành động đóng, thu hồi, hibernate hoặc wake sẽ được điều phối gián tiếp qua quyết định của `ResourceManager`.
2. **`ApplicationGraph`**:
   - Khởi tạo `ResourceManager`, `PressureMonitor`, và `SnapshotStore` lúc khởi động ứng dụng và liên kết chúng.

---

## 6. Kế hoạch Kiểm thử (Verification Plan)

### Kiểm thử Tự động (Automated Tests)
- Tạo mới tệp kiểm thử `ResourceManagerTests.swift` trong target `oraTests` để mô phỏng sự kiện memory pressure và chuyển đổi trạng thái L0-L5.
- Xác nhận các catalog bị ghim (pinned) hoặc đang tải xuống sẽ không bao giờ bị trục xuất xuống mức L4/L5 ngay cả khi bộ nhớ cảnh báo Critical.

### Kiểm thử Thủ công (Manual Verification)
- Sử dụng Terminal để ép hệ thống rơi vào trạng thái Memory Pressure Warning bằng lệnh `memory_pressure` của macOS và kiểm tra xem các catalog nền có tự động chụp snapshot rồi unload trang web hay không.
