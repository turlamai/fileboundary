# AGENTS.md

本文件是 FileBoundary 仓库的工程宪章，对人类贡献者与 AI agent 同等约束。
违反本文件的 PR 一律不接受，与实现质量无关。

## 项目定位（先读）

FileBoundary 是 Windows 透明文件加密的**对抗恢复研究**项目：机器所有者对自己机器上的第三方透明加密体系（minifilter + 注入 hook + 进程白名单 + 密钥管理服务）做全面研究——机制度量、格式与密码分析、白名单机制研究与利用、密钥提取——最终目标是**以可验证的证据恢复被加密的存量文件**。载体是一份可测试的领域引擎 + 原生 Windows GUI + agent 友好 CLI（版本化 JSON 契约）。目标平台 Windows 10/11 x64，本地优先，无遥测。

对抗手段不设禁令：驱动与服务、白名单、加密层、进程内存都在研究范围内。授权基础、技术范围与有门禁的实验协议见
[docs/security.md](docs/security.md) 与 [ADR-0006](docs/decisions/ADR-0006-adversarial-recovery-mandate.md)；
研究纲领见 [docs/adversarial-research.md](docs/adversarial-research.md)。以下四条不变式对所有工作生效：

1. 只研究操作者拥有并管理的机器；本仓库任何产物不用于他人系统，不对外发布。
2. 原始文件默认只读；改动系统状态（驱动/服务/注册表）的实验必须先记录方案再执行，优先在副本上做，全程留审计记录。
3. 仓库私有、仅限内部使用、不分发；恢复产物、密钥材料、解密器与绕过工具留在所有者控制范围内，不入库、不外发。
4. 复制成功 ≠ 解密成功。任何「成功」声明必须带证据（见下文「禁止虚假完成声明」）。

## 结构

初始化阶段的目录约定；随原型导入演进，变更走 ADR：

- `docs/` — 工程文档（架构、安全、测试、恢复流程、CLI 契约、开发）
- `docs/decisions/` — 架构决策记录（ADR），一次决策一个文件
- `.github/` — issue/PR 模板与 CI（CI 属于 Issue #6，落地前不存在）
- `contracts/` — 版本化 JSON 契约 schema（Issue #7 落地时创建）
- 引擎、CLI、GUI 的模块边界见 [docs/architecture.md](docs/architecture.md)

## 代码规范

- 技术路线以 **Racket** 为核心，GUI 优先验证 **Rivet / WinUI 3**，必要时评估 Glaze / WebView2；底层 Windows API 可以通过 Racket FFI 或小型 C/C++ 用户态辅助组件实现。GUI 选型与 Windows 完整验收仍须由 ADR-0002 和实测定案。
- 可复用 Racket 库先内部测试；提交 Racket Package Catalog 前必须确认独立接口、测试、Scribble 文档、许可证和所有者明确授权，不能公开真实样本或私有代码。
- 领域逻辑只进引擎；CLI 与 GUI 是薄适配层，业务逻辑不得进 UI 壳。
- 模块间只经显式接口/契约通信；禁止跨层抓取内部状态；依赖方向见架构文档。
- 代码注释一律英文；面向用户的文案先英文，双语文案机制落地后再补 zh-CN。
- 不提交：密钥与凭据、恢复出的文件内容、含真实文件数据的诊断转储、扫描
  数据库。`.gitignore` 是底线不是白名单——敏感产物一律写到仓库外的指定
  输出目录（保留扩展名约定见 [docs/cli-contract.md](docs/cli-contract.md)）。

## 测试要求

- 每个 PR 必须带测试；bug 修复必须红绿双验证（先写复现失败的测试，再修到绿），
  PR 中贴红、绿两份证据。
- CLI 行为用契约测试锁定（golden JSON + schema 校验）。
- 测试 fixtures 用检入仓库的生成器产出合成数据；禁止提交真实加密文件或个人数据。
  唯一现行例外：`tests/fixtures/real-samples/` 下按 SHA-256 固定的同内容明文/密文 DOCX 对照样本
  （[ADR-0004](docs/decisions/ADR-0004-real-sample-twin-pair-and-deferred-removal.md)）。
  早期个人 PDF 样本已从当前源码树移除（[ADR-0005](docs/decisions/ADR-0005-personal-pdf-removed-from-head.md)），
  历史 Git 对象清理仍由 [Issue #23](https://github.com/turinglambdaai/fileboundary/issues/23) 跟进。
- 禁止伪造测试结果：本地跑绿必须在 CI 复现；flaky 测试开 issue 隔离，
  不得静默跳过；`continue-on-error`、空测试、跳过断言不构成通过证据。
- CI 建立前（Issue #6 之前），PR 描述必须贴出本地完整测试命令与输出。

## 文档同步

- 行为、CLI 契约、恢复流程、支持平台的任何变更，同一 PR 内同步
  `README.md` 与 `README.zh-CN.md`；英文为规范源，中文为全量镜像。
- 架构决策走 ADR；改公共接口不改文档的 PR 不予合并。
- 文档写「为什么」和不变式，不复述代码。

## Git 分支规范

- `main` 是唯一长期分支，必须永远绿；谁推红 CI 谁当场修或 revert。
- 功能开发用短命分支：`feat/<topic>`、`fix/<topic>`、`docs/<topic>`；
  合并后删除分支。
- 所有变更经 PR 进入 `main`；禁止 force push、禁止删除 `main`、禁止破坏
  线性历史的 merge commit。注：GitHub Free 的私有仓库无法启用服务端分支
  保护（需 Pro 或公开仓库）；在计划允许前 PR 纪律由审查执行，允许后立即
  配置强制（见 Issue #6）。
- 多会话并行同一仓库时用 `git worktree` 隔离。

## PR 审查要求

- PR 描述必须回答三件事：改了什么、为什么、怎么验证的（贴证据）。
- 触及 diagnostics / recovery / 权限 / 输出写入 / 对抗实验的改动，必须在 PR 中逐条
  对照 [docs/security.md](docs/security.md) 的安全模型（机器范围、数据安全、
  有门禁实验协议、证据纪律）自查。
- CI 红 = 不合并，无例外；不允许绕过审查或门禁。
- 完成 = 代码 + 测试 + 文档 + CI 全绿，缺一不可。

## AI Agent 协作规范

- agent 只在 feature 分支上工作，小步 PR；不直接推 `main`。
- 每个切片可验收：记录改动范围、依赖 pin、验证命令与输出证据。
- 被阻塞时开 issue 说明真实状态；不得用「部分完成」冒充完成；不得修改
  CI/测试门禁让自己的工作变绿——削弱门禁需要 ADR + 所有者批准。
- 已实现、已验证、已发布分别陈述，三者不得互相冒充。
- 证据必须来自本次改动之后的实际运行；不复用旧证据制造通过。

## 禁止虚假完成声明

以下行为一律视为工程事故，发现即 revert 并在 issue 中记录：

1. 将未实现或未验证的功能标记为已完成。
2. 伪造、裁剪或复用测试输出与 CI 证据。
3. 用跳过、空跑、弱化断言的方式制造绿灯。
4. 用「复制成功」「文件头识别成功」冒充「解密成功」。
5. 文档与实现不符——把 Planned 写成 Shipped。

## 完成前必须运行

工具链随 ADR-0002 定案后填充具体命令。在此之前，按
[docs/testing.md](docs/testing.md) 的分层要求本地执行全部适用测试并在
PR 中贴输出证据。
