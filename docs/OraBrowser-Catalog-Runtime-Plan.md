# OraBrowser Native macOS Catalog Runtime

## Phân tích kiến trúc và kế hoạch thiết kế/triển khai

> **Trạng thái:** Proposed  
> **Ngày:** 2026-07-12  
> **Nguồn yêu cầu:** `docs/Document.md` v1.0  
> **Phạm vi:** Swift 5.9, AppKit/SwiftUI, WebKit, macOS 15+, Apple Silicon và Intel

---

## 1. Tóm tắt quyết định

OraBrowser nên chuyển từ mô hình **trình duyệt nhiều tab** hiện tại sang **catalog runtime quản lý tài nguyên**. Một catalog là một định danh bền vững gồm URL, profile phiên, layout và trạng thái khôi phục; `NSWindow` và `WKWebView` chỉ là tài nguyên tạm thời được gắn vào catalog khi cần.

Thiết kế đích có ba đường điều khiển tách biệt:

1. `WindowManager` sở hữu shell AppKit, focus, layout và pool cửa sổ.
2. `WebRuntime` sở hữu profile WebKit, cấu hình, vòng đời page và crash recovery.
3. `ResourceManager` quan sát toàn hệ thống, áp ngân sách và ra lệnh chuyển trạng thái.

Các mục tiêu chính:

- Phản hồi thị giác khi mở/chuyển catalog: **p50 < 50 ms, p95 < 100 ms** nhờ shell/snapshot.
- Không hứa trang web tương tác trong 100 ms; thời gian này phụ thuộc mạng, cache và ứng dụng web.
- Trên máy 8 GB, “50 catalog mở” nghĩa là khoảng 1–2 page live, một số ít page warm và phần còn lại hibernated/recycled; không phải 50 renderer hoạt động.
- Ưu tiên bảo toàn tác vụ AI đang chạy, upload, audio/video call và nội dung chưa gửi trước khi tiết kiệm tài nguyên.
- Mọi ngưỡng là policy thích nghi theo memory pressure, thermal state, nguồn điện và lịch sử sử dụng; không dùng timer cố định như nguồn quyết định duy nhất.

---

## 2. Hiện trạng và khoảng cách với kiến trúc đích

### 2.1 Hiện trạng codebase

Code hiện tại là browser SwiftUI nhiều tab:

- `OraApp` tạo `WindowGroup`; `OraRoot` khởi tạo manager theo từng cửa sổ.
- `TabManager` sở hữu tab/container, dùng timer 60 giây để cleanup tab cũ.
- `Tab` vừa là model SwiftData vừa giữ transient `BrowserPage` và tự tạo/hủy page.
- `BrowserEngine` cache `BrowserEngineProfile` theo container; mỗi profile dùng `WKWebsiteDataStore` riêng.
- `BrowserPage` trực tiếp cấu hình `WKWebView`, delegate, user scripts và teardown.
- `WindowFactory` tạo `NSWindow` nhưng chưa có registry/pool/state machine toàn cục.
- Đã có nền tảng tốt: website data store theo profile, lazy restore page, snapshot API, teardown, crash isolation mặc định của WebKit và host view AppKit.

### 2.2 Khoảng cách cần xử lý

| Vấn đề | Hiện tại | Thiết kế đích |
|---|---|---|
| Đơn vị quản lý | Tab gắn chặt model + page | `CatalogSession` bền vững, shell/page là lease |
| Quyết định tài nguyên | `TabManager` timer cục bộ | `ResourceManager` toàn cục, budget-driven |
| Cửa sổ | SwiftUI `WindowGroup` | Registry AppKit + shell pool có giới hạn |
| Hibernation | Có/không có WebView | State machine nhiều cấp, snapshot + checkpoint |
| Session | Data store theo container | Profile rõ ràng; normal/private tách tuyệt đối |
| Pooling | Chưa có | Pool shell và pool page tách biệt, có fingerprint |
| Occlusion | Chưa là input chính | Focus/visibility/occlusion/minimize/Space là signal |
| AI workload | Chưa phân loại | Activity lease cho stream/upload/call/draft |
| Áp lực hệ thống | Chủ yếu theo tuổi tab | Memory pressure + CPU + thermal + power + age |
| Observability | Phân tán | Metric/event chuẩn hóa, signpost và soak test |

`Tab` hiện có 437 dòng và `TabManager` 708 dòng; khi triển khai phải tách lifecycle/resource policy khỏi model để tuân thủ giới hạn dưới 500 dòng/file.

---

## 3. Đặc tính workload của ứng dụng web AI

ChatGPT, Gemini và các ứng dụng tương tự khác catalog thông thường:

- DOM hội thoại tăng liên tục, nhiều Markdown/code block/image và virtualized list.
- Streaming token giữ network, JavaScript, layout và paint hoạt động dù cửa sổ mất focus.
- Service worker, IndexedDB, Cache Storage và WebSocket/SSE có vòng đời dài.
- Upload file, xử lý ảnh, microphone/camera và screen sharing không được ngắt tùy tiện.
- Người dùng chuyển app/cửa sổ hàng chục đến hàng trăm lần/ngày; catalog gần nhất có xác suất quay lại rất cao.
- Draft chưa gửi, vị trí cuộn và trạng thái UI trong SPA không thể khôi phục hoàn hảo chỉ bằng URL.

Vì vậy policy phải phân biệt:

| Nhóm | Ví dụ | Quy tắc |
|---|---|---|
| Foreground interactive | đang gõ/chọn file | Không throttle/hibernate |
| Protected background | đang stream, upload, call | Giữ live bằng activity lease có TTL |
| Recently used | vừa chuyển khỏi trong 30–120 s | Giữ warm nếu còn budget |
| Idle restorable | không media/draft/task | Được snapshot/deep hibernate |
| Dormant | nhiều phút/giờ không dùng | Release page, chỉ giữ checkpoint |

### 3.1 Activity lease

`WebRuntime` phát `ActivityLease` cho `ResourceManager` với loại, thời hạn và mức bảo vệ:

```swift
enum ActivityKind { case userInput, generation, upload, download, audio, video, screenCapture, unsavedDraft }
struct ActivityLease { let catalogID: CatalogID; let kind: ActivityKind; let expiresAt: ContinuousClock.Instant }
```

- Lease phải được gia hạn bằng sự kiện thực, tự hết hạn để tránh leak.
- Media/capture/download dùng tín hiệu WebKit/native đáng tin cậy.
- Generation/draft chỉ được phát hiện qua adapter cho domain được hỗ trợ và script minh bạch; không đọc nội dung prompt/response.
- Khi không chắc chắn, ưu tiên giữ page ở Level 2 thay vì deep hibernate.
- Memory pressure critical có thể phá lease generation/draft nhưng không phá call/upload đang hoạt động nếu hệ thống chưa ở tình trạng khẩn cấp.

---

## 4. Kiến trúc logic đề xuất

```text
AppCoordinator (@MainActor)
├── CatalogRegistry / WorkspaceManager
├── WindowManager (@MainActor)
│   ├── WindowRegistry
│   ├── WindowPool (warm shell / cold shell)
│   ├── CatalogWindowController
│   └── WindowLayoutManager
├── ResourceManager (actor)
│   ├── ResourcePolicyEngine
│   ├── HibernationManager
│   ├── PressureMonitor
│   └── SnapshotStore
├── WebRuntime (@MainActor façade)
│   ├── WebProfileRegistry
│   ├── WebViewFactory
│   ├── PageSlotPool
│   ├── ActivityMonitor
│   └── WebCrashRecoveryManager
├── Persistence
│   ├── WorkspaceStore
│   ├── CatalogStateStore
│   └── MigrationStore
└── Observability
    ├── OSSignposter
    ├── MetricsStore
    └── DiagnosticsExporter
```

### 4.1 Quyền sở hữu bắt buộc

- `CatalogRegistry` là source of truth cho metadata, không giữ `WKWebView`.
- `WindowManager` là module duy nhất tạo/đóng/reuse `NSWindow`.
- `WebRuntime` là module duy nhất tạo/cấu hình/teardown `WKWebView`.
- `ResourceManager` không chạm AppKit/WebKit trực tiếp; nó phát command có lý do và deadline.
- Mutation AppKit/WebKit chạy trên `@MainActor`; scoring, persistence, metric aggregation chạy ngoài main actor.
- Mỗi catalog có `generation` tăng dần. Command wake/hibernate cũ phải bị bỏ qua để tránh race khi người dùng chuyển nhanh.

### 4.2 Mô hình dữ liệu tối thiểu

```text
CatalogRecord
- id, workspaceID, startURL, currentURL, title
- profileID, configurationFingerprint
- frame, screenID, zoom, lastActiveAt
- lifecycleState, snapshotKey, checkpointVersion
- crashCount, nextAutoReloadAt

RuntimeRecord (memory-only)
- windowLease?, pageLease?, activityLeases[]
- visibility, occlusion, focus, generation
- estimatedCost, transitionStartedAt
```

Persistence dùng SwiftData hiện có cho metadata quan hệ; snapshot và diagnostics là file cache có index/TTL. Ghi theo debounce và atomic replacement. Không lưu password, prompt, response body, form value hay token.

---

## 5. State machine và Hibernation levels

### 5.1 State machine chuẩn

```text
Recycled -> Waking -> Active -> Grace -> Throttled -> Snapshotted -> Hibernated -> Recycled
                          ^          |             |             |
                          +----------+-------------+-------------+
Any live state -> Crashed -> Waking (manual/backoff) | Recycled
```

Chỉ `ResourceManager` xác nhận transition. `WindowManager` và `WebRuntime` trả acknowledgment; transition hoàn tất khi cả UI state và page state đồng bộ.

### 5.2 Chi tiết từng level

| Level | Điều kiện điển hình | Tài nguyên giữ lại | Hành động | Wake |
|---|---|---|---|---|
| L0 Active | key/focused hoặc tương tác < 2 s | shell + live page | QoS bình thường, full rendering | tức thời |
| L1 Grace/Occluded | mất focus/occluded | shell + live page | ghi timestamp, chưa can thiệp | tức thời |
| L2 Throttled | idle 30–60 s, không lease mạnh | shell + live page | dừng timer native của app, pause media không được bảo vệ, giảm polling adapter | tức thời |
| L3 Snapshotted | idle 60–180 s hoặc pressure warning | shell + live page + snapshot disk | capture/coalesce snapshot, checkpoint URL/zoom/scroll | snapshot tức thời |
| L4 Deep Hibernation | idle 3–10 phút, restorable | shell tùy budget + snapshot; không page | detach, teardown, release page lease | snapshot <100 ms; page reload nền |
| L5 Recycled | pressure critical/idle dài/pool overflow | metadata + snapshot tùy TTL | release page và shell; trim snapshot/cache | tạo shell rồi hiện snapshot |

Ngưỡng mặc định theo mode:

| Mode | L2 | L3 | L4 | Warm page budget |
|---|---:|---:|---:|---:|
| Saver / 8 GB | 20 s | 45 s | 120 s | 1–2 |
| Balanced / 16 GB | 45 s | 90 s | 300 s | 3–5 |
| Performance / 32 GB+ | 90 s | 180 s | 600 s | 6–10 |

Ngưỡng được nhân 0.25–0.5 khi memory pressure tăng và 1.5 khi cắm nguồn, thermal nominal, RAM rảnh ổn định. Không dựa vào “free RAM” tức thời; dùng pressure trend và resident footprint của app.

### 5.3 Hành động an toàn theo public API

- WebKit/macOS tự throttle page nền; ứng dụng không thể đặt CPU priority cho renderer một cách đáng tin cậy.
- L2 tập trung vào việc app kiểm soát được: timer, snapshot, observer, animation overlay, polling và media không bảo vệ.
- Không inject script chung để sửa timer của mọi website. Adapter domain-specific chỉ làm tối ưu đã kiểm thử.
- L4 gọi stop loading nếu thích hợp, detach view, gỡ delegate/message handler, close media presentation và release reference.
- Snapshot capture tối đa một tác vụ đồng thời; bỏ yêu cầu cũ nếu generation thay đổi.

### 5.4 Checkpoint và giới hạn khôi phục

Checkpoint lưu URL hiện tại, title, frame, zoom, last interaction, scroll anchor best-effort và deep link hội thoại nếu URL có chứa nó. Với SPA AI, draft/DOM/stream không được serialize. UI phải hiển thị “Reloading live content…” khi snapshot không còn khớp, và không giả vờ snapshot là trang tương tác.

---

## 6. Window pooling

### 6.1 Hai pool shell

**Warm shell pool** giữ `NSWindow` + controller + hosting container đã layout, nhưng không mặc định giữ page. **Cold shell pool** giữ controller tối thiểu hoặc tạo shell theo template; không giữ snapshot giải nén.

Luồng close:

```text
Save state -> revoke focus -> show no sensitive live layer -> orderOut
-> detach page -> reset overlays/delegates/title -> validate clean -> enqueue shell
```

Luồng open:

```text
reserve catalog -> take compatible shell -> bind immutable catalog context
-> show snapshot/skeleton -> orderFront -> request page lease -> cross-fade live page
```

Pool dùng LIFO để tận dụng cache nóng, có TTL, capacity và invariant test. Shell lỗi reset phải bị destroy thay vì quay lại pool.

### 6.2 Không trộn window pool với WebView pool

Reuse `NSWindow` tương đối rẻ và an toàn; reuse `WKWebView` đã duyệt giữa domain/profile có thể giữ history, delegate, script, permission và dữ liệu UI ngoài ý muốn. Vì vậy:

- Pool page chỉ chứa **page slot chưa navigate** hoặc page đã warm đúng `profileID + configurationFingerprint + catalogID`.
- Không reuse page live qua normal/private profile hoặc qua catalog khác.
- Page deep-hibernated được tạo lại bằng `WebViewFactory`, không “reset về about:blank” rồi cấp cho website khác.
- Warm-page hit và warm-shell hit là hai metric riêng; mục tiêu >95% chỉ hợp lý cho **shell hit** sau warm-up, không phải live page hit.

### 6.3 Capacity thích nghi

| RAM vật lý | Warm shell | Cold shell | Warm page | Snapshot disk |
|---:|---:|---:|---:|---:|
| 8 GB | 2–3 | 6 | 1–2 | 150 MB |
| 16 GB | 4–6 | 12 | 3–5 | 300 MB |
| 32 GB+ | 6–8 | 20 | 6–10 | 500 MB |

Không cần giữ 30 `NSWindow` cold trên máy 8 GB; tạo shell rẻ hơn giữ graph SwiftUI/controller lớn. Memory warning giảm warm page về 0–1 và warm shell về minimum; critical xóa toàn bộ page không bảo vệ.

---

## 7. ResourceManager, WindowManager và WebRuntime phối hợp

### 7.1 Event và command

```text
WindowManager -> ResourceManager
focusChanged, visibilityChanged, occlusionChanged, windowClosed, userInteraction

WebRuntime -> ResourceManager
navigationState, activityLease, estimatedCost, pageReady, pageCrashed

System -> ResourceManager
memoryPressure, thermalState, powerState, appActivation, sleepWake

ResourceManager -> WindowManager
showSnapshot, acquireShell, releaseShell, bindPage, unbindPage

ResourceManager -> WebRuntime
acquirePage, throttle, checkpoint, snapshot, hibernate, recycle, reload
```

### 7.2 Trình tự chuyển catalog nóng

1. `WindowManager` nhận action và lập tức focus shell mục tiêu.
2. Nếu page live: attach trong cùng main run-loop; nếu không, hiện snapshot/skeleton trong <100 ms.
3. `ResourceManager` đánh dấu catalog L0, hủy command hibernate cũ bằng generation.
4. `WebRuntime` cấp page tương thích hoặc tạo page, load URL/checkpoint.
5. Khi first meaningful paint/page-ready, cross-fade 80–120 ms và giải phóng snapshot decode buffer.
6. Catalog cũ vào L1, không deep-hibernate ngay để hỗ trợ chuyển qua lại nhanh.

### 7.3 Trình tự hibernate hai pha

1. **Prepare:** kiểm tra focus và lease, đóng băng generation, checkpoint metadata.
2. **Snapshot:** capture có timeout; failure không chặn giải phóng nếu pressure critical.
3. **Commit UI:** `WindowManager` đặt snapshot/skeleton và detach live view.
4. **Commit runtime:** `WebRuntime` teardown page và trả acknowledgment.
5. **Finalize:** `ResourceManager` cập nhật L4/L5, metric và persistence.

Nếu người dùng activate giữa bước 2–4, wake command tăng generation; hibernate cũ phải rollback hoặc bỏ kết quả, không được teardown page vừa được attach lại.

### 7.4 Chấm điểm eviction

Ứng viên có điểm eviction cao hơn khi lâu không dùng, occluded, footprint lớn, reload rẻ và không pinned; điểm giảm mạnh khi có lease:

```text
score = ageWeight + occlusionWeight + estimatedCost + poolPressure
      - recencyWeight - pinnedWeight - restoreCost - activityProtection
```

Chọn theo score dưới budget toàn cục, không để mỗi window tự ngủ. Dùng hysteresis để tránh L2/L3/L4 dao động liên tục.

---

## 8. WebRuntime và session

### 8.1 Profile/session

- `WKWebsiteDataStore` mới là ranh giới cookie/storage bền vững; `WKProcessPool` một mình không đảm bảo chia sẻ cookie.
- Một profile normal dùng data store bền vững ổn định; private dùng `.nonPersistent()` và không bao giờ vào pool normal.
- Nếu cấu hình `WKProcessPool` còn được dùng, chia sẻ trong cùng profile/session class, không dùng một global pool cho normal và private.
- `WebViewFactory` tạo configuration hoàn chỉnh trước khi tạo `WKWebView`; configuration không được mutate sau đó.
- Fingerprint gồm profile, private mode, content rules, user scripts, UA, media policy và feature flags.

### 8.2 Tối ưu AI web app

- Giữ cookie, IndexedDB/service worker trong data store để login và cache sống qua L4.
- Không xóa WebKit disk cache khi memory pressure; disk cache không giải quyết pressure tức thời và làm wake chậm hơn.
- Chỉ trim snapshot decode cache, object cache của app và page live.
- Coalesce navigation/progress events để SwiftUI không render theo từng token/network tick.
- UI metric cập nhật 1–2 Hz ở background, không poll mọi window 60 fps.
- Favicon, snapshot encode/decode và persistence chạy off-main; AppKit/WebKit call vẫn trên main actor.

### 8.3 Crash recovery

Implement `webViewWebContentProcessDidTerminate`. Giữ URL/checkpoint, chuyển `Crashed`, hiện overlay nhẹ, auto-reload tối đa 2 lần với exponential backoff + jitter. Ba crash trong 10 phút mở safe mode/manual reload; không loop tạo renderer.

---

## 9. Memory, CPU và snapshot design

### 9.1 Memory budget

`PressureMonitor` kết hợp:

- `DispatchSource` memory pressure warning/critical.
- Resident footprint/physical memory theo sample thưa (5–15 s, lâu hơn ở background).
- Số page live, snapshot đang decode, shell/page pool và tải gần đây.
- `ProcessInfo.thermalState`, Low Power Mode và app active/background.

Policy phản ứng:

| Tín hiệu | Hành động |
|---|---|
| Normal | giữ recency window và warm budget |
| Warning | L3/L4 sớm, trim decoded snapshots, giảm warm page 50% |
| Critical | bảo vệ active/call/upload; L4/L5 phần còn lại; page pool về 0 |
| Thermal serious | giảm sampling/snapshot, không prewarm, hibernate sớm |
| App background | dừng prewarm/animation/metric UI; chỉ giữ lease cần thiết |

### 9.2 SnapshotStore

- Ảnh hiển thị dùng kích thước theo backing scale và viewport, không chụp full-page.
- Encode HEIF/JPEG tùy alpha/quality; ghi file atomic, tên bằng opaque key, không URL.
- Memory cache chỉ giữ 1–3 snapshot decoded gần nhất với cost limit; còn lại disk.
- Capture coalesced, rate limit và không chạy đồng loạt khi 50 window occluded.
- TTL mặc định 24 giờ; xóa LRU khi quá disk budget, logout/profile deletion hoặc private session kết thúc.
- Snapshot có thể chứa dữ liệu nhạy cảm hiển thị trên màn hình: private snapshot chỉ memory-only hoặc tắt hoàn toàn; normal snapshot dùng file protection/quyền sandbox và tùy chọn privacy blur.

### 9.3 Main-thread performance

- Mọi open/switch trước tiên chỉ bind shell + placeholder; không chờ persistence/network.
- Không encode ảnh, JSON lớn, fetch SwiftData hoặc tính eviction trên main actor.
- Batch metric/state update, tránh `@Published` fan-out toàn workspace.
- Dùng `os_signpost` đo input-to-shell, input-to-snapshot, input-to-live, page creation và teardown.

---

## 10. Kế hoạch triển khai

### Phase 0 — Baseline và contract (1 tuần)

- Ghi baseline launch, tab switch, resident memory, CPU nền và leak sau 2 giờ.
- Chốt `CatalogID`, `ProfileID`, lifecycle enum, event/command và metric schema.
- Viết test fixture mô phỏng 50 catalog, trang stream, upload và crash.
- Gate: dashboard baseline chạy được trên 8/16 GB và Intel/Apple Silicon.

### Phase 1 — Tách WebRuntime (2 tuần)

- Di chuyển quyền tạo page khỏi `Tab` sang `WebViewFactory`/`WebProfileRegistry`.
- Thêm configuration fingerprint, page teardown idempotent và crash callback.
- Duy trì tương thích UI/tab hiện tại qua adapter.
- Gate: session normal chia sẻ đúng trong profile; private cô lập; navigation/download/media regression pass.

### Phase 2 — Catalog model và WindowManager (2–3 tuần)

- Thêm `CatalogRecord`, `CatalogRegistry`, `CatalogWindowController`, registry và layout restore.
- Thay đường mở catalog bằng AppKit-managed shell; chưa bật pooling mặc định.
- Gate: open/close/restore đa màn hình, Space, full-screen và shortcut ổn định.

### Phase 3 — WindowPool + instant surface (2 tuần)

- Warm/cold shell pool, reset contract, snapshot overlay/skeleton và LIFO/TTL.
- Tách page lease khỏi window lease; invariant test chống state leak.
- Gate: shell pool hit p95 <50 ms, không lộ title/snapshot/profile catalog trước.

### Phase 4 — ResourceManager và L0–L5 (3 tuần)

- Pressure monitor, scoring, hysteresis, generation token và transition hai pha.
- L1/L2 trước, sau đó L3 snapshot, L4 teardown và L5 recycle.
- Gate: chuyển nhanh trong khi hibernate không crash/blank; 50 catalog trên 8 GB với budget xác định.

### Phase 5 — AI activity protection (2 tuần)

- Lease cho media/download/upload; adapter opt-in cho ChatGPT/Gemini generation/draft.
- Domain adapter versioned, fail-safe, không thu nội dung.
- Gate: stream/upload/call không bị ngắt ở pressure warning; lease stale tự hết hạn.

### Phase 6 — Persistence, recovery và observability (2 tuần)

- Atomic checkpoint, snapshot index/TTL, crash backoff, sleep/wake và monitor disconnect.
- Metrics local, diagnostics export có consent và redaction.
- Gate: kill renderer/app, sleep/wake và restore workspace không mất cấu trúc.

### Phase 7 — Hardening và rollout (2–3 tuần)

- Soak 8 giờ, 10.000 open/close/switch, memory-pressure injection và Instruments.
- Feature flags: `catalogRuntime`, `windowPool`, `deepHibernation`, `aiActivityLease`.
- Rollout 5% → 25% → 100%, có kill switch và migration rollback metadata.

---

## 11. Kiểm thử và tiêu chí nghiệm thu

### 11.1 Functional/concurrency

- Unit test state transition, scoring, hysteresis, capacity và lease expiry bằng test clock.
- Integration test normal/private profile, pool fingerprint, snapshot failure và crash backoff.
- Race test activate trong từng bước snapshot/teardown; stale generation không được commit.
- UI test rapid switch 10 Hz, Cmd+W/open, multi-monitor disconnect, sleep/wake.

### 11.2 Performance

| Chỉ số | Mục tiêu release |
|---|---:|
| Input → shell/snapshot visible | p50 <50 ms, p95 <100 ms |
| Input → live với page warm | p95 <150 ms |
| CPU app khi background, không lease | median <1%, p95 <3% trên máy chuẩn |
| Shell pool hit sau warm-up | >95% trong giới hạn capacity |
| Memory growth sau 10.000 chu kỳ | không tăng tuyến tính; plateau sau warm-up |
| 50 catalog/8 GB | 1 active + budget warm, phần còn lại L4/L5; không swap storm |
| Crash web process | app sống, overlay <250 ms, không reload loop |

Giá trị RAM tuyệt đối phải được chốt sau Phase 0 vì renderer WebKit và nội dung AI thay đổi theo OS/site. Tiêu chí đúng là budget, plateau, pressure recovery và không swap storm; không dùng một con số RAM thiếu baseline.

### 11.3 Ma trận bắt buộc

- MacBook Air 8 GB, Mac 16 GB, Mac 32 GB+; ít nhất một Intel được hỗ trợ.
- Battery/AC, Low Power Mode, thermal nominal/serious.
- 1/2 màn hình, Space khác nhau, minimized/fully occluded.
- ChatGPT/Gemini: idle chat dài, streaming, upload, draft, voice/video nếu được hỗ trợ.
- Offline/slow network, renderer crash, app force quit và website logout.

---

## 12. Rủi ro và quyết định kiến trúc

| Rủi ro | Giảm thiểu |
|---|---|
| Không thể khôi phục chính xác DOM/draft SPA | activity lease, deep link, snapshot trung thực, thông báo reload |
| WebKit không cung cấp CPU throttle renderer | giảm số page live; chỉ dùng public API và app-owned work |
| Global process/data store làm rò profile | profile boundary + fingerprint + isolation test |
| Pool giữ graph UI/delegate gây leak | reset contract, weak delegate, TTL/cap, repeated-cycle Instruments |
| Snapshot chứa dữ liệu nhạy cảm | private memory-only/off, TTL, file protection, privacy blur |
| Timer/race hibernate khi chuyển nhanh | actor serialization, generation token, two-phase transition |
| Prewarm làm tăng CPU/RAM hơn lợi ích | chỉ prewarm theo dự đoán và budget; tắt ở background/thermal |

ADR cần ghi riêng khi bắt đầu triển khai:

1. Catalog là đơn vị bền vững; window/page là lease.
2. `WKWebsiteDataStore` định nghĩa session boundary; private tách tuyệt đối.
3. Pool shell và page độc lập; không reuse navigated page qua catalog.
4. Resource policy là global, adaptive và activity-aware.
5. Snapshot cung cấp instant visual response, không đại diện live interactivity.
6. Chỉ public API; không phụ thuộc private WebKit key để phát hành.

---

## 13. Definition of Done

Kiến trúc hoàn tất khi:

- Module ownership và event/command contract được kiểm tra bằng test.
- 50 catalog trên máy 8 GB hoạt động theo budget L0–L5, không giữ 50 page live.
- Chuyển catalog luôn có shell/snapshot tức thời; live content thay thế không nhấp nháy.
- ChatGPT/Gemini đang generation/upload/call không bị hibernate nhầm trong điều kiện bình thường.
- Background CPU, memory plateau, pressure recovery và crash recovery đạt bảng mục tiêu.
- Normal/private không chia sẻ dữ liệu ngoài policy; snapshot lifecycle đáp ứng privacy.
- Instruments không phát hiện leak tăng tuyến tính sau soak test.
- Rollout có feature flag, metric, kill switch và migration rollback.

Thiết kế này giữ đúng nguyên tắc của `Document.md`: OraBrowser không tối ưu số lượng cửa sổ, mà tối ưu **tổng chi phí tài nguyên để duy trì workflow của người dùng**.
