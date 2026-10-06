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
- **兩個 Xcode 分工(2026-10 實測)**:
  - **Zig / GhosttyKit / Metal → Xcode 26.0**(`/Applications/Xcode.app`)。`xcode-select` 指向的
    `/Applications/Xcode-27.0.0.app` **沒有裝 Metal Toolchain**(`cannot execute tool 'metal'`)。
    ```bash
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # zig build / ensure-ghosttykit.sh 用這個
    ```
  - **cmux app 的 xcodebuild → Xcode 27**(Swift 6.4)。Xcode 26.0 的 Swift 6.2 編 v0.65.0 會**編譯器當掉**
    (`SILFunction type mismatch for 'ghostty_surface_clear_selection'`,DESERIALIZATION FAILURE,arm64/x86_64 都會)。
    這是上游 Swift 程式 + 舊編譯器的問題,跟 pixel-scroll 無關。上游 CI 用 Xcode 26.6,本機沒有。
    ```bash
    export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer   # xcodebuild 用這個
    ```
- **只 build arm64**(`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`):Arthur 的 Mac 是 Apple Silicon,不需要 x86_64 slice。
- **Rust(diff sidecar)**:cmux 用 `Native/DiffSidecar/rust-toolchain.toml` 釘 Rust 1.88.0,
  但 Arthur 的 PATH(`~/.zshenv:27`、`~/.zshrc:40`、fish `config.fish:79`)把
  `~/.rustup/toolchains/stable-aarch64-apple-darwin/bin` 放在 rustup proxy 前面,所以實際用的是 stable。
  stable 的 `rust-objcopy` 需要 `llvm-tools` component 才有 `libLLVM.dylib`,沒裝會
  `Library not loaded: @rpath/libLLVM.dylib` → sidecar 沒 strip → `verify-diff-sidecar-artifact.sh` 失敗。
  修法(已做):`rustup component add llvm-tools --toolchain stable`。stable 每次升級後若又壞,再跑一次。
- `~/.zshenv` 已把 `ZIG_GLOBAL_CACHE_DIR` 放到外接 SSD。`ghostty/.zig-cache` 留在 repo 內是預期行為。
- **建置前確認外接 SSD 有掛上**(`/Volumes/111360128 Lin Yan Yu/DevCache`)。

## 重新建置流程

### 1. 改了 ghostty Zig 碼之後 → 測試 + 重編 GhosttyKit
```bash
cd ghostty
zig build -Demit-macos-app=false                          # 快速編譯檢查
zig build test -Demit-macos-app=false -Dtest-filter='pixel scroll'   # 針對性測試(也跑 'extra row'、'Uniforms layout'、'overscan')
zig build test -Demit-macos-app=false -Dtest-filter=' ' -j2   # 全部 Zig 測試。filter 用一個空白(符合所有測試名);
                                                              # 不帶 filter 會多跑 macOS xcodebuild test,會失敗,不相關
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
export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "/Volumes/111360128 Lin Yan Yu/DevCache/xcode-derived/cmux-smoothnext-x27" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  INFOPLIST_KEY_CFBundleDisplayName="cmux Smooth Next" \
  PRODUCT_BUNDLE_IDENTIFIER="com.cmuxterm.app.smoothnext" build
```
約 15–20 分鐘。產物:`.../cmux-smoothnext-x27/Build/Products/Release/cmux.app`。Info.plist 的 `CFBundleDisplayName`
是 `$(PRODUCT_NAME)`,所以 build 完要用 PlistBuddy 改成 `cmux Smooth Next`(簽章腳本會做)。

### 3. Ad-hoc 簽章 + 安裝 → `scripts/smooth/sign-and-install.sh`
一個指令做完下面全部(改 display name、關 Sparkle、去受限權限、由內而外簽、裝到 /Applications、清 quarantine、驗章):
```bash
bash scripts/smooth/sign-and-install.sh
```
`spctl -a` 會說 `rejected` — ad-hoc 簽章本來就這樣(舊 Smooth 也是),拿掉 quarantine 後照樣能開。

細節(有坑,照順序做):
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
defaults write com.cmuxterm.app.smoothnext SUEnableAutomaticChecks -bool false   # 匯入會把舊版的 1 帶過來
```
注意:Smooth Next 第一次啟動時,舊 Smooth 已佔用 `~/.local/state/cmux/cmux.sock`,所以 Smooth Next 自動改用
`~/.local/state/cmux/cmux-501.sock`(上游的 fallback),互不干擾。socket 模式 `cmuxOnly`:只有在 Smooth Next
裡面開的 terminal 才能對它下 `cmux` 指令。
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
