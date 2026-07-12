# Architecture Specification

## Catalog Workspace for macOS

Version: 1.0

---

# 1. Architecture Goals

Ứng dụng được thiết kế như một **native macOS catalog runtime**, không phải trình duyệt web tổng quát.

Mục tiêu kiến trúc:

1. Mở nhiều cửa sổ catalog với độ trễ thấp.
2. Giảm RAM/CPU khi cửa sổ không được sử dụng.
3. Tái sử dụng tài nguyên thay vì hủy và tạo lại liên tục.
4. Cô lập lỗi web process để app chính không bị crash.
5. Duy trì session đăng nhập giữa nhiều cửa sổ.
6. Tương thích Apple Silicon và Intel.
7. Có khả năng mở rộng từ 50 lên 100–200 catalog.

---

# 2. High-Level Architecture

```text
Catalog Workspace App

├── AppCoordinator
│
├── WindowManager
│   ├── WindowPool
│   ├── WindowLayoutManager
│   └── CatalogWindowController
│
├── ResourceManager
│   ├── HibernationManager
│   ├── MemoryPressureManager
│   ├── CPUThrottleManager
│   └── SnapshotManager
│
├── WebRuntime
│   ├── SharedProcessPoolProvider
│   ├── WebViewFactory
│   ├── CookieSessionManager
│   └── WebCrashRecoveryManager
│
├── WorkspaceManager
│   ├── WorkspaceStore
│   ├── CatalogStateStore
│   └── RestoreCoordinator
│
├── UI Layer
│   ├── MenuBarController
│   ├── AddressBarController
│   ├── ShortcutController
│   └── SettingsWindowController
│
└── Observability
    ├── PerformanceLogger
    ├── MemoryLogger
    └── DiagnosticsReporter
```

---

# 3. Core Design Principle

Nguyên tắc trung tâm:

> App không quản lý “cửa sổ”.
> App quản lý “tài nguyên”.

Mỗi catalog window chỉ là một bề mặt hiển thị. Quyết định quan trọng nằm ở `ResourceManager`: cửa sổ nào được active, cửa sổ nào được giữ ấm, cửa sổ nào phải ngủ đông, cửa sổ nào cần giải phóng WebView.

---

# 4. Main Components

## 4.1 AppCoordinator

Vai trò:

- Khởi tạo toàn bộ module chính.
- Điều phối lifecycle của ứng dụng.
- Kết nối Menu Bar, Window Manager, Workspace Manager và Resource Manager.
- Xử lý app launch, app terminate, restore session.

Trách nhiệm:

```text
onAppLaunch()
onAppTerminate()
restoreLastWorkspace()
registerShortcuts()
initializeSharedWebRuntime()
```

---

## 4.2 WindowManager

Quản lý toàn bộ catalog windows.

Trách nhiệm:

- Mở cửa sổ mới.
- Đóng/ẩn cửa sổ.
- Tái sử dụng cửa sổ từ pool.
- Theo dõi cửa sổ active/focused/hidden/occluded.
- Gửi event trạng thái cửa sổ cho ResourceManager.

API nội bộ đề xuất:

```swift
final class WindowManager {
    func openCatalog(url: URL, workspaceID: WorkspaceID?)
    func closeWindow(_ id: WindowID)
    func closeAllWindows()
    func focusWindow(_ id: WindowID)
    func restoreWindow(_ state: CatalogWindowState)
}
```

---

## 4.3 WindowPool

Dùng để giảm thời gian mở cửa sổ mới.

Thay vì destroy `NSWindow`, app đưa cửa sổ về trạng thái reusable.

Pool gồm 2 tầng:

```text
Warm Pool
- NSWindow còn tồn tại
- WebView có thể còn tồn tại
- Sẵn sàng hiển thị nhanh

Cold Pool
- NSWindow còn tồn tại
- WebView đã được release hoặc chưa gắn
- Dùng khi cần giảm RAM
```

Chiến lược:

```text
Close window
↓

Save state
↓

orderOut()

↓

Reset transient UI

↓

Return to pool
```

Khi mở window mới:

```text
Request new catalog
↓

Try Warm Pool

↓

If unavailable, try Cold Pool

↓

If unavailable, create new NSWindow
```

---

# 5. Catalog Window Lifecycle

Mỗi cửa sổ có state machine riêng.

```text
Created
  ↓
Loading
  ↓
Active
  ↓
Occluded
  ↓
Throttled
  ↓
Hibernated
  ↓
Waking
  ↓
Active
```

Ngoài ra có các state phụ:

```text
Hidden
Crashed
Recycled
Destroyed
```

---

## 5.1 State Definitions

### Created

Window object đã được tạo nhưng chưa load catalog.

### Loading

WKWebView đang tải URL.

### Active

Window đang hiển thị và người dùng có thể tương tác.

### Occluded

Window bị che khuất hoàn toàn hoặc bị minimize.

### Throttled

Window vẫn giữ web content nhưng giảm hoạt động nền.

### Hibernated

Window đã lưu state, giải phóng web content nặng và chỉ giữ shell/snapshot.

### Waking

Window đang khôi phục từ trạng thái ngủ đông.

### Crashed

Web process của window bị crash, nhưng app chính vẫn sống.

---

# 6. Hibernation Architecture

Hibernation là thành phần quan trọng nhất của kiến trúc.

## 6.1 Hibernation Levels

```text
Level 0: Active
- WebView hoạt động bình thường.

Level 1: Occluded
- Window bị che hoàn toàn.
- Bắt đầu timer.

Level 2: Throttled
- Sau 60 giây occluded.
- Giảm tác vụ nền nếu có thể.
- Tạm dừng animation/media không cần thiết.

Level 3: Snapshot
- Chụp ảnh trạng thái cuối của window.
- Dùng snapshot để hiển thị tức thì khi wake.

Level 4: Deep Hibernation
- Sau 5 phút occluded.
- Lưu URL, scroll position, zoom, workspace metadata.
- Chuyển WebView về trang nhẹ hoặc release WebView.
- Giữ shell window trong pool.

Level 5: Recycled
- Khi memory pressure cao.
- Release WebView hoàn toàn.
- Window chuyển sang cold pool.
```

---

## 6.2 Hibernation Flow

```text
Window becomes occluded
↓

Start occlusion timer

↓

After 60s:
    enter throttled mode

↓

After 5min:
    capture snapshot
    save catalog state
    unload heavy web content
    mark as hibernated

↓

If memory pressure critical:
    recycle web runtime
```

---

## 6.3 Wake Flow

```text
User activates hibernated window
↓

Show snapshot immediately

↓

Recreate or reattach WebView

↓

Load saved URL

↓

Restore scroll/zoom where possible

↓

Fade from snapshot to live WebView

↓

State = Active
```

Wake goal:

```text
Visible response: <100ms
Interactive page: depends on website load time
```

---

# 7. Web Runtime Architecture

## 7.1 Shared Process Pool

Tất cả WKWebView dùng chung một `WKProcessPool`.

Mục tiêu:

- Chia sẻ cookie.
- Chia sẻ login session.
- Giảm số lượng web process.
- Tối ưu cache.
- Đồng nhất hành vi giữa các catalog.

```swift
final class SharedProcessPoolProvider {
    static let shared = WKProcessPool()
}
```

---

## 7.2 WebViewFactory

Toàn bộ WebView phải được tạo qua factory.

Không module nào được tự tạo `WKWebView` trực tiếp.

```swift
final class WebViewFactory {
    func makeWebView(configuration: CatalogWebConfiguration) -> WKWebView
}
```

Factory chịu trách nhiệm:

- Gắn shared process pool.
- Gắn website data store.
- Cấu hình preferences.
- Cấu hình user agent nếu cần.
- Gắn navigation delegate.
- Gắn crash recovery handler.

---

## 7.3 Session Management

Session được quản lý thông qua:

```text
WKWebsiteDataStore.default()
WKHTTPCookieStore
WKProcessPool
```

Ứng dụng không tự lưu password, token hoặc form input.

Được phép lưu:

```text
URL
window position
window size
workspace metadata
zoom level
last active timestamp
hibernation state
```

Không được lưu:

```text
password
credit card
form input nhạy cảm
keystroke
request body
response body
```

---

# 8. Crash Recovery

WKWebView có thể crash riêng mà không làm app chính crash.

Khi phát hiện web process crash:

```text
Web process terminated
↓

Window state = Crashed

↓

Show lightweight error view

↓

Offer Reload button

↓

Reload saved URL on demand
```

UI lỗi nên nhẹ:

```text
“This catalog stopped responding.”
[Reload Catalog]
```

CrashRecoveryManager lưu:

```text
URL
timestamp
workspace ID
crash count
last known state
```

Nếu một catalog crash liên tục quá nhiều lần:

```text
Disable auto reload
Show safe mode
Suggest opening externally
```

---

# 9. Memory Management

## 9.1 ResourceManager

`ResourceManager` là module ra quyết định.

Input:

```text
window count
active window count
occlusion state
last interaction time
memory pressure
CPU usage
pool size
hibernation timers
```

Output:

```text
hibernate window
wake window
recycle WebView
reduce warm pool
clear unused snapshots
```

---

## 9.2 Memory Pressure Strategy

Khi memory pressure thấp:

```text
Keep warm pool
Keep recent inactive windows throttled
Delay deep hibernation
```

Khi memory pressure trung bình:

```text
Hibernate occluded windows sooner
Reduce warm pool size
Release old snapshots
```

Khi memory pressure cao:

```text
Immediately deep-hibernate occluded windows
Move warm pool to cold pool
Release WebViews
Clear non-essential cache
```

---

## 9.3 Pool Size Policy

Đề xuất mặc định:

```text
Warm Pool Min: 2
Warm Pool Max: 8

Cold Pool Max: 30
Snapshot Cache Max: 100
```

Có thể thay đổi theo RAM máy:

```text
8GB RAM:
- Warm Pool Max: 4
- Aggressive hibernation

16GB RAM:
- Warm Pool Max: 8
- Balanced hibernation

32GB+ RAM:
- Warm Pool Max: 12
- Relaxed hibernation
```

---

# 10. Window Layout Architecture

WindowLayoutManager chịu trách nhiệm:

- Nhớ vị trí cửa sổ.
- Cascade khi mở nhiều cửa sổ.
- Restore workspace layout.
- Tránh mở cửa sổ chồng lên hoàn toàn.
- Hỗ trợ nhiều màn hình.

Dữ liệu lưu:

```text
windowID
workspaceID
screenID
frame: NSRect
isFullScreen
lastFocusedAt
```

Cascade strategy:

```text
New window position = last window position + offset
If out of visible screen:
    reset to default origin
```

---

# 11. Workspace Architecture

Workspace là nhóm catalog windows.

Ví dụ:

```text
Workspace: Supplier Research
├── Alibaba
├── 1688
├── Amazon
└── Internal ERP
```

WorkspaceManager chịu trách nhiệm:

- Tạo workspace.
- Lưu workspace.
- Restore workspace.
- Đóng toàn bộ workspace.
- Ghi nhớ layout từng catalog.

WorkspaceState:

```swift
struct WorkspaceState {
    let id: WorkspaceID
    var name: String
    var catalogs: [CatalogWindowState]
    var lastOpenedAt: Date
}
```

CatalogWindowState:

```swift
struct CatalogWindowState {
    let id: WindowID
    var url: URL
    var title: String?
    var frame: CGRect
    var screenID: String?
    var zoomLevel: Double
    var scrollPosition: CGPoint?
    var lifecycleState: WindowLifecycleState
    var lastActiveAt: Date
}
```

---

# 12. UI Architecture

## 12.1 Catalog Window UI

Window style:

```text
Native NSWindow
Minimal chrome
Traffic light controls retained
Address bar hidden by default
```

Layer structure:

```text
CatalogWindow
├── Titlebar / Traffic Lights
├── Hover Address Bar
├── WebView Container
├── Snapshot Overlay
└── Error Overlay
```

---

## 12.2 Address Bar

Address bar xuất hiện khi:

```text
User presses Cmd + L
User moves mouse to top edge
User opens new catalog
```

Address bar ẩn khi:

```text
ESC
Mouse leaves top area
URL submitted
Window loses focus
```

---

## 12.3 Menu Bar

MenuBarController hiển thị:

```text
Open Catalog
Open Recent
Workspaces
Active Windows
Sleeping Windows
Close All
Preferences
Quit
```

Menu bar status nên hiển thị:

```text
Active: 8
Sleeping: 42
RAM Mode: Balanced
```

---

# 13. Shortcut Architecture

ShortcutController xử lý:

```text
Cmd + N          Open new catalog
Cmd + L          Focus address bar
Cmd + W          Hide current catalog
Cmd + Option + W Close all catalogs
Cmd + R          Reload current catalog
Cmd + Shift + R  Force reload
```

Shortcut phải hoạt động đúng theo window focus.

---

# 14. Persistence Architecture

Dữ liệu lưu local bằng SQLite hoặc Codable file store.

Đề xuất MVP:

```text
Application Support/
└── CatalogWorkspace/
    ├── workspaces.json
    ├── windows.json
    ├── settings.json
    ├── snapshots/
    └── diagnostics/
```

Không lưu thông tin nhạy cảm.

---

# 15. Observability

Ngay từ MVP cần có internal metrics.

PerformanceLogger ghi:

```text
app launch time
window open time
pool hit rate
pool miss rate
webview creation time
wake time
hibernate duration
RAM estimate
crash count
reload count
```

Các metric này phục vụ debug, không upload ra ngoài nếu chưa có consent.

---

# 16. Security Architecture

Nguyên tắc:

Ứng dụng là container hiển thị web catalog, không phải proxy.

Ứng dụng không được:

```text
inject JavaScript trái phép
đọc password
ghi lại keystroke
intercept HTTPS
lưu request/response body
upload browsing data
```

Ứng dụng được phép:

```text
lưu URL
lưu layout
lưu workspace
lưu trạng thái hibernation
dùng cookie store chuẩn của WKWebView
```

---

# 17. Reliability Strategy

Ứng dụng phải chịu được:

```text
web process crash
network failure
website load timeout
memory pressure
mở nhiều cửa sổ liên tục
sleep/wake macOS
multi-monitor disconnect
```

Mỗi lỗi phải degrade gracefully.

Ví dụ:

```text
Monitor disconnected
↓

Move windows to available screen

Memory critical
↓

Hibernate all inactive windows

Web crash
↓

Show reload overlay
```

---

# 18. MVP Architecture Scope

MVP bắt buộc có:

```text
WindowManager
WindowPool
Shared WKProcessPool
Basic Hibernation
Menu Bar
Shortcuts
Workspace persistence
Crash recovery
Memory logging
```

MVP chưa cần:

```text
Cloud sync
Team sharing
Advanced analytics
Browser extension
Plugin system
Custom scripting
```

---

# 19. Key ADRs

## ADR-001: Use Native macOS Instead of Electron

Decision:

Ứng dụng dùng Swift + AppKit/SwiftUI + WKWebView.

Reason:

Electron khó đạt mục tiêu RAM thấp khi mở 50+ cửa sổ.

---

## ADR-002: Use Shared WKProcessPool

Decision:

Tất cả WKWebView dùng chung một process pool.

Reason:

Đảm bảo session đồng nhất và giảm overhead.

---

## ADR-003: Use Window Pooling

Decision:

Đóng cửa sổ mặc định là ẩn và tái sử dụng, không destroy ngay.

Reason:

Giảm thời gian mở catalog mới và giảm chi phí khởi tạo.

---

## ADR-004: Use Multi-Level Hibernation

Decision:

Cửa sổ inactive đi qua nhiều cấp hibernation thay vì unload ngay.

Reason:

Cân bằng giữa trải nghiệm wake nhanh và tiết kiệm RAM.

---

## ADR-005: ResourceManager Owns Performance Decisions

Decision:

Không để từng window tự quyết định ngủ/wake/recycle.

Reason:

Cần một module trung tâm tối ưu toàn cục theo RAM, CPU và số lượng cửa sổ.

---

# 20. Acceptance Criteria for Architecture

Kiến trúc được xem là đạt khi:

```text
Mở được 50 catalog windows trên MacBook Air 8GB.

App chính không crash khi web process crash.

Đóng/mở lại window không tạo memory leak sau 2 giờ.

Window pooling có hit rate >95% sau giai đoạn warm-up.

Occluded windows được hibernated tự động.

Shared login session hoạt động giữa nhiều window.

Menu bar hiển thị đúng số active/sleeping windows.

Wake từ hibernation phản hồi UI trong <100ms.

Không lưu dữ liệu nhạy cảm của user.
```

---

# 21. Implementation Order

Đề xuất thứ tự triển khai:

```text
Phase 1:
- App shell
- WindowManager
- WebViewFactory
- SharedProcessPool

Phase 2:
- WindowPool
- Basic open/close/reuse
- Shortcut support

Phase 3:
- Occlusion detection
- HibernationManager
- SnapshotManager

Phase 4:
- Workspace persistence
- Restore layout
- Menu bar status

Phase 5:
- Crash recovery
- Memory pressure handling
- Performance diagnostics

Phase 6:
- Polish UI
- Settings
- Acceptance testing
```

---

# 22. Final Architecture Summary

Catalog Workspace được thiết kế như một hệ thống quản lý tài nguyên web native trên macOS.

Trung tâm của hệ thống không phải là `WKWebView`, mà là `ResourceManager`.

`WindowManager` chịu trách nhiệm hiển thị.

`WebRuntime` chịu trách nhiệm session và web process.

`HibernationManager` chịu trách nhiệm giảm tài nguyên.

`WorkspaceManager` chịu trách nhiệm lưu và khôi phục workflow.

Kiến trúc này cho phép ứng dụng đạt được mục tiêu chính: mở nhiều catalog cùng lúc nhưng vẫn giữ macOS mượt, ổn định và tiết kiệm RAM.
