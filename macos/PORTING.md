# 移植记录：TigerClaw → macOS InputMethodKit

参考实现：`/Users/viui/Desktop/Tigirl macOS/macos/`（Tigirl 0.3.4）。
本目录是 **TigerClaw** 的 macOS 前端，不是把 Tigirl 换个名字：词库格式、
组句引擎、配置项、方案名和五 gram 模型都来自 TigerClaw 主线。

## 1. 为什么不是“重写一个输入法”

TigerClaw 的 `next/TigerClaw.Core.Native/` 里已经有一层与 Win32 解耦的
C++ 运行时：

- `RuntimeLexicons`：配置 + 当前方案 + 主码表 + 拼音反查表 + 选重键；
- `RuntimeInput`：中文/英文状态、普通编码、拼音反查、混合输入、整句会话、
  输出后处理、学习回执；
- `RuntimeSentenceState` / `RuntimeSentenceInput`：TCSKNM03 Q8 五 gram 的
  Beam、上下文、锁定前缀、自学习；
- `OrdinaryComposition` / `ChineseInputSession`：四码自动上屏、选重、翻页、
  标点、退格、Tab/Enter/Esc。

Windows 专用部分只有：TSF 前端（`BimeTSF2`）、命名管道、Overlay、Dialog、
Hook、注册表/启动项。macOS 适配层要做的只是：

```
IMKInputController  <=>  TigerClawEngine  <=>  RuntimeInput
```

因此这里直接编译同一批 Core 源文件，`macos/CMakeLists.txt` 里的源列表
就是 Core.Native 的 portable 子集（不含 `main.cpp`、`RuntimeProtocol.cpp`、
`RuntimePipeServer.cpp`、`RuntimeUiPublisher.cpp` 等）。

## 2. Core 的 macOS 可移植性修改

这些修改是“让同一份 Core 在 Apple libc++/Clang 上编译并保持语义”，
不是 fork 一套引擎。

### 2.1 `std::stop_token` 缺失

Xcode 16.1 的 libc++ 没有实现 C++20 stop-token（连 `<stop_token>` 都只有
声明）。Core 的 `SentenceDecodeWorker`、`SentenceServiceLifecycle`、
`SentenceLattice` 用了 `std::stop_source/token`。

处理：`compat/stop_token` 用互斥量 + 回调实现最小可用版本，构建时
`-include` 强制包含；Windows 构建不受影响。

### 2.2 `std::atomic<std::shared_ptr<T>>` 缺失

`RuntimeLexicons` 和 `SentenceLearningStore` 用 C++20 的
`atomic<shared_ptr>` 做快照发布；MSVC STL 有，Apple libc++ 没有。

处理：新增 `AtomicSharedPtr.h`（mutex + shared_ptr 的 load/store/exchange），
替换两个声明。语义一致，代价是这两处快照读取多一次无竞争互斥。

### 2.3 路径解析

`ResolveCodeRoot` 非 Windows 分支原本直接 `throw`。macOS 分支：
绝对路径原样，相对路径相对“可执行目录”，`absolute().lexically_normal()`。

### 2.4 码表文件顺序

`GetOrderedLexiconFiles` 原本依赖 Windows NLS 排序键（`LCMapStringEx`），
非 Windows 直接 `throw`。macOS 分支：

- 只接受 `.txt` / `.dict.yaml`；
- 方案同名文件（`<schema>.txt` / `<schema>.dict.yaml`）优先；
- 其余按大小写折叠后的确定性顺序稳定排序。

这保证 `tigress.dict.yaml`、`tigress_ci.dict.yaml`、`tigress_simp_ci.dict.yaml`
和 `常用符号.txt`/`快符.txt` 的加载顺序稳定；候选最终顺序仍由词频稳定排序
决定，与 Windows NLS 的差异只在同频候选的并列顺序。

### 2.5 整句候选分页

原 `RuntimeInput::ReadPage` 对整句只返回前 `pageSize` 个候选，但
`SelectedIndex` 可以超过 5；↑↓ 选到第 6 个时候选框仍显示前 5 个。

处理：整句页按当前选中项计算 `pageIndex`，只取该页；`CandidatePage.total`
仍是全部候选数。UI 的页码/高亮因此对长句也正确。

### 2.6 鼠标选择 / 加词 API

新增：

- `RuntimeSentenceInput::SelectCandidate(index)`：选中并立即 `FinishSelected`；
- `RuntimeInput::SelectSentenceCandidate(index)`：走外部结果后处理（历史、
  重复缓冲），返回 `PostProcessResult`；
- `RuntimeInput::AddWord(code, text)`：调用 `RuntimeLexicons::AdjustCandidate`
  的 `Add`，同时追加 `用户调整.txt`。

字词方案的鼠标点选没有新 API：适配层把点击行号换成对应的数字键
（第 10 项用 `0`），完整复用 `SelectionKeys` / 页状态 / 学习语义。

## 3. InputMethodKit 适配层

### 3.1 Bundle 身份

- Bundle ID 必须是 `com.viui.inputmethod.TigerClaw`
  （`inputmethod` 在倒数第二段）；`InputMethodConnectionName` 为
  `com.viui.inputmethod.TigerClaw_Connection`。
- 模式 ID `com.viui.inputmethod.TigerClaw.Hans`。
- `Info.plist` 的 `ComponentInputModeDict`、`tsInputModeListKey`、
  `tsVisibleInputModeOrderedArrayKey` 与参考实现同构。
- `zh-Hans.lproj/InfoPlist.strings`、`en.lproj/InfoPlist.strings` 都以
  **输入源 ID** 为键写“虎爪”，否则菜单显示裸 ID/英文名。

### 3.2 入口

```objc
NSApplication *app = [NSApplication sharedApplication];
IMKServer *server = [[IMKServer alloc] initWithName:connection
                                   bundleIdentifier:identifier];
TigerClawPreloadEngine();   // 词库解析，约 0.5–1.5 s
[app run];
```

不能用 `initWithName:controllerClass:delegateClass:`（macOS 14 会 SIGSEGV）。
`IMKServer` 先创建，再预热词库，缩短“可服务”时间。

### 3.3 按键路径

只实现 `handleEvent:`，不实现 `inputText:`；否则 IMK 走文本解包路径，
方向键/翻页键永远不会进输入法。`recognizedEvents:` 返回
`NSKeyDownMask | NSFlagsChangedMask`。

Windows VK 映射：字母 `'A'..'Z'`、数字 `'0'..'9'`、标点必须用
`VK_OEM_*`（`;`=186、`'`=222、`,`=188、`.`=190、`/`=191、`-`=189、
`=`=187、`[`=219、`]`=221、`\`=220、`` ` ``=192）。ANSI keyCode 表完整
0..49，空格/回车/Tab/删除/方向键单独映射。

### 3.4 marked text 与上屏

- `setMarkedText:selectionRange:replacementRange:`（不是 `selection:`）；
- 上屏顺序：先 `setMarkedText:@""` 再 `insertText:`，避免“编码+候选”叠加；
- 整句是异步 Beam/五 gram：每 40 ms `Capture()` 一次（`NSTimer`），
  直到不再 composing；候选列表和 marked code 都从引擎快照刷新；
- 只在文本真的变化时调用 `setMarkedText`，减少闪烁。

### 3.5 候选窗

- `NSPanel` + `NSWindowStyleMaskNonactivatingPanel`，
  `hidesOnDeactivate = NO`，`level = NSStatusWindowLevel`，
  `orderFrontRegardless`；`canBecomeKeyWindow/MainWindow` 返回 NO。
- 面板进程级单例：每个 IMK client 一个 controller，但共用一块候选面板，
  避免多窗口/多文档时出现两份候选。
- 定位：`firstRectForCharacterRange:`（当前 selection）→
  `attributesForCharacterIndex:lineHeightRectangle:`（Squirrel 方案）→
  `NSNotFound` 探测 → 鼠标位置；下方放不下翻到光标上方，再夹到
  `visibleFrame`。
- 鼠标点选回调到 controller；字词走数字键，整句走
  `SelectSentenceCandidate(index)`。
- 布局：`候选布局` 1/3 横向，2/4 纵向；序号、页码、选中高亮。

### 3.6 激活/失活

IMK 在候选面板出现、切换文档时会反复 `activateServer`/`deactivateServer`。
最初实现把“client 指针变化”当成切换应用，直接 `Cancel()`，导致打一半的
编码被清掉、方向键/空格变成普通按键。

处理：

- 记录 `bundleIdentifier`，只有**应用变了**才 Cancel；
- 同一个应用重新激活时，从 `Capture()` 恢复 marked text 和候选；
- `deactivateServer` 只隐藏面板/停 timer，不清引擎组合。

### 3.7 输入源启用

全新安装后 `TISSelectInputSource()` 常返回 `paramErr (-50)`。原因不是
Bundle ID，而是父级 `TISInputSourceID`（`com.viui.inputmethod.TigerClaw`）
还没有 enabled，TextInputServices 的状态是异步落盘的。

处理：`--enable-input-source` 先 enable 父级，再 enable 模式，跑 0.6 s
runloop，再 select；成功后再跑 0.4 s。验证：

```
com.viui.inputmethod.TigerClaw       enabled=1
com.viui.inputmethod.TigerClaw.Hans  enabled=1 selectable=1 selected=1
```

如果仍失败，注销重登或手动到“系统设置 → 键盘 → 输入法”添加。

### 3.8 输入法菜单的 sender 不是 NSMenuItem

IMK 不把 `NSMenuItem` 直接交给 `selectSchema:`；命令通过
`doCommandBySelector:commandDictionary:` 下发，sender 是 `NSDictionary`。
原实现执行 `sender.representedObject`，抛
`-[__NSDictionaryM representedObject]: unrecognized selector`，菜单点击
在控制台留下异常、方案却不切换——外观上就是“虎整句用不了”。

处理：`SchemaNameFromSender()` 同时接受 `NSMenuItem` 和 command
dictionary，从字典的 `representedObject` / 菜单项对象 / `tag` 取方案名；
菜单项仍设置 `representedObject` 和 `tag` 作为双保险。切换成功后清 marked
text、候选窗和组合状态，并写入 `config.txt`。

注意：IMK 的“重新载入词库/打开配置目录”也走同一条命令路径，因此它们
同样不能再假设 sender 是菜单项。

### 3.9 Chromium/Electron 的 `inputText:` 路径

Chrome、DeepSeek Harness、VS Code 等 Chromium/Electron 客户端不会走
`handleEvent:`，而是把按键以
`inputText:key:modifiers:client:` 交给输入法。只实现 `handleEvent:` 时，
这些客户端直接把字母原样插入，marked text、候选窗和上屏都不会出现。

处理：

- `inputText:key:modifiers:client:` 用硬件 keyCode + 修饰键映射到同一个
  `PhysicalKey`，再走 `processPhysicalKey:client:`；
- Backspace 在该路径下是 `key=51 string="^H"`（长度 2），不能按“多字符文本”
  丢弃，控制键必须放行；
- 方向键也以单字符控制串进入 `inputText:`，组合期间左右/Home/End 直接吞掉，
  ↑↓ 在字词方案转成翻页键；`didCommandBySelector:` 仍保留给其他客户端；
- `inputText:client:` 仅记录并返回 NO（粘贴/多字符文本交给客户端）。

实测（Chrome，系统级安装）：

- `u` → marked `u`，空格 → `的`；
- 组合中 Backspace → 清码，不删正文；
- `ae` ↓ `1` → 第二页第一候选 `乁`；
- TextEdit 同时保持 `u` 空格 → `的`。

**客户端缓存**：Chromium 在启动时枚举输入法；安装/更新虎爪后必须完全退出并
重开 Chrome/DeepSeek，光切换输入源不够。DeepSeek Harness 当前会话仍在用旧
输入法列表，重启后才会走新路径。

### 3.10 LaunchServices 残留

用 `build/TigerClaw.app` 注册过一次后，LaunchServices 会一直指向 build 路径；
即使安装了 `~/Library/Input Methods/TigerClaw.app`，输入源也可能变灰。
`install.sh` 会 `lsregister -u <build app>`，再 `-f <installed app>`。

## 4. 数据与首次运行

App 包内：

```
Contents/Resources/码表/虎码字词
Contents/Resources/码表/虎整句
Contents/Resources/拼音反查码表/拼音.txt
Contents/Resources/Models/sentence-fivegram-mobile.bin
```

首次运行时复制前三个到：

```
~/Library/Application Support/TigerClaw/
```

配置 `ConfigDefaults` 生成 `config.txt`；默认 `码表存储位置=码表`，
相对 `RuntimeLexicons` 的 executable directory（这里就是 App Support）。
`当前码表` 首次强制写 `虎码字词`（`LoadSnapshotNoLock` 本来会把 fallback
方案写回配置，若不显式写入会默认落到字典序更小的 `虎整句`）。

整句模型不复制，直接 mmap App 包内文件；只有切到 `虎整句` 或启动时配置
就是整句才映射。

## 5. 实测记录（2026-10-18/19，arm64 macOS 14.8.7）

构建：

```
cmake -S macos -B macos/build -DCMAKE_BUILD_TYPE=Release \
  -DTIGERCLAW_SENTENCE_MODEL=.../sentence-fivegram-mobile.bin
cmake --build macos/build -j8
ctest --test-dir macos/build --output-on-failure
# 1/1 Test #1: tigerclaw_engine ... Passed 2.61 sec
```

注册：

```
TISRegisterInputSource: success
enable input source: success
com.viui.inputmethod.TigerClaw.Hans  enabled=1 selectable=1 selected=1
```

TextEdit 手工/半自动输入（System Events 发真实键盘事件）：

| 操作 | 结果 |
| --- | --- |
| `u` + 空格 | `的` |
| `u` + `1` | `的`（数字选重） |
| `u` + `;` | `工作`（分号次选） |
| `f` + 空格 | `一` |
| `tuja` | `我们`（四码无重自动上屏） |
| `j` + ↓ | 第二页候选，`ae` 显示 `1/11`→`2/11` |
| `ae` 第二页 + `1` | 该页第一候选 |
| `,` / `.` | `，` / `。` |
| 退格 / Esc / Enter / Tab | 删码 / 取消 / 上屏原码 / 清屏 |
| Shift 两次 | 中→英→中，英文 `abc` 原样上屏 |
| `` ` `` + `ba` | 吧/把/八/爸/巴（拼音反查） |
| 整句 `t` | 我 / 我们；↓ + 空格 → `我们` |
| 鼠标点第二行 | 上屏该候选 |
| 候选窗跟随光标 | 三次换行后窗口 Y 下移 28 px |

截图见 `docs/candidates-vertical.png`、`docs/candidates-horizontal.png`、
`docs/pinyin-reverse.png`。

加词引擎验收：

```
e.AddWord(u"zzzz", u"测试") == 1
用户调整.txt: {添加}zzzz\t测试
```

（UI 的 Ctrl+= 加词窗口已接；用引擎探针验证了 API 与持久化。）

## 6. 尚未完成/未验证

- **整句自学习**：`IssueLearningReceipt`/`AcknowledgeLearningReceipt` 已接，
  但普通整句选择产生的 `TakeLearning` 事件为 0（引擎只对“纠正”类选择生成
  事件），所以没有写出 `自学习-虎爪.txt`。Tab 锁定自学习未做端到端验收。
- **完整设置窗口/皮肤/Overlay/状态栏**：Windows 版是独立进程；本移植只保留
  候选窗和输入法菜单，配置通过 `config.txt` 修改，改完用菜单“重新载入词库”
  或重启输入法生效。
- **导出词库**：`RuntimeLexicons::ExportLexicon` 存在，但没有接菜单。
- **全拼方案**：仓库只有 `虎爪全拼`/`虎爪小鹤双拼` 的 `schema.json`，缺少
  Wanxiang 词库与 KenLM；未打包，也未启用。
- **候选布局 5（仅编码）**：目前按纵向候选绘制；没有专门的“只显示编码”
  面板。
- **物理键盘全量验收**：只在 TextEdit 与系统输入源层面验证；微信/QQ/Chrome/
  Electron 等客户端的客户端兼容性仍需逐项测试。
- **签名/分发**：ad-hoc；没有 Developer ID / 公证，pkg 也没有签名。

## 7. 复现命令

```sh
export TIGERCLAW_SENTENCE_MODEL="/path/to/sentence-fivegram-mobile.bin"
macos/build.sh
macos/install.sh
ctest --test-dir macos/build --output-on-failure
```

调试时可：

```sh
launchctl setenv TIGERCLAW_DEBUG 1     # 打印每个按键的 handled/composing/候选
launchctl unsetenv TIGERCLAW_DEBUG
log show --last 5m --predicate 'process == "TigerClaw"'
```
