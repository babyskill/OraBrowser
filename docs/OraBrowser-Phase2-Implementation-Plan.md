# OraBrowser Phase 2 — Implementation Plan

## Catalog model và AppKit-managed window shell

> **Trạng thái:** Ready for implementation  
> **Ngày:** 2026-07-12  
> **Thời lượng dự kiến:** 2–3 tuần  
> **Phụ thuộc:** Phase 0 contracts và Phase 1 `WebRuntime` façade  
> **Nguồn:** `docs/Document.md`, `docs/OraBrowser-Catalog-Runtime-Plan.md`

---

## 1. Mục tiêu và ranh giới

Phase 2 chuyển quyền sở hữu catalog window từ SwiftUI `WindowGroup` sang AppKit, đồng thời tạo model bền vững cho catalog. Kết quả phải thiết lập được quan hệ:

```text
CatalogRecord (persistent identity)
    ↕ CatalogRegistry
CatalogWindowManager (window lease registry)
    ↕
CatalogWindowController (one AppKit shell)
    ↕
CatalogShellView (SwiftUI content hosted by AppKit)
    ↕
WebRuntime page lease (Phase 1 contract)
```

### 1.1 Kết quả bắt buộc

- `CatalogRecord` là source model cho URL, profile, layout và restore metadata; không giữ `NSWindow`/`WKWebView`.
- `CatalogRegistry` là API duy nhất đọc/ghi catalog metadata.
- `CatalogWindowManager` là module duy nhất tạo, tìm, focus và đóng catalog `NSWindow`.
- `CatalogWindowController` sở hữu đúng một shell AppKit đang bind với đúng một catalog trong Phase 2.
- `WindowLayoutManager` tính frame, cascade, clamp, multi-monitor và lưu layout.
- Normal/private browser `WindowGroup` được loại bỏ; Settings vẫn là SwiftUI `Settings` scene độc lập.
- Deep link, reopen, shortcut, close, full-screen và restore đi qua typed command/event thay vì định tuyến bằng `NSApp.windows` và `NotificationCenter`.
- Có feature flag `catalogRuntime` để rollback về legacy `WindowGroup` trong giai đoạn tích hợp.

### 1.2 Ngoài phạm vi

- Không triển khai warm/cold `WindowPool` (Phase 3).
- Không triển khai snapshot/skeleton cross-fade hoàn chỉnh (Phase 3); Phase 2 chỉ cần loading surface nhẹ.
- Không triển khai L0–L5, eviction, memory pressure hoặc activity lease (Phase 4–5).
- Không serialize DOM, draft, prompt, response hay form value.
- Không cố đặt window vào một macOS Space cụ thể; public API không cung cấp restore Space tùy ý đáng tin cậy.

---

## 2. Hiện trạng cần thay đổi

| Điểm hiện tại | Vấn đề | Đích Phase 2 |
|---|---|---|
| `OraApp` khai báo normal/private `WindowGroup` | SwiftUI quyết định identity/lifecycle window | `AppCoordinator` gọi `CatalogWindowManager` |
| `OraRoot` tự tạo `ModelContainer` và manager | dependency graph bị nhân theo window | `ApplicationGraph` tạo dependency dùng chung và inject theo catalog/profile |
| `AppDelegate.getWindow()` quét `NSApp.windows` | có thể lấy Settings/Passwords window | lookup theo `CatalogID` trong registry |
| `WindowFactory` tạo rồi show ngay | không có identity, delegate, layout restore | shell chỉ do `CatalogWindowController` tạo |
| `OraCommands` dùng `openWindow(id:)`/notification | command phụ thuộc SwiftUI scene và key-window heuristic | typed `CatalogCommandRouter` |
| `WindowReader`/`WindowAccessor` khám phá window từ view | ownership đảo ngược, observer phân tán | controller inject window context và làm `NSWindowDelegate` |
| SwiftData schema chưa có catalog | không có restore source of truth | thêm `CatalogRecord` bằng additive migration |

Phase 2 không xóa `Tab`, `TabManager` hoặc legacy browser path. Chúng được giữ nguyên để rollback; catalog path mới chỉ bật qua feature flag cho tới khi gate hoàn tất.

---

## 3. Quyết định kiến trúc

### 3.1 Invariants

1. Một `CatalogID` chỉ có tối đa một controller/window lease tại một thời điểm.
2. Một controller Phase 2 bind đúng một `CatalogID` từ lúc init đến lúc close; reuse chỉ bắt đầu ở Phase 3.
3. `CatalogRecord` không chứa reference runtime hoặc `@Transient WKWebView`.
4. `CatalogRegistry` không gọi AppKit/WebKit; `CatalogWindowManager` không ghi SwiftData trực tiếp.
5. Mọi AppKit mutation chạy trên `@MainActor`.
6. Normal và private dùng store/profile riêng; private record chỉ ở memory và không restore sau relaunch.
7. Persist frame chỉ khi window không full-screen/minimized; full-screen là cờ riêng.
8. Close phải flush layout trước khi gỡ binding. Callback đến muộn sau close bị bỏ qua bằng `generation`.

### 3.2 Typed identifiers

```swift
struct CatalogID: Hashable, Codable, Sendable { let rawValue: UUID }
struct WorkspaceID: Hashable, Codable, Sendable { let rawValue: UUID }
struct ProfileID: Hashable, Codable, Sendable { let rawValue: UUID }
```

SwiftData lưu `rawValue`; domain API không truyền UUID trần. `configurationFingerprint` là value do Phase 1 `WebRuntime` cấp, không tự tính trong window layer.

---

## 4. `CatalogRecord`

### 4.1 Vị trí và loại

Tạo `ora/Features/Catalog/Models/CatalogRecord.swift` dưới dạng `@Model final class`. Đây là persistence DTO, không phải runtime controller và không conform `ObservableObject` nếu SwiftData observation đã đủ.

### 4.2 Schema v1

```swift
@Model
final class CatalogRecord {
    @Attribute(.unique) var id: UUID
    var workspaceID: UUID?

    var startURL: URL
    var currentURL: URL
    var title: String?

    var profileID: UUID
    var isPrivate: Bool
    var configurationFingerprint: String

    var frameX: Double
    var frameY: Double
    var frameWidth: Double
    var frameHeight: Double
    var screenID: String?
    var isFullScreen: Bool
    var restoreDispositionRaw: String

    var zoomLevel: Double
    var createdAt: Date
    var updatedAt: Date
    var lastActiveAt: Date

    var lifecycleStateRaw: String
    var generation: Int
}
```

### 4.3 Semantics và validation

| Field | Quy tắc |
|---|---|
| `startURL` | URL catalog ban đầu, không đổi khi navigation |
| `currentURL` | URL cuối đã commit; chỉ chấp nhận `http`/`https` hoặc scheme nội bộ allowlist |
| `profileID` + `isPrivate` | immutable sau khi tạo; đổi profile nghĩa là tạo catalog mới |
| `configurationFingerprint` | immutable trong một page lease; mismatch bắt buộc tạo page mới |
| frame scalars | hữu hạn, width ≥ 500, height ≥ 360; luôn clamp trước khi dùng |
| `screenID` | hint, không phải foreign key; monitor có thể biến mất |
| `restoreDispositionRaw` | `visible`, `hidden`, `closed`; chỉ `visible` được restore tự động |
| `lifecycleStateRaw` | Phase 2 dùng `closed`, `opening`, `visible`, `hidden`, `crashed`; mở rộng ở Phase 4 |
| `generation` | tăng khi open/close/rebind; callback generation cũ không được commit |

Không thêm `snapshotKey`, crash backoff hoặc checkpoint payload trong Phase 2; các field đó đi cùng behavior tương ứng ở Phase 3/6 để tránh schema “chết”.

### 4.4 Persistence policy

- Thêm `CatalogRecord.self` vào normal schema trong `ModelConfiguration+Shared.swift` bằng migration additive; không xóa store nếu migration lỗi.
- Tạo một normal `ModelContainer` dùng chung tại `ApplicationGraph`.
- Tạo một in-memory container riêng cho private catalog. Không copy record giữa hai container.
- Save được debounce 250 ms cho move/resize, nhưng close/terminate phải flush đồng bộ trên main actor và báo lỗi có cấu trúc.
- Trước migration, backup database metadata; feature flag rollback chỉ bỏ qua catalog table, không xóa dữ liệu tab cũ.

---

## 5. `CatalogRegistry`

### 5.1 Trách nhiệm

Tạo `ora/Features/Catalog/State/CatalogRegistry.swift` dưới dạng `@MainActor final class`. Registry bọc hai `ModelContext` (persistent normal và ephemeral private) và là source of truth cho metadata.

Registry **được phép**:

- create/fetch/list/update/delete catalog record;
- validate URL/profile/geometry;
- lưu layout và restore disposition;
- phát `CatalogRegistryEvent` sau khi transaction thành công.

Registry **không được phép**:

- tạo/focus/close `NSWindow`;
- tạo hoặc giữ `WKWebView`;
- suy luận key window từ `NSApp.windows`;
- chứa policy hibernation/resource.

### 5.2 API đề xuất

```swift
@MainActor
protocol CatalogRegistryProtocol: AnyObject {
    func create(_ request: CreateCatalogRequest) throws -> CatalogSnapshot
    func snapshot(for id: CatalogID) throws -> CatalogSnapshot
    func restorableCatalogs() throws -> [CatalogSnapshot]
    func updateNavigation(_ update: CatalogNavigationUpdate) throws
    func updateLayout(_ update: CatalogLayoutUpdate) throws
    func markVisible(_ id: CatalogID, generation: Int) throws
    func markHidden(_ id: CatalogID, generation: Int) throws
    func markClosed(_ id: CatalogID, generation: Int) throws
    func delete(_ id: CatalogID) throws
    func flush() throws
}
```

`CatalogSnapshot` là immutable `Sendable` value, giúp window layer không giữ `@Model` object qua actor/lifecycle boundary. Request/update dùng value type, có `generation` và validation tại trust boundary.

### 5.3 Error model

```swift
enum CatalogRegistryError: Error {
    case invalidURL(URL)
    case invalidLayout
    case duplicateID(CatalogID)
    case notFound(CatalogID)
    case profileMismatch
    case staleGeneration(expected: Int, received: Int)
    case persistenceFailure(operation: String, underlying: Error)
}
```

Không dùng `try?` ở create/update/close. UI nhận lỗi có thể phục hồi; diagnostics ghi catalog ID dạng opaque, không ghi URL query hoặc nội dung trang.

### 5.4 Restore ordering

`restorableCatalogs()` chỉ trả normal record có disposition `visible`, sort theo `lastActiveAt` tăng dần để window gần nhất được show cuối và trở thành key. Nếu không có record, coordinator tạo một catalog mặc định. Private registry luôn bắt đầu rỗng.

---

## 6. `CatalogWindowController`

### 6.1 Cấu trúc

Tạo `ora/Features/Catalog/Windowing/CatalogWindowController.swift`:

```swift
@MainActor
final class CatalogWindowController: NSWindowController, NSWindowDelegate {
    let catalogID: CatalogID
    let generation: Int
    weak var eventSink: CatalogWindowEventSink?

    init(
        catalog: CatalogSnapshot,
        rootFactory: CatalogRootFactory,
        layoutManager: WindowLayoutManager,
        eventSink: CatalogWindowEventSink
    )
}
```

Controller tạo `NSWindow`, gắn `NSHostingController<CatalogShellView>`, cấu hình style và delegate trước khi show. Nó không truy cập `ModelContext` và không sở hữu page ngoài lease do `WebRuntime` trả.

### 6.2 Window configuration

- Style mask: `.titled`, `.closable`, `.miniaturizable`, `.resizable`, `.fullSizeContentView` nếu shell hiện tại cần hidden title bar.
- `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, `tabbingMode = .disallowed`.
- `minSize = 500 × 360`; initial size 1440 × 900 nhưng cap theo `visibleFrame`.
- `isReleasedWhenClosed = false`; manager giữ controller đến `windowWillClose`, sau đó teardown và bỏ strong reference để window deallocate.
- Không gọi `center()` sau khi đã có restored/cascade frame.
- `collectionBehavior` không ép `.canJoinAllSpaces`; tôn trọng Space do người dùng quản lý.

### 6.3 Event contract

```swift
enum CatalogWindowEvent {
    case didBecomeKey(CatalogID, generation: Int, at: Date)
    case didResignKey(CatalogID, generation: Int)
    case didMoveOrResize(CatalogID, generation: Int, frame: CGRect, screenID: String?)
    case didChangeFullScreen(CatalogID, generation: Int, isFullScreen: Bool)
    case didMiniaturize(CatalogID, generation: Int)
    case closeRequested(CatalogID, generation: Int)
    case didClose(CatalogID, generation: Int)
}
```

Delegate callbacks chỉ emit event; `CatalogWindowManager` điều phối registry/runtime. Move/resize được coalesce, nhưng `windowDidEndLiveResize`, `windowDidMove`, full-screen exit và close phải flush final frame.

### 6.4 Close sequence

```text
windowShouldClose
→ manager xác nhận catalog/generation
→ WebRuntime detach page lease (idempotent)
→ registry persist final frame + markClosed
→ controller đóng window
→ windowWillClose emit didClose
→ manager xóa hai chiều mapping và strong reference
```

Nếu detach/save lỗi, close vẫn không được để shell “zombie”: hiển thị/log lỗi, giữ record ở trạng thái restore-safe, rồi teardown runtime có cấu trúc. Phase 2 destroy shell; không `orderOut` vào pool.

### 6.5 SwiftUI host

Tạo `CatalogShellView`/`CatalogRootFactory` để inject:

- immutable `CatalogWindowContext` (`catalogID`, `profileID`, generation);
- `AppState` và UI managers có scope rõ ràng;
- page handle từ Phase 1 `WebRuntime`;
- typed window actions (`close`, `reload`, `focusLocation`, `toggleFullScreen`).

`OraRoot` không còn tự tạo `ModelContainer`. Trong migration adapter, nó nhận `CatalogRootDependencies` từ factory. `WindowReader` và phần full-screen observer của `WindowAccessor` được bỏ khỏi catalog path; utility windows có thể giữ riêng nếu còn dùng.

---

## 7. `WindowLayoutManager`

### 7.1 Trách nhiệm và API

Tạo `ora/Features/Catalog/Windowing/WindowLayoutManager.swift` là pure geometry service; chỉ adapter lấy `NSScreen.screens` chạy trên `@MainActor`.

```swift
struct WindowLayoutManager {
    func initialPlacement(
        saved: CatalogWindowPlacement?,
        screens: [ScreenDescriptor],
        existingFrames: [CGRect],
        preferredScreenID: String?
    ) -> ResolvedWindowPlacement

    func persistablePlacement(window: NSWindow) -> CatalogWindowPlacement?
    func rehome(_ frame: CGRect, fromMissingScreenID: String?, screens: [ScreenDescriptor]) -> CGRect
}
```

Geometry core dùng `ScreenDescriptor` value để unit test không cần tạo `NSScreen`/`NSWindow`.

### 7.2 Screen identity và fallback

1. Lưu `CGDirectDisplayID` từ `NSScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]` dưới dạng String.
2. Restore exact screen ID nếu còn tồn tại.
3. Nếu mất monitor, chọn screen có diện tích giao lớn nhất với frame cũ.
4. Nếu không giao, chọn screen của key/main window; cuối cùng `NSScreen.main`/screen đầu tiên.
5. Luôn clamp theo `visibleFrame`, không theo full frame, để tránh menu bar/Dock/notch.

Display ID chỉ là hint vì cấu hình monitor có thể đổi. Không fail restore nếu ID không khớp.

### 7.3 Clamp và cascade

- Reject `NaN`, infinity, width/height ≤ 0.
- Kích thước restore tối thiểu 500 × 360, tối đa 90% visible frame khi frame cũ không còn hợp lệ.
- Bảo đảm ít nhất titlebar và 80 × 80 content nằm trong visible frame; frame hoàn toàn off-screen phải được rehome.
- New window cascade từ frame key catalog gần nhất với offset `(+28, -28)` trong hệ tọa độ AppKit.
- Sau khi chạm mép visible frame, wrap về origin mặc định và tiếp tục offset để tránh chồng hoàn toàn.
- Không dùng `setFrameAutosaveName` cho catalog động vì key theo title dễ collision; registry là persistence source.

### 7.4 Full-screen, minimize và Space

- Persist frame cuối trước khi vào full-screen và lưu `isFullScreen` riêng.
- Restore normal frame, show window, sau đó mới request full-screen một lần khi window đã attach vào screen.
- Không persist minimized frame; lưu normal frame trước minimize.
- Khi monitor disconnect, rehome window không full-screen ngay; window full-screen được xử lý sau khi AppKit exit/move.
- Kiểm thử Space chỉ xác nhận window không xuất hiện trên mọi Space và focus/close đúng; không đặt acceptance criterion “restore đúng Space cũ”.

---

## 8. `CatalogWindowManager` và `AppCoordinator`

### 8.1 Window registry

Tạo `CatalogWindowManager` (`@MainActor`) với hai mapping:

```swift
private var controllersByCatalog: [CatalogID: CatalogWindowController]
private var catalogByWindow: [ObjectIdentifier: CatalogID]
```

API:

```swift
func open(_ request: OpenCatalogRequest) async throws -> CatalogID
func restore(_ snapshot: CatalogSnapshot) async throws
func focus(_ id: CatalogID) throws
func close(_ id: CatalogID) async
func closeAll(reason: CloseReason) async
func catalogID(for window: NSWindow?) -> CatalogID?
func handle(_ event: CatalogWindowEvent)
```

Open cùng `CatalogID` phải focus controller hiện có, không tạo bản sao. Manager gọi theo thứ tự registry → controller/shell → runtime page. Nếu page load lỗi, shell vẫn sống và hiện error surface.

### 8.2 Application composition

Tạo `ApplicationGraph` một lần cho process:

```text
ModelContainer(s)
→ CatalogRegistry
→ WebRuntime (Phase 1)
→ WindowLayoutManager
→ CatalogWindowManager
→ CatalogCommandRouter
→ AppCoordinator
```

`AppCoordinator.start()` restore catalog sau `applicationDidFinishLaunching`. Restore shell theo thứ tự, giới hạn page start đồng thời (mặc định 2) để tránh launch storm. `applicationShouldHandleReopen` focus catalog gần nhất hoặc tạo catalog mặc định khi không có window visible.

### 8.3 External URL policy

`application(_:open:)` validate từng URL rồi:

- nếu có focused normal catalog rỗng/loading-start: navigate catalog đó;
- nếu không: tạo normal `CatalogRecord` mới cho mỗi URL;
- không route URL ngoài vào private catalog;
- malformed/unsupported URL trả error UI, không force unwrap.

---

## 9. Chuyển từ `WindowGroup` sang AppKit shell

### 9.1 Transitional feature flag

`catalogRuntime` đọc trước khi scene/window được tạo:

- **OFF:** giữ normal/private `WindowGroup` và behavior hiện tại.
- **ON:** không khai báo browser `WindowGroup`; `AppCoordinator` quản lý catalog windows.
- Tab database được giữ nguyên ở cả hai path. Không tự chuyển mọi tab thành window.

Vì SwiftUI scene graph không nên đổi động sau launch, flag cần ổn định trong một app session và chỉ áp dụng sau relaunch.

### 9.2 `OraApp` target shape

Đích:

```swift
@main
struct OraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let graph = ApplicationGraph.shared

    var body: some Scene {
        Settings {
            SettingsWindowRoot(/* shared dependencies */)
        }
        .commands { OraCommands(router: graph.commandRouter) }
    }
}
```

Settings/Passwords/About là utility windows và không vào catalog registry. `OraCommands` dùng `SettingsLink`/settings action cho Settings, không dùng browser `openWindow(id:)`.

Trong rollout nếu cần biên dịch cả hai path, tách `LegacyBrowserScenes` và `CatalogRuntimeScenes` ở compile-time/configuration boundary; không để hai path cùng tự mở browser window.

### 9.3 Command mapping

| Command | Phase 2 behavior |
|---|---|
| Cmd+N | `router.openCatalog(isPrivate: false)` |
| Cmd+Shift+N | `router.openCatalog(isPrivate: true)` |
| Cmd+W | close focused catalog; utility window dùng `performClose` |
| Cmd+L | typed action đến focused `CatalogWindowController` |
| Cmd+R | reload page lease của focused catalog |
| Cmd+Option+W | close all catalog windows |
| Settings | mở SwiftUI Settings scene |

`OraCommands` không dựa vào title `"Settings"`/`"Passwords"`. Router phân loại catalog window bằng reverse mapping, utility windows tự xử lý responder chain.

### 9.4 Existing user migration

- Lần đầu bật runtime, nếu chưa có `CatalogRecord`, seed **một** normal catalog từ tab normal được truy cập gần nhất; nếu không có, dùng start page mặc định.
- Không biến toàn bộ tab cũ thành hàng chục window tự động.
- Không migrate private tab/session.
- Ghi migration marker riêng; chạy idempotent; dữ liệu tab cũ vẫn nguyên để rollback.

---

## 10. Trình tự triển khai

### Workstream A — Contracts và persistence (ngày 1–3)

1. Thêm typed IDs, enums, request/update/snapshot value types.
2. Thêm `CatalogRecord` và additive schema migration.
3. Implement `CatalogRegistry` với normal/private contexts và structured errors.
4. Unit test validation, CRUD, restore ordering, private non-persistence và stale generation.

**Gate A:** registry tests pass trên store mới và bản copy store Phase 1; migration failure không xóa dữ liệu.

### Workstream B — Layout và controller (ngày 4–7)

1. Implement pure layout geometry + screen adapter.
2. Implement `CatalogWindowController`, shell root và event sink.
3. Coalesce move/resize, persist final frame, full-screen restore.
4. Test multi-monitor fallback, invalid frame, cascade wrap, close teardown.

**Gate B:** 20 open/move/resize/full-screen/close cycles không duplicate controller hoặc observer.

### Workstream C — Manager và application lifecycle (ngày 8–11)

1. Implement two-way registry and `CatalogWindowManager`.
2. Implement `ApplicationGraph`, `AppCoordinator`, reopen/URL handling.
3. Convert `OraRoot` construction to injected dependencies.
4. Add loading/error surface and bounded page restore concurrency.

**Gate C:** open/focus/close/restore đúng normal/private; renderer/page error không đóng shell.

### Workstream D — Scene/commands migration và hardening (ngày 12–15)

1. Route browser commands through `CatalogCommandRouter`.
2. Remove browser `WindowGroup` from enabled catalog path; retain Settings scene.
3. Seed one catalog idempotently from legacy data.
4. Run UI regression, leak/observer check, feature-flag rollback.

**Gate D:** launch/reopen/deep-link/quit/shortcut ổn định và legacy rollback mở được dữ liệu cũ.

---

## 11. File-level change plan

### File mới

| File | Nội dung |
|---|---|
| `ora/Features/Catalog/Models/CatalogRecord.swift` | SwiftData model + persistent enums |
| `ora/Features/Catalog/Models/CatalogContracts.swift` | IDs, snapshots, requests, updates, errors |
| `ora/Features/Catalog/State/CatalogRegistry.swift` | metadata source of truth |
| `ora/Features/Catalog/Windowing/CatalogWindowController.swift` | `NSWindowController` + delegate |
| `ora/Features/Catalog/Windowing/CatalogWindowManager.swift` | window registry/orchestration |
| `ora/Features/Catalog/Windowing/WindowLayoutManager.swift` | geometry, screen fallback, cascade |
| `ora/Features/Catalog/Views/CatalogShellView.swift` | lightweight SwiftUI host/loading/error surface |
| `ora/App/ApplicationGraph.swift` | process-scoped composition root |
| `ora/App/AppCoordinator.swift` | launch/restore/reopen/terminate coordination |
| `ora/App/CatalogCommandRouter.swift` | typed command routing |

### File sửa

| File | Thay đổi |
|---|---|
| `ora/App/OraApp.swift` | scene migration và delegate startup |
| `ora/App/OraRoot.swift` | nhận dependencies; bỏ self-created container/window discovery trên catalog path |
| `ora/App/OraCommands.swift` | bỏ browser `openWindow(id:)`/key-window title heuristic |
| `ora/Core/Extensions/ModelConfiguration+Shared.swift` | Catalog schema + shared/in-memory configuration |
| `ora/Core/Utilities/WindowFactory.swift` | deprecate/remove main catalog factory sau migration; utility factory nếu cần phải đổi tên rõ |
| `ora/Core/Platform/Representables/WindowReader.swift` | không dùng trong catalog shell; xóa nếu không còn caller |
| `ora/Core/Platform/Representables/WindowAccessor.swift` | chuyển full-screen observation sang controller |

Không sửa `BrowserPage`/`WebViewFactory` ngoài adapter contract đã được Phase 1 định nghĩa.

---

## 12. Kiểm thử

### 12.1 Unit tests

- `CatalogRecord`: default, URL/profile invariants, raw enum compatibility.
- `CatalogRegistry`: CRUD, duplicate/not-found, stale generation, save failure, restore ordering.
- Private store: record biến mất khi recreate container; normal record còn lại.
- `WindowLayoutManager`: single/dual display, negative coordinate, missing monitor, invalid/off-screen frame, Dock/menu visible frame, cascade wrap.
- `CatalogWindowManager`: duplicate open focuses existing, reverse lookup, close removes both mappings, late event ignored.
- Migration: legacy store → schema có catalog, seed marker idempotent, rollback không mất tab.

### 12.2 Integration/UI tests

1. Cold launch không record → đúng một catalog default.
2. Mở 10 normal + 2 private window; shortcut tác động đúng key catalog.
3. Relaunch restore normal frame/order/full-screen; không restore private.
4. Rút màn hình phụ → window được rehome và vẫn thao tác được.
5. Cmd+W đóng catalog; Settings/Passwords close theo responder riêng.
6. Mở URL từ Finder/OS khi không có window, khi normal key và khi private key.
7. App reopen từ Dock sau khi đóng hết window.
8. Rapid open/close 100 vòng: không duplicate registry, observer hoặc tăng memory tuyến tính rõ rệt.
9. Feature flag OFF: legacy `WindowGroup` vẫn launch và đọc dữ liệu tab cũ.

### 12.3 Verification commands

```bash
xcodegen generate
xcodebuild build -scheme ora -destination 'platform=macOS'
xcodebuild test -scheme ora -destination 'platform=macOS'
```

Thêm Instruments/manual pass cho retain cycle giữa manager → controller → event sink → manager; event sink phải `weak` hoặc dùng token hủy rõ ràng.

---

## 13. Acceptance criteria

- Mỗi catalog có identity bền vững độc lập với `NSWindow` và page.
- Không có browser window do SwiftUI `WindowGroup` tạo khi `catalogRuntime` bật.
- Open cùng `CatalogID` không tạo window trùng.
- Close giải phóng controller/page binding và lưu final layout; không để window ẩn bị giữ vô hạn.
- Normal restore đúng URL/frame/screen fallback; private không ghi disk và không restore.
- Full-screen/minimize/multi-monitor disconnect không làm frame invalid hoặc window mất ngoài màn hình.
- Cmd+N, Cmd+Shift+N, Cmd+W, Cmd+L, Cmd+R, reopen và external URL định tuyến đúng catalog.
- Settings/Passwords/About không xuất hiện trong catalog registry.
- Main-thread open path không chờ persistence scan/network; shell visible trước khi page load.
- Unit/integration/UI test pass; build pass trên Apple Silicon và ít nhất một Intel target được hỗ trợ.
- GitNexus `detect_changes()` chỉ báo các file/symbol thuộc catalog window migration và execution flow dự kiến.

---

## 14. Rủi ro và rollback

| Rủi ro | Giảm thiểu |
|---|---|
| Hai lifecycle cùng mở window | feature flag cố định theo launch; chỉ một owner gọi startup |
| Duplicate window cho cùng catalog | atomic check/insert trên `@MainActor`; invariant assertion trong DEBUG |
| SwiftData object vượt context boundary | chỉ trả `CatalogSnapshot` immutable |
| Migration làm mất dữ liệu browser cũ | additive schema, backup, cấm destructive delete, giữ legacy tables |
| Restore off-screen/full-screen loop | pure clamp tests; full-screen chỉ request sau show và một lần/generation |
| Retain cycle controller/delegate/SwiftUI | weak event sink, explicit teardown, lifecycle tests/Instruments |
| External URL vào private profile | router policy luôn tạo/focus normal catalog |
| Page restore storm | bounded concurrency 2; shell không chờ page |
| Exact Space restore không khả thi | không hứa/không dùng private API; tôn trọng AppKit/user Space behavior |

### Rollback procedure

1. Tắt `catalogRuntime` cho lần launch kế tiếp.
2. Legacy `WindowGroup` đọc nguyên store tab cũ.
3. Không xóa catalog records; giữ để điều tra hoặc bật lại.
4. Nếu catalog schema load lỗi, hiển thị recovery UI/diagnostics; không gọi `deleteSwiftDataStore`.

---

## 15. Definition of Done cho Phase 2

Phase 2 hoàn tất khi bốn contract `CatalogRecord`, `CatalogRegistry`, `CatalogWindowController`, `WindowLayoutManager` được implement và test; `CatalogWindowManager` là owner duy nhất của browser shell; normal/private `WindowGroup` không còn hoạt động trên catalog path; restore/multi-monitor/full-screen/shortcut/deep-link đạt acceptance criteria; build/test và change-scope verification đều có bằng chứng mới.
