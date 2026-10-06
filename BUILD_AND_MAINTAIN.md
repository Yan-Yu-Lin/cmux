# cmux Smooth — 建置與維護手冊

我們的 fork:在 cmux 的 ghostty submodule 加上 pixel-perfect 平滑捲動(phase 1)+ 滑鼠選取對齊修正。

| 版本 | App | Bundle ID | parent branch | ghostty branch | 基底 |
|---|---|---|---|---|---|
| 現行(新) | `/Applications/cmux Smooth Next.app` | `com.cmuxterm.app.smoothnext` | `smooth-scroll-v0.65.0` | `pixel-scroll-v0.65.0` | cmux v0.65.0 / ghostty `324c0273` |
| 舊版(保留) | `/Applications/cmux Smooth.app` | `com.cmuxterm.app.smooth` | `smooth-scroll` | `pixel-scroll` | cmux main `6cf7f5fc27`(0.64.22)/ ghostty `f76c132e5` |

兩個 app 可以同時開(不同 bundle ID、不同偏好設定 domain)。舊 branch 一律不動,確保舊版能重建。

## Repo 結構

| 位置 | 內容 |
|---|---|
| 本目錄(parent repo) | cmux app(Swift)。remote `mine` = github.com/Yan-Yu-Lin/cmux,`origin` = manaflow-ai/cmux(**永遠不要 push 到 origin**) |
| `ghostty/`(submodule) | 平滑捲動實作。remote `mine` = github.com/Yan-Yu-Lin/ghostty。`pixel-scroll-v0.65.0` = 7 個功能 commits + 1 個 API 遷移 + 1 個 Uniforms layout 重新定位 |
| `ghostty` branch `archive/phase2-tui-spring` | 已放棄的 phase 2(TUI 彈簧動畫)。失敗原因:alt screen 無 scrollback。細節見 PIXEL_SCROLL_IMPL_NOTES.md |
| `PIXEL_SCROLL_SPEC.md` / `PIXEL_SCROLL_PHASE2_SPEC.md` | 設計規格 |
| `PIXEL_SCROLL_IMPL_NOTES.md` | 實作筆記(檔案/行號/偏差/教訓/每次 port 的衝突解法) |

## Fork 在 parent repo 的改動(除了 docs)

- `.gitmodules`:ghostty URL → Yan-Yu-Lin/ghostty,branch → `pixel-scroll-v0.65.0`
- `Packages/macOS/CmuxUpdater/.../UpdateController.swift`:`com.cmuxterm.app.smooth*` 視為 DEV-like bundle →
  **Sparkle 不排程檢查、手動檢查也被擋**。(只靠 Info.plist 不夠:SUFeedURL 空白會 fallback 回上游 appcast,
  而且 cmux 啟動時會強制打開 automatic checks。)舊的 Smooth app 沒有這個保護,它的 SUFeedURL 仍指向上游,別按更新。

## 工具鏈(必讀)

- **Zig 必須用 0.16.0**(cmux v0.65.0 的 ghostty pin 也是 `minimum_zig_version = 0.16.0`)。
- **Xcode 用 26,不要用 27**:`xcode-select` 目前指向 `/Applications/Xcode-27.0.0.app`,它**沒有裝 Metal Toolchain**
  (`cannot execute tool 'metal'`)。cmux v0.65.0 的 `.xcode-version` 是 `26`。所有 zig / xcodebuild 指令前加:
  ```bash
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # Xcode 26.0,Metal Toolchain 已安裝
  ```
- `~/.zshenv` 已把 `ZIG_GLOBAL_CACHE_DIR` 放到外接 SSD。`ghostty/.zig-cache` 留在 repo 內是預期行為。
- **建置前確認外接 SSD 有掛上**(`/Volumes/111360128 Lin Yan Yu/DevCache`)。

## 重新建置流程

### 1. 改了 ghostty Zig 碼之後 → 測試 + 重編 GhosttyKit
```bash
cd ghostty
zig build -Demit-macos-app=false                          # 快速編譯檢查
zig build test -Demit-macos-app=false -Dtest-filter='pixel scroll'   # 針對性測試(也跑 'extra row'、'Uniforms layout'、'overscan')
zig build test -Demit-macos-app=false -Dtest-filter=''    # 全部 Zig 測試(不帶 filter 會多跑 macOS xcodebuild test,會失敗,不相關)
cd ..
CMUX_GHOSTTYKIT_NO_PREBUILT=1 ./scripts/ensure-ghosttykit.sh   # 用上游腳本建 ReleaseFast universal xcframework(正確的 flags/flavor)
```
`ensure-ghosttykit.sh` 以 ghostty HEAD SHA + flavor 當快取 key,存在 `~/.cache/cmux/ghosttykit/<sha>-crashsubdir-cmux-crash-sentry-off-noi18n-v2/`,
並把 repo 根目錄的 `GhosttyKit.xcframework` symlink 指過去。tree 必須乾淨(先 commit),否則 key 會帶 `-dirty-`。
`ghostty/macos/GhosttyKit.xcframework` 只有 arm64 slice,不是給 app 用的,別理它。

**改了 Metal `Uniforms` struct(或上游改了)→ 一定要重新量 offset**,`Uniforms layout matches the MSL definition`
測試寫死了 offset。量法:寫一個同樣 struct 的 compute kernel,把 `&field - base` 寫回 buffer(見 IMPL_NOTES 2026-10-06 那節)。

### 2. Build app — Release(最終版)
上游 Release 要求 Manaflow 的開發者憑證,本機沒有 → 跳過簽章、事後 ad-hoc 簽。DerivedData 放外接 SSD:
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "/Volumes/111360128 Lin Yan Yu/DevCache/xcode-derived/cmux-smoothnext" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  INFOPLIST_KEY_CFBundleDisplayName="cmux Smooth Next" \
  PRODUCT_BUNDLE_IDENTIFIER="com.cmuxterm.app.smoothnext" build
```
產物:`.../cmux-smoothnext/Build/Products/Release/cmux.app`。注意 Info.plist 的 `CFBundleDisplayName` 是 `$(PRODUCT_NAME)`,
所以 build 完要用 PlistBuddy 把 `CFBundleDisplayName` 改成 `cmux Smooth Next`(簽章之前做)。

### 3. Ad-hoc 簽章(有坑,照順序做)
**坑:不能直接用 repo 的 `cmux.entitlements` 簽** — `keychain-access-groups` 與
`com.apple.developer.web-browser.public-key-credential` 是受限權限,ad-hoc 簽章帶著它們 macOS 會拒開。

```bash
# a. 產生去除受限權限的 entitlements(從 cmux.entitlements 移除上述兩項)
# b. 由內而外簽:Frameworks 裡的 .xpc / Updater.app / .framework / .dylib,PlugIns 裡的 .plugin,
#    Resources/bin 與 Helpers 的執行檔(全部 codesign --force --sign -)
# c. 最後簽 app 本體:codesign --force --sign - --entitlements <去除版.entitlements> "<app>"
# d. 複製到 /Applications/"cmux Smooth Next.app" 後:xattr -dr com.apple.quarantine "<app>"
# e. codesign --verify --deep --strict "<app>"
```
代價:鑰匙圈登入狀態可能要重登、瀏覽器面板 passkey 不可用。終端機功能不受影響。

**絕對不要動正在用的 `/Applications/cmux Smooth.app`**(不要覆蓋、不要 kill)。新版裝成獨立的 app。

### 4. 設定複製(只做這個,其他不自動搬)
```bash
defaults export com.cmuxterm.app.smooth /tmp/p.plist
defaults import com.cmuxterm.app.smoothnext /tmp/p.plist
```
共用不需複製:`~/.config/ghostty/config`、`~/.config/cmux/*.json`。

### 5. Debug build(開發測試用)
```bash
./scripts/reload.sh --tag <tag>     # tag 化 build:獨立 app 名/bundle id/socket
```

## 跟上游更新(下一次)

1. 讀出目標 cmux tag 實際 pin 的 Ghostty SHA:`git ls-tree <tag> ghostty`。**不要追 Ghostty absolute tip**。
2. ghostty:從目前 branch 開新 branch(例如 `pixel-scroll-v0.66.0`),`git rebase --onto <新 pin> <舊 pin>`。
   衝突重點:`generic.zig`(row 索引:上游 `top_overscan_rows` + 我們的 `row_offset`)、`shaders.metal`(兩個 shift 相加)、
   `render.zig`(測試互相 append)、`metal/shaders.zig`(Uniforms layout 要重量)。詳見 IMPL_NOTES。
3. 跑 focused tests → `ensure-ghosttykit.sh`。
4. parent:從目前 branch 開新 branch,`git merge <tag>`;衝突通常只有 `docs/ghostty-fork.md` 與 ghostty pointer
   (pointer 用 `git update-index --cacheinfo 160000,<新 ghostty HEAD>,ghostty`)。記得 `git submodule update --init vendor/bonsplit`。
5. Release build → 簽章 → 裝成新 app → 驗證 → `git push mine <新 branches>`。

## 磁碟紀律

- `ghostty/.zig-cache` 一輪完整編譯 ~11GB,**專案告一段落就 trash 掉**(會自動重建)
- DerivedData(外接 SSD `DevCache/xcode-derived/`)每個 ~7GB,淘汰的隨手清
- `~/.cache/cmux/ghosttykit/` 留最新 SHA 那份即可

## 已知限制

- nvim / TUI(alt screen)捲動 = 逐行跳(設計限制,見 phase 2 歸檔)
- 平滑捲動只作用於 primary screen scrollback;滑鼠回報模式下自動退回逐行
- OpenGL/GTK 路徑僅保證編譯,未在 Linux 驗證
- iOS:我們的 extra rows 在 iOS 編譯期關掉,iOS 用上游自己的 pixel scroll
