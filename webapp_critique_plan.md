# Phân tích phản biện và kế hoạch cải tiến WebApp Packager của OraBrowser
> Phạm vi khảo sát: `project.yml`, `oraWebApp/`, `ora/Features/Catalog/WebAppCreator/` và các hạ tầng sẵn có liên quan trong BrowserEngine, Privacy/Content Blocker và Sparkle.  
> Ngày phân tích: 2026-07-13. Đây là kế hoạch kiến trúc, chưa phải đặc tả triển khai cuối cùng.
## 1. Kết luận điều hành
WebApp Packager hiện tại là một prototype có luồng cơ bản hợp lý: sao chép `CapyWebApp.app`, ghi JSON, sửa `Info.plist`, đổi tên executable, tạo ICNS và ký ad-hoc. Tuy nhiên, thiết kế hiện tại chưa đủ an toàn để phát hành:
1. **Đồng nhất sai ba khái niệm tên**: `appName`, tên bundle/Finder/Dock và tiêu đề cửa sổ đang dùng chung một giá trị; `config.title` lại chưa thực sự điều khiển title của cửa sổ.
2. **Đường ống icon chưa đáng tin cậy**: chỉ nhận PNG thủ công, upscale bằng `sips`, chưa lấy favicon/manifest, chưa xử lý crop/padding/mask/màu nền và chưa chứng minh `AppIcon.icns` được `Info.plist` tham chiếu.
3. **Mô hình đóng gói xung đột với App Sandbox và code signing**: app mẹ đang sandboxed nhưng gọi `Process` tới `sips`, `iconutil`, `codesign`, `xattr`; lỗi sandbox bị nuốt, trong khi bundle đã bị sửa nên chữ ký template có thể mất hiệu lực. “Tạo thành công” vì vậy không đồng nghĩa app tạo ra có thể chạy ổn định qua Gatekeeper.
4. **Không có ranh giới kiến trúc giữa builder, manifest và runtime**: `WebAppConfigMock` trùng schema với `WebAppConfig`, không version hóa, không migration, không validate chặt, không rollback giao dịch.
5. **Runtime còn là kiosk WebKit tối thiểu**: chưa có user scripts/styles, content blocker, permission manager, notification bridge, Dock badge, menu-bar mode, link routing, download/new-window handling hay update compatibility.
6. **Template bị “đóng băng” lúc tạo**: Sparkle chỉ cập nhật OraBrowser mẹ; các `.app` đã sinh là bản copy độc lập nên không nhận sửa lỗi runtime, WebKit policy hay schema mới.
Đề xuất trọng tâm là chuyển từ “copy rồi vá bundle tùy ý” sang một **WebApp Platform có manifest versioned, pipeline đóng gói giao dịch, runtime capability-based và registry quản lý vòng đời**. Trước khi viết thêm tính năng, phải quyết định rõ kênh phân phối và mô hình ký mã.
---
## 2. Hiện trạng kiến trúc
### 2.1 Build và phân phối template
- `project.yml` khai báo hai target:
  - `ora`: app mẹ, macOS 15+, sandboxed, dùng Sparkle, FaviconFinder và SafariConverterLib.
  - `oraWebApp`: app template `CapyWebApp`, macOS 15+, chưa khai báo entitlements, Sparkle, content blocker converter hay cấu hình signing/hardened runtime riêng.
- `ora` phụ thuộc `oraWebApp` với `embed: false`, sau đó post-build copy `CapyWebApp.app` vào `Contents/Resources` của app mẹ.
- Template được sao chép nguyên bundle sang thư mục do người dùng chọn rồi bị sửa tại máy người dùng.
### 2.2 Luồng tạo app
`WebAppCreatorView` thu thập một tên, một/nhiều URL, chế độ persistent/incognito và PNG tùy chọn. `WebAppCreatorService.createWebApp` thực hiện:
1. Tạo/kiểm tra thư mục đích.
2. Copy template.
3. Ghi `Contents/Resources/webapp-config.json`.
4. Sửa `CFBundleName`, `CFBundleDisplayName`, `CFBundleIdentifier`, `CFBundleExecutable`.
5. Đổi tên binary.
6. Dùng `sips` + `iconutil` tạo `AppIcon.icns`.
7. Dùng `codesign --sign -` và xóa quarantine bằng `xattr`.
### 2.3 Runtime hiện tại
- `WebAppState` đọc config động trong Application Support trước, rồi mới fallback về JSON trong bundle.
- Một `WKWebView` được tạo cho mỗi URL; persistent profile dùng `WKWebsiteDataStore(forIdentifier:)`, incognito dùng `.nonPersistent()`.
- User agent bị hard-code; navigation chỉ có back/forward/reload qua `NotificationCenter`.
- Favicon của sidebar tải từ Google S2, không phải discovery trực tiếp từ website.
- `windowStyle`, `title` trong config chưa được triển khai đầy đủ.
### 2.4 Tài sản có thể tái sử dụng từ app mẹ
OraBrowser đã có nền móng tốt hơn runtime template:
- `BrowserUserScript`, injection time và `WKUserContentController` trong BrowserEngine.
- `BrowserEngineProfile`/profile registry cho cô lập website data và process pool.
- `ContentBlockerCompileService`, `ContentBlockerArtifactStore`, `AdBlockService`, rule-list sharding và refresh scheduler.
- Sparkle `UpdateService` cho app mẹ.
Vấn đề là các thành phần này thuộc target `ora`, chưa được tách thành module dùng chung cho `oraWebApp`.
---
## 3. Phân tích phản biện chi tiết
### 3.1 App name, display name và window title
Hiện tại một biến `name` chi phối đồng thời:
- tên package `<name>.app` trong Finder;
- `CFBundleName` và `CFBundleDisplayName`;
- tên executable;
- suffix của bundle identifier;
- `config.title`.
Đây là coupling không cần thiết. Một người dùng có thể muốn:
- **App name**: “Slack – Work” trong Finder/Dock/Spotlight;
- **Window title**: “Acme Support” hoặc title động từ trang;
- **Executable name**: tên ổn định `OraWebAppHost`, không cần hiển thị;
- **Bundle identity**: UUID ổn định, không suy ra từ tên có thể đổi.
Các lỗi cụ thể:
- `config.title` không được gắn rõ vào `WindowGroup`/`NSWindow`; title thực tế có thể vẫn là product/bundle name hoặc title trang.
- Đổi executable chỉ làm tăng rủi ro signing và không mang lợi ích UX.
- Bundle ID suy từ tên dễ va chạm, thay đổi khi rename và có thể chứa ký tự không hợp lệ như `_` hoặc Unicode.
- `NSSavePanel` trả về đường dẫn đầy đủ nhưng service bỏ tên file người dùng đã chỉnh, chỉ lấy thư mục cha rồi tự ghép `appName`.
- “Private” và “Incognito” gây hiểu nhầm: code ánh xạ “Private” sang persistent, “Incognito” sang non-persistent.
**Kết luận:** phải tách identity bất biến khỏi metadata hiển thị và title policy.
### 3.2 Icon và ICNS Retina
Điểm tích cực là pipeline đã sinh đủ tên slot 16–1024 px cho iconset. Tuy nhiên:
- Chỉ chấp nhận PNG, chưa nhận `.icns`, HEIC/JPEG/SVG/PDF hay favicon tự động.
- Một favicon 16/32 px bị upscale thành 1024 px sẽ mờ; không có đánh giá chất lượng nguồn.
- `sips -z` ép ảnh vuông, có thể làm méo ảnh không vuông.
- Không có crop theo alpha bounds, safe-area, padding, background/gradient fallback hay preview ở nhiều kích thước.
- Không đọc `apple-touch-icon`, `<link rel=icon>`, Web App Manifest hoặc Open Graph theo thứ tự ưu tiên.
- Runtime sidebar phụ thuộc Google S2, vừa rò rỉ domain cho bên thứ ba vừa không đảm bảo chất lượng/caching.
- `createICNS` ghi `AppIcon.icns` nhưng `updateInfoPlist` không đặt `CFBundleIconFile`; việc hiển thị phụ thuộc template có sẵn key phù hợp hay không.
- Lỗi icon bị nuốt và UI vẫn báo thành công, không có “success with warnings”.
**Kết luận:** icon phải là một service trong-process có discovery, scoring, normalization và caching; không nên dựa vào shell command từ app sandboxed.
### 3.3 Code signing, sandbox và tính nguyên tử
Đây là rủi ro lớn nhất:
- Sửa `Info.plist`, resources và executable làm mất tính toàn vẹn chữ ký của template.
- App mẹ sandboxed gọi binary hệ thống qua `Process`; code đã dự đoán lỗi sandbox rồi chủ động bỏ qua.
- Nếu `codesign` thất bại, bundle vẫn bị trả về như thành công dù chữ ký cũ đã hỏng.
- Xóa quarantine không phải là thay thế cho ký/notarize đúng chuẩn, và tự động xóa quarantine là hành vi không nên coi là điều kiện vận hành.
- Không staging vào thư mục tạm rồi atomic move; lỗi giữa chừng để lại bundle nửa hoàn chỉnh.
- Không cleanup destination khi config/plist/rename thất bại.
- Không có verify cuối (`codesign --verify --deep --strict`, `spctl`, launch smoke test).
**Quyết định bắt buộc trước triển khai:**
| Kênh | Mô hình đề xuất |
|---|---|
| Developer ID ngoài Mac App Store | Dùng **Packager Helper** tách biệt, có quyền cần thiết, thực hiện staging/sign/verify; app mẹ gửi request có schema chặt. Generated app ký ad-hoc chỉ nên là lựa chọn local, còn chia sẻ ra máy khác cần strategy ký/notarize riêng. |
| Mac App Store/sandbox nghiêm ngặt | Không giả định được phép sinh và thực thi code bundle tùy ý. Ưu tiên **managed web apps trong OraBrowser** hoặc launcher bất biến đã ký + metadata ngoài bundle; cần xác nhận bằng review entitlement/distribution trước. |
| Nội bộ/doanh nghiệp | Có thể dùng signing service/CI để phát hành web app đã ký và notarized từ manifest, thay vì ký trên máy client. |
### 3.4 Config và dữ liệu
- `WebAppConfigMock` và `WebAppConfig` là hai model song song, dễ schema drift.
- Không có `schemaVersion`, `runtimeMinimumVersion`, migration hay capability flags.
- JSON trong bundle sau lần chạy đầu có thể bị config động cũ che khuất mãi mãi.
- Định danh Application Support dựa vào bundle ID; nếu bundle ID collision thì dữ liệu/session/config trộn nhau.
- Config chứa `profileID` dạng String nhưng validate lỏng; runtime tự sinh UUID khác nếu parse thất bại, tạo trạng thái khó chẩn đoán.
- Không có checksum/signature cho manifest, không phân biệt field do builder quản lý và field do runtime thay đổi.
- Không có giới hạn URL scheme/host; normalization chấp nhận mọi scheme có mặt.
**Kết luận:** cần một `WebAppManifest` dùng chung, Codable versioned, validate tại trust boundary và tách immutable manifest khỏi mutable user state.
### 3.5 WebKit runtime
- `WKWebView` được xây trực tiếp trong SwiftUI representable, bỏ qua BrowserEngine/Privacy đã trưởng thành hơn.
- Không xử lý `WKUIDelegate`, popup, `target=_blank`, download, permission camera/mic, authentication challenge, file upload policy và external URL scheme một cách đầy đủ.
- User agent giả Safari cố định dễ lỗi theo thời gian và có thể gây compatibility/security fingerprint bất thường.
- Mỗi tab persistent gọi cùng data-store identifier là đúng hướng, nhưng chưa có lifecycle/resource policy cho nhiều WebView.
- State URL được ghi sau mọi `didFinish`, khiến “home URL” và “last visited URL” nhập làm một; thiếu policy restore.
- Title động, favicon động, unread count và media state chưa được quan sát.
### 3.6 Chất lượng sản phẩm
- UI không có favicon auto-detection, preview icon Retina, advanced settings, warnings hay repair/update flow.
- Không có App Library/registry để sửa, rebuild, backup, export/import hoặc phát hiện app bị di chuyển.
- Error enum không conform `LocalizedError`, nên thông báo có thể không hữu ích.
- Nhiều lỗi quan trọng chỉ `print` hoặc bị nuốt.
- Chưa có unit/integration/UI tests cho packager/runtime.
---
## 4. Đối chiếu đối thủ trên macOS
### 4.1 Ma trận năng lực
| Năng lực | Ora hiện tại | WebCatalog | Coherence X | Unite Pro | Safari Web Apps |
|---|---|---|---|---|---|
| Tên/icon tùy chỉnh | Một tên; PNG thủ công | Custom app/icon, catalog, profiles | Gợi ý tên/icon, icon kiểu macOS | Tự phát hiện tên/icon chất lượng cao, fallback gradient | Đổi tên/icon trong Settings |
| Cô lập dữ liệu | Có UUID profile; chưa quản trị | Sandbox từng app, nhiều profile/account | Profile và engine Chromium riêng | App/site cô lập trên WebKit | Tách cookies/history/settings khỏi Safari |
| Scripts/styles | Chưa có | Không thấy tài liệu công khai đủ rõ để kết luận ở mức per-app | Có thể dựa Chrome extensions; extension riêng cho native behavior | Custom scripts/styles, cross-app sync | Safari Web Extensions; không phải arbitrary editor mặc định |
| Ad/tracker blocking | App mẹ có, template chưa có | Built-in per product/profile | Cài extension/ad blocker riêng | Built-in AdBlock, quick settings | Content blockers/Safari Web Extensions bật/tắt theo web app |
| Menu bar | Chưa có | Có tray/menu bar integration | Không phải điểm mạnh công khai chính | Menu-bar app/overlay, badge | Không phải tính năng mặc định |
| Dock badge/notification | Chưa có | Focused notifications | Phụ thuộc website/Chrome extension | Badge theo service, Dock Monitor, native notifications | Web Push + unread Dock badge |
| Update app đã tạo | Không | Nền tảng quản lý tập trung | Created apps tự cập nhật | Có cơ chế tìm/cập nhật created apps/backend | Hệ thống/Safari quản lý runtime |
| Link routing/window policy | Tối thiểu | Có launcher/workspace | Intelligent whitelisting, link forwarding, tab restore | Link forwarding, permission manager, intelligent windows | Toolbar đơn giản, Open in Safari |
### 4.2 Bài học kiến trúc
1. **WebCatalog:** lợi thế không chỉ là tạo `.app`, mà là control plane gồm app library, profiles, workspaces, sync, menu bar và blocker. Ora cần registry và lifecycle manager, không chỉ wizard “Create”.
2. **Coherence:** extension/bridge là lớp capability để sửa hành vi cửa sổ, link routing, resume và tích hợp native. Ora nên có `RuntimeBridge` có message API tối thiểu, versioned và allowlist, thay vì script ad-hoc không quản trị.
3. **Unite:** WebKit vẫn cạnh tranh được nếu bổ sung native enhancements, scripts/styles, permissions, badge, link routing và update backend. Đây là đối thủ kiến trúc gần nhất với Ora.
4. **Safari Web Apps:** đặt baseline về isolation, settings per-app, extensions/content blockers, notification identity và Dock badge. Ora không nên chỉ đạt mức “một WKWebView có icon”.
Nguồn chính thức tham khảo:
- WebCatalog Desktop và pricing/features: <https://webcatalog.io/en/desktop>, <https://webcatalog.io/en/pricing>
- Coherence X và changelog: <https://www.bzgapps.com/coherence>, <https://www.bzgapps.com/coherence-changelog>
- Unite Pro và changelog: <https://www.bzgapps.com/unite>, <https://www.bzgapps.com/unite-changelog>
- Safari Web Apps và extensions/content blockers: <https://support.apple.com/104996>, <https://support.apple.com/guide/safari/ibrw4a0164a5/mac>
Lưu ý: bảng trên chỉ khẳng định các tính năng được tài liệu chính thức công khai; không suy đoán chi tiết triển khai nội bộ của đối thủ.
---
## 5. Kiến trúc đích đề xuất
### 5.1 Tách module/target
```text
WebAppKit (Swift package/framework dùng chung)
├── Manifest/
│   ├── WebAppManifest
│   ├── ManifestValidator
│   └── ManifestMigrator
├── IconPipeline/
│   ├── IconDiscoveryService
│   ├── IconNormalizer
│   └── ICNSWriter/PackagerIconAdapter
├── Runtime/
│   ├── WebAppRuntimeController
│   ├── ScriptStyleController
│   ├── ContentBlockingController
│   ├── NotificationBadgeController
│   └── LinkRoutingController
└── UpdateProtocol/
    ├── RuntimeCompatibility
    └── WebAppRegistryRecord
Ora target
├── WebAppCreator feature (UI/ViewModel)
├── WebAppRegistry + update coordinator
└── Packager client
OraWebAppHost target
└── Mỏng: load manifest -> validate/migrate -> khởi tạo WebAppKit Runtime
OraWebAppPackagerHelper (chỉ nếu distribution cho phép)
└── staging -> mutate resources/plist -> sign -> verify -> atomic install
```
Không copy source qua hai target. Tách model, icon logic, privacy rule loading và runtime primitives thành module dùng chung; giữ UI app mẹ và app host tách biệt.
### 5.2 Manifest versioned
Ví dụ schema:
```json
{
  "schemaVersion": 2,
  "instanceID": "UUID-bat-bien",
  "runtime": { "minimumVersion": "2.0.0", "createdBy": "0.3.0" },
  "identity": {
    "bundleIdentifier": "com.orabrowser.webapp.instance.<uuid>",
    "appDisplayName": "Slack – Work",
    "finderPackageName": "Slack – Work",
    "windowTitle": { "mode": "custom", "value": "Acme Support" }
  },
  "startPages": [{ "url": "https://app.slack.com", "title": null }],
  "session": { "persistence": "persistent", "restorePolicy": "lastSession" },
  "appearance": { "iconResource": "AppIcon.icns", "titleBar": "hidden" },
  "scripts": [],
  "styles": [],
  "contentBlocking": { "enabled": true, "listIDs": ["easylist"] },
  "integrations": { "menuBar": false, "dockBadge": "webBridge" },
  "navigation": { "allowedHosts": ["*.slack.com"], "externalLinks": "defaultBrowser" }
}
```
Nguyên tắc:
- `instanceID` và bundle ID bất biến; rename không đổi identity/data.
- `appDisplayName`, `finderPackageName`, `windowTitle` độc lập.
- Unknown field được bỏ qua; unknown enum/capability phải fail-safe.
- Manifest immutable do builder quản lý; runtime state (`lastURL`, window frame, unread count) nằm trong Application Support riêng.
- Mọi URL chỉ cho phép `http/https` mặc định; scheme ngoài phải qua allowlist và confirmation.
### 5.3 Pipeline đóng gói giao dịch
1. Validate request và canonicalize tên/URL.
2. Tạo `instanceID`, bundle ID ASCII hợp lệ và không va chạm.
3. Stage trong cùng volume với destination.
4. Copy template bằng API giữ metadata cần thiết.
5. Ghi manifest/config bằng atomic write.
6. Áp icon và metadata; giữ executable name ổn định.
7. Ký theo strategy đã chọn.
8. Verify cấu trúc, plist, manifest, code signature và launch dry-run.
9. Atomic rename từ staging sang destination.
10. Đăng ký vào `WebAppRegistry`; nếu bất kỳ bước nào lỗi thì xóa staging và trả structured error.
Kết quả phải có ba trạng thái rõ: `success`, `successWithWarnings`, `failure`; không nuốt lỗi signing/icon.
---
## 6. Thiết kế các tính năng ưu tiên
### 6.1 Tùy chỉnh app icon nâng cao
**Discovery pipeline:**
1. URL do người dùng chọn.
2. Fetch HTML bằng ephemeral `URLSession`, giới hạn dung lượng/thời gian/redirect.
3. Parse theo ưu tiên: Web App Manifest icon 512/1024 `purpose:any` -> `apple-touch-icon` -> SVG/PNG favicon lớn nhất -> Open Graph image -> `/favicon.ico` -> generated fallback.
4. Không gọi Google S2 mặc định; cache theo origin + ETag/Last-Modified.
5. Chặn localhost/private-network fetch ngoài ý muốn nếu URL nguồn không phải do người dùng xác nhận; giới hạn MIME và decompression size.
**Normalization:**
- Decode bằng ImageIO/NSImage trong-process.
- Giữ aspect ratio; crop alpha bounds; cho chọn fit/fill.
- Canvas vuông 1024 px, safe-area theo macOS icon; background solid/gradient/transparent tùy nguồn.
- Render đúng các slot 16, 32, 128, 256, 512 và @2x từ master chất lượng cao; không upscale âm thầm nếu nguồn quá nhỏ mà phải cảnh báo.
- Preview ở 16/32/128/512 px và light/dark desktop.
- Nhận PNG/JPEG/HEIC/ICNS; SVG/PDF chỉ nếu renderer an toàn đã có.
**Metadata:** đặt rõ `CFBundleIconFile = AppIcon` hoặc asset strategy tương ứng; invalidate icon cache sau install bằng API phù hợp, không dùng thủ thuật xóa quarantine.
### 6.2 App title và app name
UI nên có phần Basic và Advanced:
- `App Name` — tên Finder/Dock/Spotlight, hỗ trợ Unicode, validate `/`, `:`, control chars và độ dài.
- `Window Title` — `followPage`, `appName`, `custom`, hoặc format `"{pageTitle} — {appName}"`.
- `Bundle Identity` — ẩn mặc định, UUID bất biến; chỉ hiển thị read-only trong Advanced.
- `Executable` — cố định `OraWebAppHost`; không rename.
Runtime quan sát `WKWebView.title` và cập nhật `NSWindow.title` theo policy, debounce để tránh nhấp nháy. Menu app lấy `CFBundleDisplayName`; Dock/notification identity dùng bundle ID duy nhất.
### 6.3 UserScripts/UserStyles per WebApp
Model đề xuất:
```swift
struct WebAppInjectionRule: Codable, Identifiable {
    let id: UUID
    var name: String
    var kind: Kind          // javaScript | css
    var source: String
    var matches: [String]   // URL match patterns
    var excludes: [String]
    var injectionTime: InjectionTime
    var frameScope: FrameScope
    var contentWorld: ContentWorldPolicy
    var enabled: Bool
}
```
Thiết kế runtime:
- Compile CSS thành JS wrapper tạo `<style data-ora-id>` idempotent; JS/CSS được inject bằng `WKUserScript` ở document start/end.
- Dùng `WKContentWorld` riêng khi có thể; chỉ dùng `.page` khi rule yêu cầu tương tác trực tiếp và người dùng xác nhận.
- Match URL trước khi tạo page; navigation khác domain phải tái cấu hình/recreate web view nếu cần để tránh script chạy sai origin.
- Message handler chỉ đăng ký theo capability allowlist; validate payload/type/size, không expose native filesystem/process API tùy ý.
- UI có editor, syntax validation, enable/disable, thứ tự, import/export và nút “Reload to apply”.
- Preset built-in được ký/versioned; user script tách khỏi built-in script để update không ghi đè tùy chỉnh.
- Safe mode: giữ Option khi launch hoặc CLI flag để vô hiệu hóa toàn bộ injection khi script làm app trắng/crash loop.
Tái sử dụng `BrowserUserScript` hiện có nhưng bổ sung ID, URL scope, content world và ownership.
### 6.4 Content Blocking cô lập
Không copy toàn bộ filter raw data vào từng `.app`. Đề xuất:
- Shared filter catalog/revision cache trong Ora Application Support để tiết kiệm dung lượng và băng thông.
- Mỗi `instanceID` có selection/policy riêng: enabled, selected list IDs, custom rules, update mode.
- Compiled `WKContentRuleList` identifiers phải namespace theo `instanceID + listID + revision` hoặc có registry ref-count rõ ràng để không xóa artifact app khác.
- Runtime chỉ load rule lists đã chọn vào `WKUserContentController` của page đó.
- Custom allow/block rules per-app được compile thành shard nhỏ ưu tiên cao.
- Update filter list do app mẹ/coordinator thực hiện; runtime nhận revision mới qua distributed notification/XPC rồi recreate controller có kiểm soát.
- Incognito không ghi browsing state, nhưng có thể đọc blocker artifact immutable dùng chung.
- UI hiển thị coverage, last updated, rule count, lỗi compile và “disable on this site”.
Tách phần pure Swift của `ContentBlockerCompileService`/artifact model sang `WebAppKit`; không để target host phụ thuộc toàn bộ SettingsStore của Ora.
### 6.5 Menu Bar extra và Dock Badge
**Menu Bar:**
- Config `menuBar.mode = disabled | companion | menuBarOnly`.
- Dùng `MenuBarExtra` hoặc `NSStatusItem`; menu có Open/Hide, unread summary, reload, pause notifications, quit.
- `menuBarOnly` dùng activation policy/accessory cẩn thận; không tự ẩn Dock nếu user chưa chọn.
- Không tạo một background helper cho mỗi app mặc định. Với nhiều web app, cân nhắc một Ora WebApp Agent quản lý status items để giảm process/memory.
**Dock badge:**
- Native sink: `NSApp.dockTile.badgeLabel`.
- Nguồn dữ liệu theo thứ tự:
  1. Web Notifications/Push nếu WebKit và entitlement cho phép.
  2. Site adapter built-in đã ký cho Gmail/Slack/Teams…
  3. UserScript bridge khai báo `setBadge(count)`.
- Bridge validate `0...9999`, throttle, main-thread update; clear khi logout/config reset, không nhất thiết clear khi focus nếu site không xác nhận read.
- Notification permission per bundle ID; dùng `UNUserNotificationCenter`, category/deep link vào đúng tab.
- Không dùng DOM scraping generic như mặc định vì dễ vỡ và tạo rủi ro script.
### 6.6 Auto-update khi OraBrowser mẹ cập nhật
Không cài Sparkle độc lập vào từng generated app: sẽ nhân updater, feed checks và rủi ro race/signing. Dùng **parent-coordinated update**:
1. `WebAppRegistry` lưu path/bookmark, instance ID, runtime version, manifest version, template hash, lần verify cuối.
2. Sau khi Sparkle cập nhật Ora thành công, `WebAppUpdateCoordinator` quét registry.
3. So sánh `hostRuntimeVersion` và `manifest.minimumVersion`.
4. Với mỗi app: backup manifest + mutable state reference, stage template mới, migrate manifest, áp lại icon/metadata, sign/verify, atomic replace.
5. Không đụng website data vì dữ liệu nằm trong Application Support theo instance ID.
6. Nếu app đang chạy: defer, thông báo “Update on next quit”, hoặc dùng handshake yêu cầu terminate có đồng ý.
7. Rollback giữ một generation trước; journal theo batch để power loss không phá toàn bộ library.
8. App host cũ khi mở tự kiểm tra compatibility và yêu cầu mở Ora để repair nếu thấp hơn minimum; không tự sửa bundle đang chạy.
Registry phải xử lý app bị move/rename bằng security-scoped bookmark hoặc rescan theo instance metadata; missing app được đánh dấu `detached`, không xóa dữ liệu tự động.
---
## 7. Lộ trình triển khai
### Phase 0 — Quyết định distribution và signing (P0, 2–4 ngày)
- Chốt Developer ID vs Mac App Store vs enterprise.
- Prototype tối thiểu: generate, sign, verify, launch trên máy sạch; kiểm tra sandbox/Process/helper.
- Viết threat model cho packager helper, manifest và script bridge.
- Exit criteria: có ADR về signing và bằng chứng Gatekeeper; nếu chưa đạt, không tiếp tục sửa bundle động.
### Phase 1 — Shared manifest, identity và pipeline giao dịch (P0, 1–2 tuần)
- Tạo `WebAppKit` và `WebAppManifest v2` dùng chung.
- Bỏ `WebAppConfigMock`; thêm validator/migrator.
- Tách app display name/window title/bundle identity; giữ executable ổn định.
- Staging, cleanup, atomic install, structured error/warning, verification.
- Sửa save-panel để tôn trọng đúng URL đích.
- Thêm registry bản đầu.
- Exit criteria: 100 lần create/delete không để lại bundle tạm; duplicate name không collision identity; rename không mất data.
### Phase 2 — Icon pipeline (P0, 1 tuần)
- Favicon/manifest discovery, cache và source scoring.
- In-process normalization, multi-size rendering, ICNS adapter phù hợp signing model.
- Preview và manual override; fallback icon đẹp.
- Exit criteria: snapshot/golden tests ở mọi Retina slot; icon rõ ở Finder/Dock/Spotlight; offline fallback không gọi bên thứ ba.
### Phase 3 — Runtime hợp nhất và hardening (P0, 1–2 tuần)
- Đưa host sang `WebAppRuntimeController` dựa trên BrowserEngine primitives.
- Title policy, link routing, popup/download/permissions, session restore, external scheme confirmation.
- Bỏ UA hard-code; cung cấp UA policy có version migration.
- Crash/safe-mode và diagnostics.
- Exit criteria: login/cookie isolation qua hai instance; incognito không persist; popup/download/camera/mic có test matrix.
### Phase 4 — UserScripts/UserStyles (P1, 1–2 tuần)
- Rule model, editor, URL match, content world, ordering và safe mode.
- Built-in presets tách user rules; import/export.
- Exit criteria: scripts không chạy ngoài match; malformed bridge payload bị từ chối; recovery khỏi crash loop.
### Phase 5 — Content blocker per-app (P1, 1–2 tuần)
- Tách compiler/artifact interfaces dùng chung.
- Shared revision cache + per-instance selection + custom override.
- Runtime refresh/recreate an toàn.
- Exit criteria: hai app chọn hai bộ list khác nhau không ảnh hưởng nhau; update/rollback artifact hoạt động offline.
### Phase 6 — macOS integration (P1, 1–2 tuần)
- `UNUserNotificationCenter`, deep link, Dock badge bridge.
- Menu bar companion/menuBarOnly; site adapters cho 2–3 dịch vụ ưu tiên.
- Exit criteria: notification settings hiển thị đúng app identity; badge không leak giữa app; login launch/focus behavior ổn định.
### Phase 7 — Parent-coordinated updates và repair (P0 trước phát hành rộng, 2 tuần)
- Hook sau Sparkle update, registry scan, manifest migration, atomic replacement, rollback.
- UI App Library: update, repair, reveal, export diagnostics, detach/remove.
- Exit criteria: nâng template N -> N+1 giữ cookie/config/icon/user scripts; power-loss simulation không phá app; app đang chạy được defer đúng.
---
## 8. Kiểm thử và tiêu chí chất lượng
### Unit tests
- Name/path/bundle ID normalization với Unicode, emoji, dấu tiếng Việt, tên trùng và path traversal.
- Manifest decode/migrate/unknown fields/corrupt JSON.
- URL scheme/host validation và match patterns.
- Icon source scoring, alpha crop, aspect fit/fill, pixel dimensions.
- Script/style ordering, match/exclude, message payload validation.
- Content-blocker namespace/ref-count/revision rollback.
### Integration tests
- Tạo app vào path có space/Unicode; chạy `codesign`/Gatekeeper verification theo distribution profile.
- Hai app cùng website nhưng khác profile: cookie không giao nhau.
- Persistent vs incognito qua restart.
- Update template giữ Application Support, manifest và icon.
- App bị move/rename; registry resolve lại.
- Filter list update trong khi webview đang active.
### UI/smoke tests
- Wizard basic/advanced, auto favicon, preview và override.
- Window title policy theo navigation.
- Notification permission, badge, menu bar-only, Dock click/close/reopen.
- Popup, OAuth, external link, download, file upload, camera/mic.
### Non-functional
- Packager không block main actor khi resize icon/sign/verify.
- Giới hạn HTML/icon/filter downloads; chống decompression bomb và SSRF.
- Không log URL/token/cookie/script secret.
- Mỗi file code <500 dòng; module có trách nhiệm đơn nhất.
- Telemetry chỉ opt-in và không thu nội dung URL/script.
---
## 9. Ưu tiên sản phẩm và các quyết định không nên trì hoãn
### P0 bắt buộc trước beta
1. Signing/distribution ADR và pipeline atomic có verify.
2. Manifest dùng chung + identity duy nhất + tách ba loại tên.
3. Icon discovery/normalization đáng tin cậy.
4. Runtime isolation, permissions và link routing tối thiểu.
5. Registry + update/repair cho app đã tạo.
### P1 tạo khác biệt cạnh tranh
1. UserScripts/UserStyles scoped và safe mode.
2. Content blocker per-app dùng shared artifacts.
3. Dock badge/native notification.
4. Menu bar companion và site enhancements.
### P2 sau khi nền tảng ổn định
- App library sync/export/import.
- Shared presets giữa nhiều WebApp.
- Team-managed manifests/signing service.
- Dock live content/compact apps và automation/Shortcuts.
### Những điều không nên làm
- Không tiếp tục thêm field vào JSON mock song song.
- Không rename executable chỉ để khớp tên hiển thị.
- Không coi lỗi `codesign`/icon là warning có thể bỏ qua.
- Không inject script ở `.page` world cho mọi site theo mặc định.
- Không nhân bản raw filter lists và Sparkle updater vào từng app.
- Không phụ thuộc Google favicon service mặc định.
- Không cập nhật bundle đang chạy tại chỗ; luôn stage + verify + atomic replace.
---
## 10. Đề xuất bước tiếp theo ngay lập tức
1. Tạo ADR `WebApp Distribution & Signing` với prototype trên máy sạch.
2. Đặc tả `WebAppManifest v2` và migration từ config hiện tại.
3. Tách `WebAppKit` skeleton, đưa model dùng chung vào đó.
4. Viết test đỏ cho identity collision, save-path mismatch, config drift và signing failure bị báo thành công.
5. Chỉ sau khi Phase 0–1 đạt exit criteria mới triển khai icon auto-discovery và các capability nâng cao.
Thứ tự này có chủ ý: scripts, AdBlock, badge hay menu bar đều không cứu được một `.app` có identity/signature/update lifecycle không đáng tin cậy. Nền tảng đóng gói và vòng đời phải đúng trước, sau đó mới mở rộng khả năng runtime.
