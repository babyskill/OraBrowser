# Phase 5 Design Specification: AI Activity Protection

Tài liệu này đặc tả chi tiết kiến trúc, thiết kế và kế hoạch triển khai cho **Phase 5: AI Activity Protection**. 

Mục tiêu cốt lõi của Phase 5 là bảo vệ trải nghiệm của người dùng khi sử dụng các dịch vụ AI liên tục (như ChatGPT, Gemini) hoặc các hoạt động nền quan trọng (tải tệp, phát nhạc). Hệ thống sẽ ngăn chặn việc đưa các Catalog này vào trạng thái ngủ đông (L3/L4/L5) hoặc hạn chế tài nguyên (L2 Throttled) khi chúng đang thực hiện truyền phát dữ liệu (streaming output), tải tệp tin lên/xuống (file upload/download), hoặc đàm thoại giọng nói.

---

## 1. Kiến trúc Bảo vệ (Activity Lease System)

Để bảo vệ các Catalog đang hoạt động tích cực mà không có tiêu điểm (focus), chúng ta giới thiệu khái niệm **Activity Lease** (Hợp đồng thuê hoạt động). Một Catalog sở hữu ít nhất một hợp đồng thuê hợp lệ sẽ được bảo vệ tuyệt đối khỏi các chính sách thu hồi tài nguyên của `ResourceManager`.

```text
                  WKWebView (ChatGPT / Gemini)
                              │
               (DOM mutations / State changes)
                              ▼
                        UserScripts
                              │
            (postMessage: oraAIActivityHandler)
                              ▼
                  AIActivityMessageHandler (Swift)
                              │
                              ▼
                    CatalogWindowManager
                              │
         (acquireLease / releaseLease / heartbeat)
                              ▼
                     ResourceManager (Actor)
                              │
               (Checks active leases during L0-L5)
                              ▼
                        Eviction Bypass
```

### 1.1 Loại hình Hoạt động cần Bảo vệ (Lease Types)
1. **`.aiGeneration`**: Khi mô hình AI đang sinh nội dung (streaming text/audio).
2. **`.fileTransfer`**: Khi đang tải tệp tin lên (upload) hoặc tải xuống (download).
3. **`.mediaPlayback`**: Khi đang phát nhạc/video hoặc thoại giọng nói (WebRTC).
4. **`.userInteraction`**: Bảo vệ ngắn hạn ngay sau khi người dùng click/gõ phím ở Catalog nền.

---

## 2. Đặc tả Cấu trúc Dữ liệu mới

### 2.1 [ActivityLease.swift](file:///Users/trungkientn/Dev2/MacOS/OraBrowser/ora/Features/Catalog/ResourceManager/ActivityLease.swift)
```swift
import Foundation

public enum LeaseType: String, Codable, Sendable {
    case aiGeneration
    case fileTransfer
    case mediaPlayback
    case userInteraction
}

public struct ActivityLease: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let type: LeaseType
    public let expiresAt: Date
    public let metadata: [String: String]

    public var isExpired: Bool {
        expiresAt < Date()
    }

    public init(id: UUID = UUID(), type: LeaseType, expiresAt: Date, metadata: [String: String] = [:]) {
        self.id = id
        self.type = type
        self.expiresAt = expiresAt
        self.metadata = metadata
    }
}
```

---

## 3. Các Domain Adapter bằng JavaScript (UserScripts)

Chúng ta sẽ tạo các mã kịch bản JavaScript để tiêm (inject) vào WebView của các dịch vụ AI để lắng nghe trạng thái hoạt động:

### 3.1 ChatGPT Adapter (`ChatGPTAdapter.js`)
- Lắng nghe trạng thái của nút **Stop Generating** hoặc sự thay đổi của nút gửi tin nhắn (khi đang sinh, nút gửi tin nhắn sẽ biến thành biểu tượng dừng).
- Phát hiện phần tử phản hồi đang sinh chữ (`.result-streaming`, `.markdown` đang cập nhật).
- Gửi tin nhắn qua WebKit handler: `window.webkit.messageHandlers.oraAIActivity.postMessage({ status: "started", type: "aiGeneration" })` khi bắt đầu sinh và `{ status: "stopped", type: "aiGeneration" }` khi kết thúc.

### 3.2 Gemini Adapter (`GeminiAdapter.js`)
- Phát hiện trạng thái sinh nội dung của Gemini (phần tử `.assistant-message-response` hoặc sự xuất hiện của nút dừng).
- Gửi sự kiện tương tự về Swift host.

### 3.3 Media/Video Adapter chung
- Lắng nghe sự kiện `play` và `pause` của mọi thẻ `<video>` hoặc `<audio>` trong trang để duy trì lease `.mediaPlayback`.

---

## 4. Tích hợp ResourceManager và Message Handler

### 4.1 Cập nhật `ResourceManager`
Chúng ta sẽ bổ sung các hàm quản lý lease trực tiếp vào `ResourceManager`:
```swift
public actor ResourceManager {
    // ...
    private var leases: [CatalogID: Set<ActivityLease>] = [:]

    public func acquireLease(for catalogID: CatalogID, type: LeaseType, duration: TimeInterval, metadata: [String: String] = [:]) {
        let expiration = Date().addingTimeInterval(duration)
        let lease = ActivityLease(type: type, expiresAt: expiration, metadata: metadata)
        
        var current = leases[catalogID] ?? []
        // Loại bỏ lease cũ cùng loại để ghi đè thời hạn
        current = current.filter { $0.type != type }
        current.insert(lease)
        leases[catalogID] = current
        
        // Cập nhật trạng thái hasActiveActivity trên CatalogResourceState
        updateActivityState(for: catalogID)
    }

    public func releaseLease(for catalogID: CatalogID, type: LeaseType) {
        guard var current = leases[catalogID] else { return }
        current = current.filter { $0.type != type }
        leases[catalogID] = current
        updateActivityState(for: catalogID)
    }

    private func updateActivityState(for catalogID: CatalogID) {
        let active = hasActiveLeases(for: catalogID)
        setActiveActivity(active, for: catalogID)
    }

    public func hasActiveLeases(for catalogID: CatalogID) -> Bool {
        guard let current = leases[catalogID] else { return false }
        // Loại bỏ các lease đã hết hạn
        let valid = current.filter { !$0.isExpired }
        leases[catalogID] = valid.isEmpty ? nil : valid
        return !valid.isEmpty
    }
}
```

### 4.2 Triển khai WKScriptMessageHandler
```swift
final class AIActivityMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    weak var delegate: AIActivityDelegate?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "oraAIActivity",
              let body = message.body as? [String: Any],
              let status = body["status"] as? String,
              let typeStr = body["type"] as? String,
              let type = LeaseType(rawValue: typeStr) else { return }

        delegate?.didReceiveActivityUpdate(type: type, isStarting: status == "started")
    }
}
```

---

## 5. Kế hoạch Kiểm thử (Verification Plan)

### Kiểm thử Tự động (Automated Tests)
- Thêm `ActivityLeaseTests.swift` để kiểm tra việc xin giữ lease, tự động hết hạn (expiry), và xác nhận `ResourceManager` không chuyển hạ cấp L3/L4/L5 đối với catalog có lease còn hiệu lực.

### Kiểm thử Thủ công (Manual Verification)
- Mở trang ChatGPT trong Catalog, bắt đầu một câu hỏi dài và chuyển sang Catalog khác (làm Catalog ChatGPT rơi vào nền và bị che khuất).
- Kiểm tra xem Catalog ChatGPT có tiếp tục nhận nội dung streaming bình thường và không bị chuyển trạng thái ngủ đông hay không.
