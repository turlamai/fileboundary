# FileBoundary

**Windows 原生的文件加密诊断与对抗恢复研究工具集。本地优先，原生 Windows GUI 与 agent 友好 CLI。**

[English](README.md) · **中文**

## 状态

**v0.2.0 已发布** —— 对抗恢复核心已在无界面 CLI 上产品化（[发布页](https://github.com/turlamai/fileboundary/releases/tag/v0.2.0)）。按工程宪章的三层如实记账：

- **已发布（v0.2.0）**：`decrypt`（封装 OOXML 逐条目 CRC 验证重组；封装 PDF 语义头重建 + xref 抽查）、`pad twin`（一对对齐明文/密文恢复策略 pad）、以及自更新通道（`update now` 对接 GitHub Releases，支持私有资产认证与带守卫的增量包）。发布物含源码分发 + manifest；空目录经线上通道 0.0.0 → 0.2.0 已端到端验证。
- **已实现、本机已验证**：完整测试套件（194 项 + JSON Schema 契约校验）在 Windows 全绿，含三个 pin 定真实样本的端到端解密（[ADR-0007](docs/decisions/ADR-0007-real-wrapped-decryption-fixtures.md)）。CI 运行暂被账号账单阻塞——恢复前合并门禁由审查执行。
- **待办**：WinUI 宿主包由 [Windows GUI CI](.github/workflows/windows-gui.yml) 构建（同一账单关卡）；GUI 解密面板在 [#34](https://github.com/turlamai/fileboundary/issues/34) 跟进；安装器（[#9](https://github.com/turlamai/fileboundary/issues/9)）待 CI 恢复后落地。

既有 C#/WinForms v0.1 仅是仓库外的参考原型，并非正式技术选型（见 [Issue #1](https://github.com/turlamai/fileboundary/issues/1)）。

### 无界面开发预览

要求 Windows 10/11 x64 上的 Racket CS 9.3。在仓库根目录执行——或解压发布包后使用 `fileboundary.cmd`（封装同一 CLI）：

```powershell
# 盘点与诊断（只读）
racket src/cli.rkt scan "C:\\test-data" --max-files 500
racket src/cli.rkt doctor

# 解密（ADR-0006；策略 pad 默认取 research/t0/pad_full.json）
racket src/cli.rkt decrypt --in "C:\\Encrypted\\doc.docx" --out "D:\\Recovered\\doc.docx"
racket src/cli.rkt pad twin --plain "P:\\plain.xlsx" --cipher "C:\\ct.xlsx" --out "D:\\keys\\new-policy-pad.json"

# 自更新（GitHub Releases；私有仓库需设只读 PAT）
$env:FILEBOUNDARY_GH_TOKEN = "<细粒度 PAT，contents:read-only>"
racket src/cli.rkt update now
```

每条命令向标准输出写一个版本化 JSON envelope（[契约](docs/cli-contract.md)）；机器可读输出即规范接口。

扫描器会拒绝符号链接形式的扫描根路径，跳过目录中的文件/目录符号链接，并将跳过情况报告为 `partial`。这只是路径级防护，**尚不能**保证覆盖所有 Windows 重解析点或并发替换链接的竞态；后续由 [#10](https://github.com/turinglambdaai/fileboundary/issues/10) 跟进。

### 授权导出验证（只读预览）

必须先经原加密系统**批准的正规解密/导出流程**取得另一份候选文件，再执行：

```powershell
racket src/cli.rkt verify --original "C:\\Encrypted\\document.pdf" --exported "D:\\ApprovedExports\\document.pdf"
```

此命令**不会直接解密 E-SafeNet 密文**。退出码 1 为**尚未验证**，需要独立检查；退出码 4 表示检测到加密封装仍存在或可信明文哈希不匹配。详细说明见[存量文件授权恢复指南](docs/authorized-recovery.md)。不要凭此删除原始加密文件。

### Windows GUI 测试包

[Windows GUI CI](.github/workflows/windows-gui.yml) 会生成便携开发包 **FileBoundary-Windows-x64-dev**。界面支持只读扫描、过滤驱动诊断和新增的 **Check Export / 验证导出**，用于比较原密文与**已经正式授权导出的候选文件**。输出 `FAILED` 或 `UNVERIFIED` 都**不表示已能独立解密密文**。在受保护的电脑上安装之前，先阅读 [Windows 实机验收指南](docs/windows-qa.zh-CN.md)，不要删除原始加密文件。

## 背景

目标机器运行着第三方透明文件加密软件，其机制组合是该品类的典型形态：

- Windows 文件系统 **minifilter** 驱动拦截文件 I/O；
- 用户进程内的 **DLL 注入**与 **API Hook**；
- **进程白名单**决定哪些程序读到明文；
- **密钥管理服务**持有加密密钥；
- 写入时透明加密、读取时透明解密。

观察到的现象：白名单内的 PDF 软件能正常打开和保存；文件保存到磁盘后可能被透明加密；非白名单软件可能无法正确读取这些文件。已有一批历史文件被加密，需要分析与恢复。

FileBoundary 的目标是让这一局面变得可度量、可破解：所有者研究这套机制，尝试一切可行的恢复路径——有授权渠道先走授权渠道，没有就走对抗路径——最终判定只来自证据管线（[ADR-0006](docs/decisions/ADR-0006-adversarial-recovery-mandate.md)）。

## FileBoundary 做什么

规划范围——每项能力都通过对应 issue 落地：

1. **分析加密机制** —— 枚举 minifilter、过滤驱动与服务配置、注入模块、hook 启发式检测，以及探针文件上的 I/O 行为（[#3](https://github.com/turlamai/fileboundary/issues/3)）。
2. **诊断** —— 输出机器可读的报告：当前过滤栈与各进程的读写行为。
3. **盘点加密文件** —— 批量扫描磁盘，按加密可能性分类，记录文件状态、SHA-256 与格式信息（[#4](https://github.com/turlamai/fileboundary/issues/4)）。
4. **恢复——不设渠道限制、全程离线** —— T0 破密已产品化：`decrypt` 用策略 pad 重构封装的 OOXML（docx/xlsx/pptx，逐条目 CRC 验证）与封装的 PDF（语义头重建 + xref 抽查）；`pad twin` 从一对对齐的明文/密文恢复策略 pad（[#5](https://github.com/turlamai/fileboundary/issues/5)、[研究纲领](docs/adversarial-research.md)）。
5. **验证完整性** —— 恢复文件只有通过完整验证管线才可标记 `verified`；复制成功不等于解密成功（[#5](https://github.com/turlamai/fileboundary/issues/5)）。
6. **管理恢复流程** —— 基于 manifest 的选择、每次尝试的审计记录、恢复集合与 manifest 的对账（[docs/recovery-workflow.md](docs/recovery-workflow.md)）。
7. **两个前端** —— 原生 Windows GUI，以及为 agent 与自动化提供版本化 JSON 契约的 CLI（[#7](https://github.com/turlamai/fileboundary/issues/7)）。
8. **工程严谨性** —— Windows CI、自动化测试与双语文档从第一天建立（[#6](https://github.com/turlamai/fileboundary/issues/6)、[#8](https://github.com/turlamai/fileboundary/issues/8)）。
9. **在线更新** —— `update check` / `update apply` 对接 GitHub Releases 渠道，增量包只携带变更文件（[ADR-0008](docs/decisions/ADR-0008-release-channel-and-self-update.md)）。

## 研究纲领

FileBoundary 是面向机器所有者的对抗恢复研究项目（[ADR-0006](docs/decisions/ADR-0006-adversarial-recovery-mandate.md)）。在操作者自己的机器上**不设技术禁令**——密钥提取、白名单研究与伪装、驱动探测、密码分析都是正当研究课题。固定的是范围与证据：

- **范围** —— 只针对操作者拥有并管理的机器；仓库私有、仅限内部使用，不对外发布任何内容。
- **数据安全** —— 原始文件默认只读打开；改动防护系统状态的实验必须先记录方案、先在副本上跑（[docs/security.md](docs/security.md)）。
- **证据** —— 复制成功不是解密；文件头可识别不是明文的证明。无论候选明文由哪种技术产生，`verified` 判定只来自 [docs/security.md](docs/security.md) 的验证管线。

## 产品形态

- **引擎** —— 全部领域逻辑（诊断、盘点、恢复编排、验证）位于可测试的核心，不依赖任何 UI。
- **CLI** —— 引擎之上的薄适配层：stdout 输出 JSON，stderr 输出人类可读日志；契约见 [docs/cli-contract.md](docs/cli-contract.md)。
- **GUI** —— 原生 Windows 展示层，自身不含业务逻辑。
- **契约** —— 版本化 JSON schema，由 CLI、GUI、测试与 agent 消费方共享。

GUI 能做的，CLI 都能做——agent 对等是架构不变式，不是可选特性。

## 技术方向

当前开发预览的文件扫描引擎和 JSON CLI 使用 **Racket**；Windows GUI 首选验证 **Rivet / WinUI 3**，在实际测试表明有优势时可以改选 **Glaze / WebView2**。Windows 底层可使用 Racket FFI 或独立小型 C/C++ 用户态模块。详见[候选架构决策 ADR-0002](docs/decisions/adr-0002-prototype-stack.md)和[C#/WinForms 原型审查](docs/prototype-review.md)。本仓库已加入基于 Rivet v0.13.0 的 WinUI 3 宿主源码，构建证据见 [GUI 工作流](.github/workflows/windows-gui.yml) 和 [GUI 开发指南](docs/gui-development.md)。Windows 实机交互验收及文件恢复仍未完成。通用 Racket 库公开发布需单独批准。

## 平台要求

- Windows 10 / 11 x64。
- 诊断操作（minifilter 与驱动枚举）需要管理员权限。需要提权的诊断一律显式报告 `requiresElevation`，绝不静默失败。
- 本地优先：无遥测、无云组件、无账号。

## 文档

| 文档 | 内容 |
|---|---|
| [架构](docs/architecture.md) | 模块图、数据流、分类语义、技术姿态 |
| [安全模型](docs/security.md) | 授权基础、技术范围、固定规则、完整性语义、数据安全 |
| [对抗研究纲领](docs/adversarial-research.md) | 攻击面、研究线、实验协议、优先级 |
| [恢复流程](docs/recovery-workflow.md) | 六阶段恢复流程与判定规则 |
| [厂商授权恢复渠道](docs/authorized-recovery.md) | 厂商导出渠道与其验证流程 |
| [CLI 契约](docs/cli-contract.md) | 版本化 JSON envelope、命令、退出码、版本策略 |
| [测试](docs/testing.md) | 测试分层、fixtures、红绿规则、CI 门禁 |
| [开发](docs/development.md) | 环境、工作流、产物卫生 |
| [决策记录（ADR）](docs/decisions/) | 架构决策记录 |

`AGENTS.md` 是对所有贡献者（人类或 AI）有约束力的工程宪章。

## 路线图

| 领域 | Issue | 状态 |
|---|---|---|
| 导入并审查 v0.1 原型 | [#1](https://github.com/turlamai/fileboundary/issues/1) | 完成（[docs/prototype-review.md](docs/prototype-review.md)） |
| 模块化 Windows 应用架构 | [#2](https://github.com/turlamai/fileboundary/issues/2) | 完成（引擎/CLI/GUI 分层，[ADR-0002](docs/decisions/adr-0002-prototype-stack.md)） |
| Windows 文件加密诊断 | [#3](https://github.com/turlamai/fileboundary/issues/3) | 核心已发布（`doctor`）；驱动/服务/模块检查规划中 |
| 加密文件盘点与分类 | [#4](https://github.com/turlamai/fileboundary/issues/4) | 核心已发布（`scan`）；持久化清单规划中 |
| 文件恢复与验证 | [#5](https://github.com/turlamai/fileboundary/issues/5) | 核心已发布（T0 解密 + 逐条目验证，[研究纲领](docs/adversarial-research.md)） |
| Windows CI 与自动化测试 | [#6](https://github.com/turlamai/fileboundary/issues/6) | 完成（工作流已上线；runner 暂被账单阻塞） |
| 版本化 JSON CLI 契约 | [#7](https://github.com/turlamai/fileboundary/issues/7) | 完成（schema + [CI 契约门禁](contracts/command-data-v1.schema.json)） |
| 双语文档 | [#8](https://github.com/turlamai/fileboundary/issues/8) | 完成（README 镜像 + ADR 决策记录） |
| Windows 安装包与便携版发布 | [#9](https://github.com/turlamai/fileboundary/issues/9) | 部分——发布通道 + 自更新已上线（[ADR-0008](docs/decisions/ADR-0008-release-channel-and-self-update.md)、[v0.2.0](https://github.com/turlamai/fileboundary/releases/tag/v0.2.0)）；WinUI 包与安装器待 CI |

## 开发

`main` 是唯一长期分支。所有变更经 pull request 进入；CI 是合并门禁。贡献前（无论人类还是机器）先读 [`AGENTS.md`](AGENTS.md)。流程细节见 [docs/development.md](docs/development.md)。

## Windows 过滤驱动诊断（开发预览）

Windows 控制台执行 `racket src/cli.rkt doctor`。目前只会执行限时、限输出（每路最多 64 KiB、8 秒超时）的只读命令 `fltmc.exe filters` 和 `fltmc.exe instances`，分别报告退出状态、是否截断、是否超时。权限不足或命令失败**不能**解释为系统没有过滤驱动；此时会返回 `partial`（退出码 1）。更全面的驱动、服务和进程模块检查仍在规划中。

## 许可

专有——仅限内部使用。尚未授予任何许可，也暂无 LICENSE 文件；不得在所有者控制范围之外分发代码或其产物。
