# OraBrowser Phase 3 — WindowPool và Instant Surface
## Kế hoạch thực hiện chi tiết
> **Trạng thái:** Proposed  
> **Ngày:** 2026-07-12  
> **Phạm vi:** Phase 3 — `WindowPool`, `ShellResetContract`, `SnapshotOverlay`, `PageLease` và tách `PageLease`/`WindowLease`  
> **Nguồn:** `docs/Document.md`, `docs/OraBrowser-Catalog-Runtime-Plan.md`  
> **Điều kiện đầu vào:** Phase 1 WebRuntime và Phase 2 catalog/AppKit window shell đã khả dụng sau feature flag
## 1. Mục tiêu Phase 3
Phase 3 biến shell AppKit của Phase 2 thành tài nguyên có thể cấp phát và thu hồi, đồng thời bảo đảm người dùng luôn thấy một bề mặt hợp lệ trước khi page live sẵn sàng.
Mục tiêu bắt buộc:
1. Thêm warm/cold `WindowPool` có capacity, TTL, LIFO và trim chủ động.
2. Định nghĩa `ShellResetContract` có thể kiểm chứng; shell reset lỗi phải destroy, không quay lại pool.
3. Thêm `SnapshotOverlay`/skeleton để input → bề mặt nhìn thấy đạt p50 < 50 ms, p95 < 100 ms.
4. Định nghĩa `WindowLease` và `PageLease` là hai quyền sở hữu độc lập, có token/generation và teardown idempotent.
5. Không cho state của catalog, profile, snapshot, delegate hoặc SwiftUI graph trước rò sang catalog sau.
6. Giữ Phase 3 độc lập với policy hibernation L0–L5 của Phase 4; Phase 3 cung cấp primitive, không tự quyết định eviction toàn cục.
### 1.1 Chỉ số thành công
| Chỉ số | Mục tiêu |
|---|---:|
| Input → shell visible, warm hit | p95 < 50 ms |
| Input → snapshot/skeleton visible | p95 < 100 ms |
| Warm shell hit sau warm-up và trong capacity | > 95% |
| State leak qua 10.000 vòng bind/reset/rebind | 0 |
| Duplicate active lease cho cùng shell/page/catalog | 0 |
| Memory sau soak | plateau, không tăng tuyến tính |
| Main-thread work trên acquire warm shell | không I/O, không encode/decode đồng bộ |
### 1.2 Ngoài phạm vi
- Eviction scoring, memory-pressure policy và state machine L0–L5 hoàn chỉnh: Phase 4.
- Activity lease cho generation/upload/call/draft: Phase 5.
- Snapshot disk index, TTL 24 giờ và crash recovery hoàn chỉnh: Phase 6.
- Reuse `WKWebView` đã navigate giữa hai catalog: bị cấm.
- Khôi phục DOM, draft, stream hoặc form state từ ảnh snapshot.
## 2. Hiện trạng và thay đổi cần thực hiện
Phase 2 hiện có:
- `CatalogWindowManager` giữ mapping catalog ↔ controller và destroy controller khi close.
- `CatalogWindowController` có `catalogID`/`generation` bất biến, tự tạo `NSWindow` và root controller trong `init`.
- `CatalogShellView` tự lấy dependency từ `ApplicationGraph.shared` trong `onAppear`; loading/error state nằm trong SwiftUI local state.
- `BrowserPage` có snapshot và teardown idempotent cơ bản; `WebViewFactory` tạo page nhưng chưa cấp `PageLease`.
- `ApplicationGraph` chưa compose `WindowPool`, `SnapshotStore` hoặc WebRuntime façade cấp lease.
Khoảng cách của Phase 3:
| Hiện tại | Đích Phase 3 |
|---|---|
| Controller gắn vĩnh viễn với một catalog | Reusable shell có binding thay đổi qua `WindowLease` |
| Close luôn `window.close()` | Unbind → reset → `orderOut()` → pool; destroy chỉ khi lỗi/overflow/TTL |
| SwiftUI root tự tạo dependency | Manager bind một immutable shell presentation model |
| Loading surface đơn giản | Overlay state machine: skeleton/snapshot/loading/error/live |
| Page được UI/model sở hữu trực tiếp | WebRuntime cấp `PageLease`, shell chỉ attach view khi token hợp lệ |
| Window/page cùng đi theo controller | Window lease và page lease acquire/release độc lập |
## 3. Quyết định kiến trúc và invariants
### 3.1 Đơn vị bền vững và tài nguyên tạm thời
```text
CatalogRecord (bền vững)
  ├── WindowLease?  -> NSWindow + controller + shell host
  └── PageLease?    -> BrowserPage + profile/configuration identity
```
`CatalogID` không phải identity của window hoặc page. Một catalog có thể:
- có cả window và page lease khi visible;
- có window lease nhưng chưa có page lease khi đang hiện snapshot/skeleton;
- có page lease tạm thời nhưng shell chưa attach trong lúc chuyển tiếp;
- không có lease nào khi closed/recycled.
### 3.2 Invariants bắt buộc
1. Mỗi `ShellID` có tối đa một `WindowLease` active.
2. Mỗi `PageID` có tối đa một `PageLease` active.
3. Một catalog có tối đa một window lease và một page lease active.
4. Page chỉ attach khi `catalogID`, `profileID`, `configurationFingerprint` và generation cùng khớp binding hiện tại.
5. `WindowPool` không sở hữu page live và không giữ `CatalogSnapshot` của lần bind trước.
6. `PageLease` không sở hữu `NSWindow`/controller; `WindowLease` không sở hữu vòng đời `BrowserPage`.
7. Release/reset/teardown gọi lặp lại phải không crash và không phát event trễ vào binding mới.
8. Shell không được show snapshot/title/profile của catalog cũ dù chỉ một frame.
9. Private snapshot không được vào disk cache; private/normal không bao giờ dùng chung page.
10. Token hoặc generation cũ không được commit UI, attach/detach page hay trả shell mới về pool.
## 4. Contract `WindowLease`
`WindowLease` là quyền dùng độc quyền một reusable shell. Lease được tạo bởi `WindowPool.acquire`, được đăng ký bởi `CatalogWindowManager`, và kết thúc bằng `release` hoặc `destroy`.
```swift
struct ShellID: Hashable, Sendable { let rawValue: UUID }
struct WindowLeaseID: Hashable, Sendable { let rawValue: UUID }
struct ShellCompatibility: Hashable, Sendable {
    let shellVersion: Int; let chromeVariant: String
    let appearanceClass: String; let minimumOSMajor: Int
}
@MainActor
final class WindowLease {
    let id: WindowLeaseID; let shellID: ShellID
    let catalogID: CatalogID; let generation: Int
    let compatibility: ShellCompatibility
    var controller: CatalogWindowController { get }
    func orderFront(); func attach(_ pageLease: PageLease) throws
    func detachPage(expectedPageLeaseID: PageLeaseID?)
    func release(reason: WindowLeaseReleaseReason) async
    func destroy(reason: ShellDestroyReason)
}
```
### 4.1 Trạng thái lease
```text
reserved -> binding -> visible -> releasing -> reset -> pooled
                       \-> destroying -> destroyed
```
- `reserved`: pool đã lấy shell ra khỏi collection, chưa bind catalog.
- `binding`: áp context/title/frame/overlay; window vẫn `orderOut`.
- `visible`: mapping hai chiều đã đăng ký; có thể chưa có page.
- `releasing`: revoke command/focus, chặn event mới và detach page view.
- `reset`: thực thi `ShellResetContract`.
- `pooled`: không còn lease; shell thuộc pool.
- `destroyed`: controller/window/observers đã teardown và không reuse.
### 4.2 Ownership
- `WindowPool` giữ strong reference tới pooled `ReusableWindowShell`, không giữ active lease.
- `CatalogWindowManager` giữ strong reference tới active `WindowLease` theo `CatalogID`.
- Controller giữ weak event sink; mọi callback mang `WindowLeaseID + catalogID + generation`.
- Lease deinit là assertion/debug fallback, không thay cho release có cấu trúc.
## 5. Contract `PageLease`
`PageLease` là quyền dùng độc quyền một `BrowserPage` thuộc WebRuntime. Nó không đồng nghĩa page đang nằm trong window.
```swift
struct PageID: Hashable, Sendable { let rawValue: UUID }
struct PageLeaseID: Hashable, Sendable { let rawValue: UUID }
struct PageCompatibility: Hashable, Sendable {
    let catalogID: CatalogID; let profileID: ProfileID; let isPrivate: Bool
    let configurationFingerprint: String
}
@MainActor
final class PageLease {
    let id: PageLeaseID; let pageID: PageID
    let catalogID: CatalogID; let generation: Int
    let compatibility: PageCompatibility
    var contentView: NSView { get }
    func load(_ request: URLRequest); func detachFromHost()
    func captureSnapshot(_ request: SnapshotRequest) async throws -> SnapshotArtifact
    func release(reason: PageLeaseReleaseReason)
    func recycle(reason: PageRecycleReason)
}
```
### 5.1 Quy tắc cấp page
- Phase 3 ưu tiên tạo hoặc trả page warm của **chính catalog đó** với fingerprint khớp.
- Không cấp page đã navigate của catalog A cho catalog B.
- Không dùng `about:blank` như cơ chế tẩy state để tái cấp page qua catalog/profile.
- Page slot chưa navigate chỉ được dùng nếu factory configuration hoàn toàn khớp; ngay sau navigation, slot gắn với catalog.
- `release` có thể giữ page warm trong WebRuntime theo budget tạm thời; `recycle` luôn teardown và bỏ reference.
- Fingerprint phải bao gồm profile/private, data store/process-pool class, user scripts, content rules, UA, media policy và feature flags.
### 5.2 Attach token
Controller không nhận `BrowserPage` trực tiếp mà nhận `PageAttachment`:
```swift
struct PageAttachment {
    let windowLeaseID: WindowLeaseID; let pageLeaseID: PageLeaseID
    let catalogID: CatalogID; let generation: Int
    let contentView: NSView
}
```
Trước attach phải kiểm tra đủ bốn identity. Khi detach, chỉ remove view nếu `pageLeaseID` vẫn là attachment hiện tại; callback trễ của page cũ không được gỡ page mới.
## 6. Tách biệt Page lease và Window lease
### 6.1 API orchestration
```swift
@MainActor
protocol WindowLeasing {
    func acquireWindow(for request: WindowAcquireRequest) async throws -> WindowLease
    func releaseWindow(_ lease: WindowLease, reason: WindowLeaseReleaseReason) async
}
@MainActor protocol PageLeasing {
    func acquirePage(for request: PageAcquireRequest) async throws -> PageLease
    func releasePage(_ lease: PageLease, reason: PageLeaseReleaseReason)
}
```
Chỉ `CatalogWindowManager` phối hợp hai contract trong Phase 3. `WindowPool` không gọi WebRuntime; WebRuntime không gọi `WindowPool`.
### 6.2 Ma trận vòng đời
| Tình huống | Window lease | Page lease | Bề mặt |
|---|---|---|---|
| Open, warm shell + warm page | acquire | acquire | snapshot/skeleton → live |
| Open, warm shell + cold page | acquire | create async | snapshot/skeleton → live |
| Page load/crash | giữ | recycle/reacquire | error hoặc snapshot |
| User close Phase 3 | release về pool | release/recycle theo policy | không visible |
| Shell reset fail | destroy | không bị ảnh hưởng sau detach | không visible |
| Page fingerprint đổi | giữ | recycle rồi acquire mới | overlay trong lúc chờ |
| Pool overflow/TTL | destroy pooled shell | không có page | không visible |
### 6.3 Lợi ích bắt buộc
- Shell hit không phụ thuộc network hoặc page creation.
- Page crash không làm mất window/layout/error surface.
- Pool trim shell không vô tình teardown page đang được WebRuntime quản lý.
- Phase 4 có thể hibernate page nhưng giữ shell, hoặc recycle cả hai theo hai command riêng.
- Metrics `windowPoolHit` và `pageWarmHit` không bị trộn.
## 7. Thiết kế `WindowPool`
### 7.1 Cấu trúc
```swift
@MainActor
final class WindowPool {
    func acquire(_ request: WindowAcquireRequest) throws -> WindowLease
    func release(_ lease: WindowLease, reason: WindowLeaseReleaseReason) async
    func trim(to target: WindowPoolCapacity, reason: WindowPoolTrimReason)
    func invalidate(where predicate: (ShellDescriptor) -> Bool); func diagnostics() -> WindowPoolDiagnostics
}
```
Pool có hai collection LIFO theo `ShellCompatibility`:
- **Warm shell:** `NSWindow`, controller, hosting container và layout graph đã dựng; không giữ page, catalog context hoặc snapshot decoded.
- **Cold shell:** shell tối thiểu đã reset, có thể cần tạo lại hosting content trước bind; không giữ decoded image hoặc catalog dependency graph.
“Warm” mô tả chi phí dựng shell, không mô tả WebView. Chuyển warm → cold phải bỏ SwiftUI catalog graph/decoded buffers nhưng vẫn không tạo page coupling.
### 7.2 Acquire
1. Tìm warm shell tương thích theo LIFO.
2. Nếu không có, lấy cold shell và hydrate hosting container.
3. Nếu không có, tạo shell mới từ `ReusableWindowShellFactory`.
4. Reserve shell và tạo `WindowLeaseID` mới.
5. Bind immutable `CatalogShellBinding` khi window còn hidden.
6. Apply frame/title/appearance/overlay của catalog mới.
7. Validate binding; đăng ký mapping manager trước khi `orderFront`.
8. Emit hit/miss, acquire duration và pool depth.
Không đọc SwiftData, decode ảnh hoặc tạo WebView đồng bộ trong bước acquire. Snapshot decode là task riêng; skeleton luôn sẵn sàng.
### 7.3 Release
1. Đánh dấu lease `releasing`; reject command/callback mới.
2. Persist final placement qua registry; persistence lỗi không chặn cleanup.
3. Revoke key/focus và thay live layer bằng privacy-safe blank surface.
4. `orderOut()` trước khi đưa shell vào pool.
5. Detach page attachment, nhưng page release được manager gửi riêng cho WebRuntime.
6. Chạy `ShellResetContract.reset` và `validateClean`.
7. Nếu pass, enqueue warm/cold theo capacity; nếu fail, destroy.
8. Xóa mapping active theo compare-and-remove bằng lease ID.
Không gọi `window.close()` cho shell hợp lệ được pool. Chỉ close/destroy khi reset lỗi, TTL/overflow, compatibility invalidation hoặc app terminate.
### 7.4 Capacity, TTL và trim
Giá trị Phase 3 ban đầu, có thể override bằng test/config:
| Pool | 8 GB | 16 GB | 32 GB+ | TTL |
|---|---:|---:|---:|---:|
| Warm shell max | 2 | 4 | 6 | 5 phút |
| Cold shell max | 4 | 8 | 12 | 20 phút |
- Capacity là giới hạn shell, không phải số catalog/page.
- Overflow destroy phần tử cũ nhất; acquire lấy phần tử mới nhất.
- App background, thermal serious hoặc memory warning: warm → cold, giảm decoded overlay về 0.
- Memory critical/app terminate: destroy toàn pool; active lease do manager xử lý riêng.
- Phase 4 sẽ thay static defaults bằng policy thích nghi; API trim phải giữ ổn định.
## 8. `ShellResetContract`
`ShellResetContract` là barrier bắt buộc giữa hai lần bind catalog.
```swift
@MainActor
protocol ShellResetContract {
    func prepareForRelease(_ context: ShellReleaseContext)
    func reset(_ shell: ReusableWindowShell) async -> ShellResetReport
    func validateClean(_ shell: ReusableWindowShell) -> ShellCleanlinessReport
}
```
### 8.1 Reset checklist
Reset phải thực hiện theo thứ tự:
1. Vô hiệu `WindowLeaseID`, catalog generation và command closures cũ.
2. Bỏ key/main eligibility trong lúc reset; `orderOut` window.
3. Detach page host view bằng expected page lease ID.
4. Gỡ first responder khỏi web/content/address field; đặt responder về window hoặc nil an toàn.
5. Hủy async task, debounce item, animation, transition và observer token thuộc binding.
6. Gỡ weak/strong event sink binding; delegate AppKit nền của reusable shell có thể giữ nhưng không giữ catalog.
7. Reset overlay sang `.blank`, xóa decoded snapshot và snapshot key.
8. Xóa title, represented URL, subtitle, progress, favicon, error text, address text và accessibility label động.
9. Đóng popover/sheet/context menu/find/password/download overlay do catalog mở.
10. Reset toolbar/traffic-light customization, cursor tracking, hover state và full-screen pending flag.
11. Gỡ catalog SwiftUI root/dependency graph; thay bằng neutral reusable root.
12. Reset frame metadata tạm, min/max constraints động và appearance override về template.
13. Xóa page attachment ID, catalog/profile ID, generation và navigation callback.
14. Chạy layout pass khi hidden; xác nhận không còn view ngoài allowlist.
### 8.2 Cleanliness report
```swift
struct ShellCleanlinessReport: Sendable {
    let isClean: Bool; let violations: [ShellCleanlinessViolation]
}
```
Validator phải kiểm tra ít nhất:
- không catalog/profile/page/window lease identity;
- không page content view trong hierarchy;
- không snapshot/image/error/title động;
- không sheet, attached child window, popover hoặc first responder nhạy cảm;
- không task/observer/closure catalog-scoped;
- event sink chỉ là pool sink/neutral sink;
- window hidden, không key/main, không full-screen transition;
- root view/controller đúng neutral template.
DEBUG dùng assertion chi tiết. Release build ghi metric đã redaction và destroy shell; không enqueue shell “best effort”.
### 8.3 Failure policy
- Reset timeout, unknown child window, full-screen transition kẹt hoặc violation bất kỳ → destroy.
- Destroy cũng idempotent: cancel task, remove observers, nil delegate/content controller phù hợp, close window.
- Không retry reset trên main thread theo loop.
- Diagnostics ghi `ShellID`, loại violation và timing; không ghi URL/title/snapshot.

## 9. `SnapshotOverlay`
### 9.1 Vai trò
`SnapshotOverlay` là lớp hiển thị tức thời nằm trên page host. Nó không nhận input web và không được trình bày như page live.
```swift
enum SnapshotOverlayState: Equatable {
    case blank, skeleton
    case loading(snapshotKey: SnapshotKey?)
    case snapshot(SnapshotPresentation)
    case error(CatalogSurfaceError)
    case fadingToLive(pageLeaseID: PageLeaseID)
    case live
}
```
Layer order:
```text
CatalogShell
├── PageHostView
├── SnapshotOverlay (hit testing disabled)
├── Loading/Error status chrome
└── Native address/command chrome
```
### 9.2 Presentation flow
1. Bind mới luôn bắt đầu bằng `.skeleton` hoặc privacy-safe `.blank`.
2. Nếu có snapshot đúng `catalogID + generation/checkpointVersion + viewport class`, decode off-main.
3. Trước commit ảnh, kiểm tra window lease ID/generation lần nữa.
4. Page attach phía sau overlay; chỉ chuyển khi page báo ready/first meaningful state theo contract WebRuntime.
5. Cross-fade 80–120 ms; Reduce Motion dùng thay đổi opacity ngắn hoặc không animation.
6. Sau fade, release decoded buffer và state thành `.live`.
Snapshot lỗi/stale không chặn open; giữ skeleton và tiếp tục page load. Snapshot không được nhận click/keyboard; accessibility phải thông báo “Loading live content” khi chưa live.
### 9.3 Privacy và correctness
- Private: mặc định không chụp; nếu bật trong tương lai chỉ memory-only và xóa khi release.
- Normal: Phase 3 dùng in-memory artifact hoặc adapter store tối thiểu; disk lifecycle hoàn chỉnh ở Phase 6.
- Trước khi reuse shell, overlay phải blank trước `orderOut`/reset để ngăn flash catalog cũ.
- Snapshot phải aspect-fill/fit theo policy rõ ràng, không kéo méo; viewport mismatch lớn dùng skeleton.
- Không log URL, title hoặc pixel content; key là opaque.
- Error overlay thuộc binding hiện tại, không được sống qua reset.

## 10. Luồng end-to-end
### 10.1 Open catalog
```text
reserve CatalogSnapshot/generation
→ acquire WindowLease
→ bind neutral shell + skeleton
→ register catalog/window/lease mappings
→ orderFront
→ request/decode snapshot asynchronously
→ acquire PageLease independently
→ validate both lease IDs + generation
→ attach page behind overlay
→ load/restore URL
→ page ready
→ fade overlay to live
```
Nếu acquire page thất bại, giữ window lease và hiển thị error/retry. Không trả shell về pool chỉ vì renderer/network lỗi.
### 10.2 Close catalog
```text
mark catalog closing
→ invalidate generation/commands
→ persist final placement
→ set overlay blank and orderOut
→ detach PageAttachment
→ release PageLease to WebRuntime
→ reset + validate shell
→ release WindowLease to WindowPool
→ mark CatalogRecord closed
```
Persist lỗi được ghi nhận nhưng cleanup vẫn hoàn thành. Mapping chỉ xóa nếu lease ID hiện tại khớp, tránh callback close trễ xóa lease mới.
### 10.3 Rapid close/reopen
- Reopen tạo generation và lease ID mới.
- Task snapshot/page acquire cũ phải cooperative-cancel; kết quả cũ bị drop tại commit guard.
- Shell cũ có thể đang reset; acquire không lấy shell ở trạng thái `releasing/reset`.
- Nếu catalog đã có active lease mới, late `didClose`/navigation event của lease cũ bị ignore.
### 10.4 Page crash hoặc fingerprint thay đổi
- Overlay chuyển error/skeleton trên cùng window lease.
- Detach và recycle page lease cũ.
- Acquire page lease mới đúng fingerprint; window không đổi identity/layout/focus.
- Snapshot chỉ show nếu thuộc catalog/checkpoint hiện tại.

## 11. Concurrency và error model
- AppKit/WebKit, pool, controller, window/page attach chạy trên `@MainActor`.
- Snapshot decode/encode và disk I/O chạy ngoài main actor, trả immutable `Sendable` artifact.
- Manager là nơi duy nhất mutate mapping active; dùng lease ID + generation cho compare-and-commit.
- Không giữ SwiftData model qua actor boundary; dùng `CatalogSnapshot` value.
- Mọi acquire/release có structured error; không `try?` ở trust boundary hoặc state transition.
- Close/reset cleanup dùng `defer`/transaction có báo cáo; persistence failure không tạo zombie shell.
Error đề xuất:
```swift
enum WindowPoolError: Error {
    case incompatibleShell, staleGeneration, bindingFailed
    case duplicateLease(ShellID)
    case resetFailed(ShellResetReport)
}
enum PageLeaseError: Error {
    case incompatibleProfile, fingerprintMismatch, staleGeneration
    case duplicateLease(PageID)
    case pageCreationFailed(underlying: Error)
}
```

## 12. File-level implementation plan
### 12.1 File mới
| File | Nội dung |
|---|---|
| `ora/Features/Catalog/Windowing/WindowLease.swift` | IDs, state và exclusive shell lease |
| `ora/Features/Catalog/Windowing/WindowPool.swift` | warm/cold LIFO, TTL, capacity, trim, diagnostics |
| `ora/Features/Catalog/Windowing/ReusableWindowShell.swift` | neutral shell và factory/hydration |
| `ora/Features/Catalog/Windowing/ShellResetContract.swift` | reset pipeline, validator và reports |
| `ora/Features/Catalog/Views/SnapshotOverlay.swift` | overlay state/presentation/accessibility |
| `ora/Core/BrowserEngine/PageLease.swift` | page lease identity, compatibility và release/recycle |
| `ora/Core/BrowserEngine/WebRuntime.swift` | façade acquire/release page và warm-page ownership |
| `ora/Core/BrowserEngine/PageAttachment.swift` | guarded window/page attachment token |
| `oraTests/WindowPoolTests.swift` | LIFO, TTL, capacity, compatibility, reset failure |
| `oraTests/ShellResetContractTests.swift` | cleanliness/state-leak tests |
| `oraTests/PageLeaseTests.swift` | exclusivity, fingerprint/profile isolation, stale event |
| `oraTests/SnapshotOverlayTests.swift` | state machine, stale decode, privacy, transition |
### 12.2 File sửa
| File | Thay đổi |
|---|---|
| `ora/Features/Catalog/Models/CatalogContracts.swift` | lease-aware event context, snapshot/checkpoint references |
| `ora/Features/Catalog/Windowing/CatalogWindowController.swift` | tách creation khỏi binding; neutral/rebindable shell; attach guard |
| `ora/Features/Catalog/Windowing/CatalogWindowManager.swift` | sở hữu active leases; orchestration acquire/release độc lập |
| `ora/Features/Catalog/Views/CatalogShellView.swift` | nhận binding model; bỏ tự lookup graph trong `onAppear` |
| `ora/Core/BrowserEngine/BrowserPage.swift` | expose attachment-safe hooks; giữ teardown idempotent |
| `ora/Core/BrowserEngine/WebViewFactory.swift` | chỉ factory tạo page/slot theo fingerprint |
| `ora/App/ApplicationGraph.swift` | compose WebRuntime, WindowPool, resetter và overlay dependencies |
| `ora/App/AppCoordinator.swift` | drain pool khi terminate; feature flag startup |
| `ora/App/CatalogCommandRouter.swift` | route theo active window lease thay vì controller cũ |
Mỗi file phải dưới 500 dòng. Nếu `WindowPool`/reset validator lớn, tách policy/value types khỏi implementation thay vì tạo manager tổng hợp.

## 13. Trình tự triển khai — 10 ngày
### Workstream A — Contracts và neutral shell (ngày 1–2)
1. Thêm typed IDs, compatibility, lease state và error types.
2. Refactor controller thành `ReusableWindowShell` có lifecycle create/bind/unbind/destroy.
3. Thêm lease-aware event context; stale event guard trong manager.
4. Test controller không còn catalog identity sau unbind.
**Gate A:** một shell bind A → reset → bind B mà không còn title/context/view/event A.
### Workstream B — Reset contract và WindowPool (ngày 3–5)
1. Implement reset checklist và cleanliness validator.
2. Implement warm/cold stacks theo compatibility, LIFO, TTL và capacity.
3. Chuyển close path sang orderOut/reset/enqueue; thêm destroy fallback.
4. Thêm test clock, deterministic TTL/trim và diagnostics.
**Gate B:** 10.000 vòng acquire/release không duplicate lease, state leak hoặc memory tăng tuyến tính rõ rệt.
### Workstream C — PageLease separation (ngày 6–7)
1. Thêm `WebRuntime` façade và exclusive `PageLease`.
2. Thêm fingerprint/profile validation và `PageAttachment` guard.
3. Tách page release khỏi window release trong manager.
4. Test normal/private, catalog A/B và stale page callback.
**Gate C:** trim/destroy shell không recycle nhầm page; page crash/recreate không destroy shell.
### Workstream D — Instant surface và hardening (ngày 8–10)
1. Implement overlay state machine, skeleton và snapshot adapter.
2. Commit snapshot/page bằng lease ID + generation; cross-fade accessible.
3. Thêm signpost/metrics, feature flag `windowPool` và kill switch.
4. Chạy UI/performance/Instruments matrix và sửa tối đa ba vòng.
**Gate D:** đạt latency target, không flash catalog cũ và rollback về Phase 2 close/destroy path hoạt động.

## 14. Kiểm thử
### 14.1 Unit tests
- Warm trước cold; cùng tier dùng LIFO.
- Compatibility mismatch tạo shell mới, không cấp shell sai variant.
- TTL/overflow destroy phần tử đúng và chỉ một lần.
- Reset thành công xóa mọi catalog-scoped field/view/task/observer.
- Mỗi reset violation làm shell bị destroy, không enqueue.
- Double release/destroy không crash; duplicate acquire bị từ chối.
- Page fingerprint/profile/private/catalog mismatch bị từ chối.
- Late event/snapshot decode/page-ready không commit vào generation mới.
- Overlay transitions hợp lệ; invalid transition assert trong DEBUG.
- Private snapshot không đi qua disk adapter.
### 14.2 Integration/UI tests
1. Open/close/reopen cùng catalog 100 vòng; mapping và focus đúng.
2. Xen kẽ catalog A/B 10 Hz; không flash title/snapshot/page của catalog trước.
3. Mở 20 catalog trong capacity; shell hit rate và LIFO đúng.
4. Page load lỗi/crash: shell/error/retry còn hoạt động.
5. Close khi snapshot decode hoặc page create đang chạy: không orphan attachment.
6. Full-screen/minimize/sheet/popover rồi close: reset hoặc destroy an toàn.
7. Normal/private xen kẽ: không reuse page/snapshot qua boundary.
8. Reduce Motion, VoiceOver và keyboard focus: overlay không giữ input.
9. Feature flag OFF: Phase 2 create/destroy path không regression.
### 14.3 Performance và soak
```bash
xcodegen generate
xcodebuild build -scheme ora -destination 'platform=macOS'
xcodebuild test -scheme ora -destination 'platform=macOS'
```
- Đo `inputToShell`, `inputToOverlay`, `inputToLive`, `shellAcquire`, `shellReset`, `pageAcquire` bằng `os_signpost`.
- Instruments Allocations/Leaks qua 10.000 cycle; kiểm tra retain graph manager → lease → controller → event sink.
- Soak 2 giờ với rapid switch, close/reopen, full-screen và snapshot failure injection.
- Báo riêng warm-shell hit, cold-shell hit, shell miss, warm-page hit; không gộp.

## 15. Feature flag, rollout và rollback
Feature flags:
- `catalogRuntime`: prerequisite từ Phase 2.
- `windowPool`: bật acquire/release shell mới.
- `snapshotOverlay`: cho phép tắt ảnh nhưng giữ skeleton.
- `warmPageLease`: tắt giữ warm page nếu phát hiện regression; không ảnh hưởng shell pool.
Rollout nội bộ: 0% → developer opt-in → 25% test cohort → 100% sau soak. Metric không đạt hoặc state-leak violation tăng sẽ tắt `windowPool` ở lần launch sau.
Rollback:
1. Tắt `windowPool`; close dùng destroy controller như Phase 2.
2. Drain/destroy toàn bộ pooled shell ở startup/flag transition.
3. Giữ CatalogRecord/layout; không migration destructive.
4. Có thể giữ `SnapshotOverlay` skeleton trên non-pooled shell nếu ổn định.
5. `PageLease` façade có thể tiếp tục làm ownership boundary; không trả ownership page về `Tab`.

## 16. Rủi ro và biện pháp
| Rủi ro | Biện pháp |
|---|---|
| SwiftUI state/dependency graph sống qua reuse | neutral root, reset validator, weak/cancellable binding |
| Flash dữ liệu catalog trước | blank overlay trước show/reset; commit guard theo lease/generation |
| Callback close/page cũ xóa binding mới | compare-and-remove bằng lease ID |
| Pool giữ observer/sheet/popover | checklist + cleanliness violation → destroy |
| Full-screen transition không reset được | không pool cho đến khi ổn định; timeout → destroy |
| Reuse WebView gây rò session/history | PageLease riêng; cấm cross-catalog navigated page reuse |
| Snapshot chứa dữ liệu nhạy cảm | private off/memory-only; opaque key; decoded buffer release |
| Pool làm RAM cao hơn tạo mới | capacity/TTL/trim, metrics riêng, kill switch |
| Main-thread hitch do snapshot | skeleton trước; decode/encode off-main |

## 17. Acceptance criteria và Definition of Done
Phase 3 hoàn tất khi:
- `WindowPool`, `WindowLease`, `PageLease`, `ShellResetContract` và `SnapshotOverlay` có contract, implementation và test.
- Catalog identity độc lập với shell/page identity; manager phối hợp hai lease nhưng hai subsystem không gọi lẫn nhau.
- Warm/cold pool đúng LIFO/TTL/capacity/compatibility; reset lỗi luôn destroy.
- Close/reopen không flash title, snapshot, profile, error hoặc page của catalog trước.
- Page lỗi/crash/recreate không làm mất shell; shell trim/destroy không recycle nhầm page.
- Snapshot/skeleton visible đạt p50 < 50 ms, p95 < 100 ms; warm shell acquire p95 < 50 ms trên máy chuẩn.
- Normal/private và fingerprint isolation pass; private snapshot không persist.
- Rapid race tests, 10.000-cycle soak, Instruments, build và test pass.
- Feature flag OFF rollback về Phase 2 hoạt động, không đổi schema destructive.
- GitNexus change detection chỉ báo windowing/WebRuntime/catalog shell/application composition và tests dự kiến.
Phase 3 chỉ cung cấp cơ chế cấp/thu hồi và instant surface. Quyền quyết định **khi nào** giữ warm, hibernate hoặc recycle theo pressure vẫn thuộc `ResourceManager` ở Phase 4.
