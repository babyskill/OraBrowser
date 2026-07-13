# OraBrowser — Codebase Map

> **Project Type:** macos | **Tech Stack:** macOS (SwiftUI, WebKit)
> **Last Synced:** 2026-07-13 (Phase 7 runtime hardening)

> [!NOTE]
> AI PHẢI đọc file này TRƯỚC KHI dùng `grep_search` / `codebase_search` / `list_dir`.
> Đọc → xác định target → search cụ thể. KHÔNG search "mù".

---

## 🗺️ Directory Structure

```
ora/
├── App/                         # SwiftUI app lifecycle and root composition
├── Core/BrowserEngine/          # WebKit abstraction, profiles and page hosting
├── Core/Services/               # App/web shared services
├── Features/                    # Browser, tabs, privacy, settings, downloads…
├── Shared/                      # Reusable UI components and layouts
└── Resources/                   # Runtime resources
oraTests/                        # Unit tests
oraUITests/                      # UI tests
docs/                            # Architecture and product documentation
scripts/                         # Build, release and publishing automation
```

---

## 📁 File Index

> Compact format: `path` → purpose (1 line mỗi file)

### Core / Infrastructure

| Path | Purpose |
|------|---------|
| `ora/App/OraApp.swift` | AppKit delegate, SwiftUI scenes and application lifecycle |
| `ora/App/OraRoot.swift` | Per-window dependency composition and root browser UI |
| `ora/Core/BrowserEngine/BrowserEngine.swift` | Browser profile/page creation façade |
| `ora/Core/BrowserEngine/BrowserEngineProfile.swift` | Persistent/private `WKWebsiteDataStore` profiles |
| `ora/Core/BrowserEngine/BrowserPage.swift` | `WKWebView` configuration, navigation, scripts and teardown |
| `ora/Core/BrowserEngine/BrowserPageView.swift` | AppKit host view and SwiftUI bridge for browser pages |
| `ora/Core/Utilities/WindowFactory.swift` | Imperative `NSWindow` construction helper |
| `ora/Core/Utilities/SystemNotificationMonitor.swift` | Bridges system sleep, wake, and display-change notifications into callbacks |
| `ora/Features/Catalog/Windowing/CatalogWindowManager.swift` | Catalog windows/pages, crash backoff, and system sleep/wake resource coordination |

### Features

| Path | Purpose |
|------|---------|
| `ora/Features/Tabs/Models/Tab.swift` | Persistent tab model plus transient browser-page lifecycle |
| `ora/Features/Tabs/State/TabManager.swift` | Tab/container orchestration, activation and cleanup policy |
| `ora/Features/Privacy/` | Content blocking, privacy policy and per-space settings |
| `ora/Features/Downloads/` | Download persistence, progress and UI |
| `ora/Features/Settings/` | User-facing application settings |
| `ora/Features/Catalog/ResourceManager/` | Centralized ResourceManager, PolicyEngine, PressureMonitor, SnapshotStore, and ActivityLease |
| `oraTests/CrashBackoffTests.swift` | Crash-window counting and reload cutoff tests |
| `oraTests/SystemNotificationTests.swift` | System sleep, wake, and display notification forwarding tests |
| `oraTests/HardeningTests.swift` | Phase 7 stress/soak coverage for hibernation and activity-lease feature flags |



### UI / Views

| Path | Purpose |
|------|---------|
| `ora/Features/Browser/Views/BrowserView.swift` | Main browser surface and floating UI coordination |
| `ora/Features/Browser/Views/BrowserWebContentView.swift` | Active page, error, password and find overlays |
| `ora/Features/Sidebar/` | Sidebar and tab navigation UI |
| `ora/Features/Launcher/` | Keyboard launcher and suggestions |

> ⚠️ Thêm file mới vào section phù hợp. Dùng `/codebase-sync` để auto-update.

---

## 🔑 Key Files

| File | Purpose |
|------|---------|
| `.project-identity` | AI project context |
| `CODEBASE.md` | This file — codebase map for AI |
| `project.yml` | XcodeGen targets, packages, entitlements and build settings |
| `docs/Document.md` | Initial native catalog runtime architecture specification |
| `docs/OraBrowser-Catalog-Runtime-Plan.md` | Detailed catalog runtime analysis and implementation plan |
| `docs/OraBrowser-Phase2-Implementation-Plan.md` | Phase 2 catalog model, AppKit window shell and WindowGroup migration plan |
| `docs/OraBrowser-Phase3-Implementation-Plan.md` | Phase 3 WindowPool, shell reset, instant snapshot surface and independent window/page lease plan |
| `docs/OraBrowser-Phase4-Implementation-Plan.md` | Phase 4 ResourceManager, L0-L5 Hibernation Policy, PressureMonitor, and SnapshotStore plan |
| `docs/OraBrowser-Phase5-Implementation-Plan.md` | Phase 5 AI Activity Protection, user scripts and activity leases plan |



---

## 📝 Notes

- Current implementation is a general multi-tab browser; the catalog runtime is a proposed migration.
- `BrowserEngineProfile` isolates website data by container/profile; private profiles are non-persistent.
- `Tab` currently owns transient `BrowserPage`; the catalog plan moves this ownership into `WebRuntime`.
- `TabManager` currently contains timer-based cleanup and exceeds 500 lines; split resource policy during migration.

## Changelog Delta

- 2026-07-12: Replaced generated placeholders with the current Swift/AppKit/WebKit structure.
- 2026-07-12: Added the native catalog runtime architecture and implementation plan to the documentation index.
- 2026-07-12: Added the detailed Phase 2 catalog model and AppKit-managed window implementation plan.
- 2026-07-12: Added the detailed Phase 3 WindowPool, ShellResetContract, SnapshotOverlay and lease-separation implementation plan.
- 2026-07-12: Added the detailed Phase 4 ResourceManager, L0-L5 Hibernation Policy, PressureMonitor, and SnapshotStore implementation plan and tests.
- 2026-07-13: Added the detailed Phase 5 AI Activity Protection (ActivityLease, UserScripts, and WKScriptMessageHandler) implementation and tests.
- 2026-07-13: Added Phase 6 crash backoff and system sleep/wake resource handling with tests.
- 2026-07-13: Added Phase 7 catalog runtime defaults, hibernation/activity-lease feature flags, and 100-cycle hardening tests.



---

*Auto-generated by `awkit init` — keep updated with `/codebase-sync`*
