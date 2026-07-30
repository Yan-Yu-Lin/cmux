# cmux Smooth — 建置與維護手冊

我們的 fork:在 cmux 的 ghostty submodule 加上 pixel-perfect 平滑捲動(phase 1)+ 滑鼠選取對齊修正。
成品:`/Applications/cmux Smooth.app`(Release、ad-hoc 簽章、無 DEV 紅字)。

## Repo 結構

| 位置 | 內容 |
|---|---|
| 本目錄(parent repo) | cmux app(Swift)。branch `smooth-scroll`,remote `mine` = github.com/Yan-Yu-Lin/cmux |
| `ghostty/`(submodule) | 平滑捲動實作。branch `pixel-scroll`(7 commits on 80d7fb35a),remote `mine` = github.com/Yan-Yu-Lin/ghostty |
| `ghostty` branch `archive/phase2-tui-spring` | 已放棄的 phase 2(TUI 彈簧動畫)。失敗原因:alt screen 無 scrollback,捲出的行立即銷毀,無內容可動畫。細節見 PIXEL_SCROLL_IMPL_NOTES.md |
| `PIXEL_SCROLL_SPEC.md` / `PIXEL_SCROLL_PHASE2_SPEC.md` | 設計規格 |
| `PIXEL_SCROLL_IMPL_NOTES.md` | 實作筆記(檔案/行號/偏差/教訓) |

## 工具鏈(必讀)

- **Zig 必須用 0.15.2**:`/opt/homebrew/opt/zig@0.15/bin/zig`。PATH 上的 zig 是 0.16,build 會直接 compile error 擋掉。
  每次 build 前:`export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"`
- Metal toolchain 需已安裝(曾用 `xcodebuild -downloadComponent MetalToolchain` 修過)。

## 重新建置流程

### 1. 改了 ghostty Zig 碼之後 → 重編 GhosttyKit
```bash
cd ghostty
export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"
zig build -Demit-macos-app=false          # 快速編譯檢查(迭代用)
zig build test -Dtest-filter=<name>       # 針對性測試
zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast   # 最終(很慢)
```
注意:cmux 的 `scripts/ensure-ghosttykit.sh` 以 HEAD commit hash 做快取 key,存於
`~/.cache/cmux/ghosttykit/<hash>-.../`。tree 乾淨時它認得本地 build;dirty tree 會拒用 prebuilt。

### 2. Build app — Debug(開發測試用)
```bash
export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"
./scripts/reload.sh --tag <tag>     # tag 化 build:獨立 app 名/bundle id/socket,可與正式版並存
```
產物在 `~/Library/Developer/Xcode/DerivedData/cmux-<tag>/Build/Products/Debug/`。
注意:`reload.sh` 會 kill 同 tag 的執行中 app;不同 tag 不互相影響。

### 3. Build app — Release(最終版)
上游 Release 設定要求 Manaflow 的開發者憑證,本機沒有 → 必須跳過簽章、事後 ad-hoc 簽:
```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-release-smooth \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  INFOPLIST_KEY_CFBundleDisplayName="cmux Smooth" \
  PRODUCT_BUNDLE_IDENTIFIER="com.cmuxterm.app.smooth" build
```

### 4. Ad-hoc 簽章(有坑,照順序做)
**坑:不能直接用 repo 的 `cmux.entitlements` 簽** — 其中 `keychain-access-groups` 與
`com.apple.developer.web-browser.public-key-credential` 是受限權限,ad-hoc 簽章帶著它們
macOS 會直接拒開("The application can't be opened",spctl rejected)。

```bash
# a. 產生去除受限權限的 entitlements(用 python/plutil 從 cmux.entitlements 移除上述兩項)
# b. 由內而外簽:先簽 Frameworks 裡的 .xpc / Updater.app / .framework 與 Resources/bin 的執行檔
#    (全部 codesign --force --sign -)
# c. 最後簽 app 本體:codesign --force --sign - --entitlements <去除版.entitlements> "<app>"
# d. 裝進 /Applications 後:xattr -dr com.apple.quarantine "<app>"
```
代價:鑰匙圈登入狀態可能要重登、瀏覽器面板 passkey 不可用。終端機功能不受影響。

### 5. 設定複製(Debug/Release/正式版各自獨立的 preferences domain)
```bash
defaults export com.cmuxterm.app - > /tmp/p.plist        # 從正式版匯出
defaults import com.cmuxterm.app.smooth /tmp/p.plist     # 匯入 Smooth 版
```
共用不需複製:`~/.config/ghostty/config`、`~/.config/cmux/*.json`。

## 跟上游更新(未來)

1. `cd ghostty && git fetch origin && git rebase origin/main pixel-scroll`(7 個 commits,衝突點多半在
   render.zig / generic.zig / shaders — 見 IMPL_NOTES 的檔案清單)
2. 重編 xcframework → parent repo `git pull` 上游 → 重 build app → 重簽
3. 推 fork:`git push mine pixel-scroll`(submodule)、parent 提交 submodule pointer 後 `git push mine smooth-scroll`

## 磁碟紀律

- `ghostty/.zig-cache` 一輪完整編譯 ~11GB,**專案告一段落就 trash 掉**(會自動重建)
- DerivedData 每個 tag ~7GB,淘汰的 tag 隨手清
- `~/.cache/cmux/ghosttykit/` 留最新 hash 那份即可,舊的可刪

## 已知限制

- nvim / TUI(alt screen)捲動 = 逐行跳(設計限制,見 phase 2 歸檔)
- 平滑捲動只作用於 primary screen scrollback;滑鼠回報模式下自動退回逐行
- OpenGL/GTK 路徑僅保證編譯,未在 Linux 驗證
