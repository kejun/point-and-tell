# Point & Tell：核心逻辑契约

Point & Tell 是 macOS 原生录屏讲解工具：屏幕与麦克风写入本地 MOV，用户主动标记/保存画笔截图形成独立卡片，再用真实 ASR 时间关联讲解，经人工校对后离线导出。

本文件适用于全仓库；修改子目录前检查更近的 `AGENTS.md` / `AGENTS.override.md`，局部冲突以更近的指令为准。当前行为以待修改提交的实际代码为准，文档可能滞后；未合入 PR 和已分发包不是当前源码的替代品。下面是改动的验收约束，不是“现有实现没有缺陷”的保证。用户明确要求改变核心行为时，可以调整契约，但须在同一改动中说明语义变化、旧数据处理与回归测试，不要把类名、算法常数或当前缺陷永久冻结。

需要跨模块追踪或已知风险时读 [逻辑与使用链路](docs/USER-AND-SYSTEM-FLOWS.md)；按改动选择相关章节，不必每次通读。具体源码入口与版本快照在该文档中。

## 必须保住的业务关系

1. **截图事件拥有卡片，ASR 不拥有卡片。** 录制中的 bookmark / 保存后的 pen 事件先保存图片和独立卡片，无语音、无匹配或同一时刻的不同截图仍可独立存在。卡片身份来自截图事件，不随 ASR 句子 ID、断句或重试变化；同一事件不能重复成卡，同时间按原事件顺序稳定排列。不得在转写完成、打开项目或导出时隐式抽帧、按句子新造截图卡，或把多张截图卡合并成一张。手动卡片、手动提取和旧式自动图片须保留各自来源，不能冒充录制截图。

2. **所有关联都回到同一条真实媒体时间轴。** 截图时刻取录制输出的媒体时间；冻结截图时刻与画笔编辑持续区间分开保存。WAV 分片起点保留原 MOV 的 PTS 偏移，ASR 的片内时间只加一次该偏移；不能用墙钟、文件时长等分或文字长度猜时间。词时间完整且能无损对应原文才按词拆分；否则保留句级/无时间精度。有效最终正文缺时间仍可保存为已完成源转写，缺词时间不自动重传；空结果或检测到的未完成流不能当作成功。截图前、期间、之后的讲解均可成为候选；歧义显示需校对，不复制同一语音单位给多个自动卡片。删除卡片不删除原截图的时间分界，避免邻卡重新吞掉已删除讲解。

3. **源数据、人工结果和生成建议分层保留。** MOV、截图和已写出的音频是可恢复的用户资料；重试/导出/删卡不得改写或清理这些原件。自动重算仅更新仍未被编辑的生成内容；用户文字、时间、配图、顺序、删除抑制记录和旧项目已存布局优先。迁移须可重复且不丢数据；缺少新字段可兼容，不能因 chunks 为空就清空合法的旧版顶层 transcripts。改变模型/迁移时一起覆盖旧项目 → 打开 → 编辑/删除 → 重试 → 保存重开 → 导出。

4. **落盘成功决定提交，取消不能等于丢弃。** `ProjectStore` 的读改写由单一串行所有者协调，manifest 原子替换，项目内路径拒绝越界与符号链接。新增截图、删卡、换图、手动抽帧须在保存成功后提交可见状态，失败保留原状态或可重试草稿。文字/时间或 ASR 结果保存失败，不能显示已保存，也不能让 New/Open/退出/更新静默丢弃未落盘内容。ASR 取消停止后续上传，已完成结果和媒体保留；本地步骤尚未结束时如实显示等待，不承诺立即终止。注意：链路文档记录了现有 ASR 取消/保存缺口，修改这些路径时补失败用例，不把缺口当正确基线。

5. **录制、转写与界面是有先后关系的状态机。** 录制在切换应用、使用画笔时继续；截图不得包含 HUD/画笔控件。重复 Start/Stop 和晚到回调不能重复启动、封口、成卡或覆盖另一项目；选定输入断开不得悄悄换设备，有局部 MOV 也不能掩盖录制错误。自动转写只在本次成功录制结束、本地音频检查及项目保存成功、上传许可仍有效后触发一次；打开旧项目、取消或失败不自动发起/重试。重试只发送未完成/失败片；无可靠时间的完成片仅在用户同意重新上传后重发。编辑和导出不可与变更同一项目的异步流程交叉提交。

6. **导出与更新不能绕过用户数据边界。** 编辑器与导出使用同一已提交卡片及顺序、文字、时间和所选图片；预览/刷新不得隐式改配图。HTML/Markdown/JSON 保留同一对应关系，未知时间或缺图如实显示；离线输出对正文及 HTML 属性中的不可信项目内容做上下文转义，不带原 MOV/WAV、凭据、诊断或源绝对路径。API Key 仅保存在 Keychain，项目/日志只保留脱敏诊断。保留导出体积上限、项目外目的地及 bundle 暂存后提交行为。更新须先满足无活动工作和保存成功，退出安装时再核对；取消恢复编辑。保留签名校验、不可覆盖的版本归档和固定提交下载地址，不以禁用安全检查让更新测试通过。

## 改动影响与验证

先确定改动命中上面哪条关系，再验证该区域及紧邻上下游；以可观察结果断言，不只断言按钮/状态值。行为改动补充能复现旧问题或证明新语义的测试。以下测试类均在 `Tests/PointAndTellCoreTests/`；组合改动取各行的并集。

| 改动区域 | 至少覆盖的相邻链路 / 回归入口 |
| --- | --- |
| 录制、HUD、画笔、时钟、抽音 | 重复开始/停止、切换应用、设备中断、截图 → MOV/WAV → ASR 偏移；`CaptureDiagnosticsTests`、`CaptureFailureTests`、`ASRWAVAudioTests`、`WorkflowReadinessTests`，macOS audio/UI smoke，相关设备检查 |
| ASR 请求、解析、取消、重试 | JSON/SSE → 分片保存 → 卡片保留；`ASRClientTests`、`ASRTransportTests`、`ASRResponseParserTests`、`ASRErrorTests`、`ASRProjectUpdatesTests`，时间解析变更加测 `ScreenshotCardsTests`、`TranscriptAlignmentTests`；无请求取消/第二片保存失败后重开 |
| 截图卡、匹配、模型、持久化、编辑器 | 同时刻/无匹配、词/句/无时间、人工编辑/删卡后重试、旧项目重复打开；`ScreenshotCardsTests`、`ReviewCardGroupingTests`、`ReviewCardDeletionTests`、`ProjectTests`、`TranscriptAlignmentTests`、`FrameMatcherTests`，UI smoke 与导出对照 |
| 导出 | 编辑器 → HTML/Markdown/JSON、无图/坏图/危险文本及关联元数据属性/大小限制、失败不伤源项目；`ExporterTests`、`TranscriptAlignmentTests`，UI fixture → WebKit 验证 |
| 设置、更新、打包、依赖 | 许可撤回/重复自动触发、忙碌/未保存时安装门禁；`WorkflowReadinessTests`、`UpdateSafetyTests`，release metadata、Universal 构建与隔离更新测试 |

从仓库根目录运行，命令的当前定义见 `.github/workflows/macos.yml`：

- Swift 5.9+：`swift test`；定位问题可用 `swift test --filter ScreenshotCardsTests` 等实际类名。纯 Core 在 Linux 可测；不要以此替代 AppKit/AVFoundation 验证。
- 发布脚本或元数据：`python3 -m unittest discover -s scripts/tests -v`；有完整已分发归档时运行 `python3 scripts/verify-releases.py`。
- macOS 原生/依赖/打包改动：`ARCH=universal scripts/build-app.sh`，再按区域运行以下验证；应用路径保持引号。
  - `"dist/Point & Tell.app/Contents/MacOS/PointAndTell" --audio-smoke-test "$PWD/dist/audio-smoke"`
  - `"dist/Point & Tell.app/Contents/MacOS/PointAndTell" --smoke-test "$PWD/dist/ui-smoke"`
  - 导出 UI fixture 生成后：`swift scripts/verify-export.swift "$PWD/dist/ui-smoke/timeline.html" "$PWD/dist/ui-smoke"`
  - 更新改动：`scripts/test-update-tools.sh`、`scripts/test-update-install.sh`（隔离临时应用/测试密钥，不对用户安装或生产 feed 测试）。

支持底线是 macOS 11（包含 11.7.11 Intel / 8 GB 使用场景）及 Intel/Apple Silicon Universal。Core 保持不依赖 AppKit/AVFoundation，平台能力放原生层；新 API 做系统可用性处理，依赖/框架/helper 的最低系统版本一并核对。录制与抽音保持流式、有界内存，不能为方便把完整长录音/视频装入内存。详细设备场景见 [TESTING.md](docs/TESTING.md)；macOS 新系统编译成功不代表旧机性能、权限、真实音画同步已验证。

本地 Core 和 smoke 使用替身/一次性资料，不需要真实 API Key 或付费 ASR；未经授权不上传用户项目。纯文档改动核对链接、源码和命令即可，不必重跑无关全套。交付说明：改变了什么语义、哪些相邻链路已验证、执行命令及结果、未运行项和原因；不得把已有 CI、静态阅读或测试替身写成这次实机通过。
