# 自动更新与发布

## 用户体验

官方安装包启用 Sparkle 2.9.6：每 24 小时自动检查一次；应用菜单提供
「检查更新…」和「自动检查更新」开关。检查遵循 Sparkle 的本地检查时间，
手动检查不受每日周期限制。安装始终需要用户点击确认，不静默安装。

发现新版后使用 Sparkle 原生更新说明、下载、校验、安装与重启窗口。
自动提醒等待应用回到前台、首次设置完成且没有正在进行的工作。
录制的启动、录制中、收尾，转写、导出、截图、画笔与模态面板都受保护。
交互更新期间暂时暂停新任务与编辑；稍后、跳过、取消或失败后恢复。
这种安排保证下载期间也不会启动新录制，再被安装打断。

更新前保存全部项目；退出前再次检查工作状态并重试完整保存。
文字自动保存曾失败、时间输入无效或磁盘不可写都会阻止退出。
取消退出后恢复编辑，用户可以修复后重试。更新只替换 .app；
.pointtell 项目、UserDefaults 与钥匙串服务名保持不变。

旧版 v0.3.3 不含更新器，需要手动安装一次带更新功能的正式发布包。
源代码的 v0.4.0 与发布的 v0.4.0 是两件事：发布前 README 继续指向已有下载。

## 维护者：首次配置

需要一台装有 Xcode Command Line Tools / Swift 和已登录 GitHub CLI 的 Mac，
以及对此仓库 Actions Secrets 和 Variables 的写权限。在仓库根目录执行：

```sh
bash scripts/setup-updates.sh
```

脚本解析锁定的 Sparkle 依赖，在本机登录钥匙串的独立 account
`io.github.kejun.point-and-tell.updates` 生成或复用 Ed25519 密钥。
私钥仅通过权限受限的临时文件和标准输入传入 GitHub Secret；
成功或失败都会清理临时文件，不写入仓库或构建产物。

| 配置 | 用途 |
| --- | --- |
| Actions Secret `SPARKLE_PRIVATE_ED_KEY` | 签安装包与更新清单；32 字节 seed 的 Base64，来自 Sparkle generate_keys |
| Actions Variable `SPARKLE_PUBLIC_ED_KEY` | 公钥；构建时写入安装包 Info.plist |

请保留钥匙串密钥的安全备份。脚本发现仓库已配置其他公钥时会拒绝覆盖。
在只有 ad-hoc 应用签名的情况下，丢失更新私钥可能要求用户重新手动安装。
不要把私钥粘贴到 issue、PR、聊天或日志。

这是发布者的一次性配置，使用应用的人不需要 GitHub 账号、Token 或 Xcode。
开发/PR 构建没有公钥时仍可运行；更新菜单禁用并给出说明。
发布构建必须有公钥，发布步骤必须验证公私钥匹配。

## 每次发布

1. 在 main 合入已验证代码；同步 VERSION、Info.plist 的显示版本与递增整数
   CFBundleVersion，以及 CHANGELOG.md 对应版本条目。
2. GitHub Actions → **Publish signed macOS update** → Run workflow → main，
   或运行：

```sh
gh workflow run release.yml --repo kejun/point-and-tell --ref main
```

3. 工作流在 Intel 和 Apple Silicon 上复用完整的原生检查，然后构建正式
   Universal 安装包。最小系统继续为 11.0。
4. 校验版本、源提交、架构、最终字节与签名公钥，拒绝覆盖已有版本、回退
   build number 或意外更换密钥。
5. 将安装包、校验文件、build.json 和更新说明放入 releases/vX.Y.Z/；
   使用 Sparkle 官方 generate_appcast 生成签名清单，禁用增量包。
6. 验证清单签名，以及清单中安装包签名、长度、版本和最低系统。
   安装包下载链接使用不可变 archive commit。两个本地提交通过一次
   fast-forward push 原子发布；main 已前进则安全停止，无强推。

发布工作流仅支持 main 手动发起；PR 不接触发布私钥。GitHub Token 只有
发布 job 获得 contents:write。若分支保护要求 PR，push 会失败，不自动绕过。
未发布的失败运行可以修正后重试；已发布版本必须递增版本号和 build number。

0.5.1 的用户 Intel 真机验收已记录在 [发布验收记录](release-acceptance-0.5.1.json)。
原生探针继续执行；仅对完全一致的应用输入和已知 Intel 暂停画面失败，
发布门禁记录 `accepted-on-device` 警告并保留失败产物。其他错误、改变后的应用
及后续版本仍失败；没有放宽更新签名、保存保护或归档校验。范围与证据见
[暂停录制验证](PAUSE-RECORDING.md#051-正式发布验收)。

首次提交的 appcast 是无条目的占位文件；首个正式发布会生成其有效签名。
在此之前不分发有公钥但没有有效更新源的开发包作为正式版本。

## 验证与回退

自动检查：

- Swift core 回归：各类忙碌状态延后更新、保存失败、重复交互、退出时重新验证。
- Python 发布回归：应用身份、版本/构建号、公钥、包字节、更新链接、签名字段、
  最低系统与更新说明范围。
- macOS 原生编译、已有音频/UI/HTML 冒烟；临时密钥签真实 .app ZIP 和 appcast，
  用独立 CryptoKit 验证包签名，并确认被修改的包与清单被拒绝。
- 额外用独立测试 .app、临时密钥与本机 feed 实际完成 build 1 → 2 替换和重启。
  临时测试不访问生产更新源、不操作用户钥匙串、不替换真实 Point & Tell。
  测试包为本机 HTTP 设置的例外不进入正式应用。

发布前在隔离 Mac/测试账号上，用两个签名一致且构建号递增的真实安装包验证：

- 从旧版下载、校验、替换到新版并重启；关于窗口显示新版。
- 录制启动/收尾、转写、导出时到达更新提醒，任务不被中断。
- 稍后/跳过、取消下载、断网、损坏签名后旧版继续可用。
- 断开项目存储盘或制造时间输入错误，更新无法丢弃未保存内容。
- 从只读位置/被 App Translocation 隔离的位置运行时，移到 Applications 后重试。
- macOS 11 Intel 与较新 Apple Silicon 系统上确认屏幕、麦克风权限与 Keychain
  访问；现有 ad-hoc 签名不能保证系统不重新请求授权。

项目仍用 ad-hoc 签名、未公证。Ed25519 验证更新来源，不能替代 Apple
Developer ID 与公证。将来接入 Apple 签名需要独立迁移与真机验证。

若新版本异常，退出应用，从旧 releases/vX.Y.Z/ 下载并校验安装包后手动
替换 Applications 中的副本。关闭自动检查或跳过问题版本，避免再次提示。
本轮不改变项目 schema；不承诺自动降级、崩溃回滚或恢复系统权限。

## 实现约束

- Sparkle 固定在 2.9.6（Package.resolved 同时锁定提交）；2.10 要求 macOS 12。
- Framework、辅助程序、资源、许可证和符号链接完整打包；由内向外签名，
  不用 codesign --deep 进行签名。
- HTTPS；开启 SUVerifyUpdateBeforeExtraction、SURequireSignedFeed；
  签名验证失败不超时放行。系统统计保持关闭。
- 安装包与清单都由官方 Sparkle 工具签名；不自写替换 .app 的脚本。
- 参考：[Sparkle 接入](https://sparkle-project.org/documentation/)、
  [非打扰提醒](https://sparkle-project.org/documentation/gentle-reminders/)、
  [发布说明](https://sparkle-project.org/documentation/publishing/)。
