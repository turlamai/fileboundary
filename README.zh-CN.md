# FileBoundary

**Windows 原生的文件加密诊断与授权恢复工具集。本地优先，原生 Windows GUI 与 agent 友好 CLI。**

[English](README.md) · **中文**

## 状态

**Racket 核心开发预览，尚非完整产品。** 本分支新增 `src/engine/inventory.rkt` 与 `src/cli.rkt`，实现只读文件检查、有限数量扫描和版本化 JSON 输出。Windows 编译及测试是否通过，以 [实际工作流](.github/workflows/windows-core.yml) 为准。原生 GUI、完整系统诊断、持久化清单和授权恢复验证**尚未实现**。既有 C#/WinForms v0.1 仅是仓库外的参考原型，并非正式技术选型（见 [Issue #1](https://github.com/turinglambdaai/fileboundary/issues/1)）。

### 无界面开发预览

Windows 需安装 Racket CS 9.3，在仓库根目录执行：

```powershell
racket src/cli.rkt version
racket src/cli.rkt scan "C:\\test-data\\fixture.pdf"
racket src/cli.rkt scan "C:\\test-data" --max-files 500
raco test tests/inventory-test.rkt tests/cli-test.rkt
```

每次调用向标准输出写一个 JSON envelope；默认不输出文件内容或完整路径。文件签名不能证明明文或恢复成功；`doctor` 现已支持只读 Filter Manager 清单，`verify` 仍明确返回 `notImplemented`。详见 [实现限制](docs/implementation-slice.md)。

## 背景

目标机器运行着第三方透明文件加密软件，其机制组合是该品类的典型形态：

- Windows 文件系统 **minifilter** 驱动拦截文件 I/O；
- 用户进程内的 **DLL 注入**与 **API Hook**；
- **进程白名单**决定哪些程序读到明文；
- **密钥管理服务**持有加密密钥；
- 写入时透明加密、读取时透明解密。

观察到的现象：白名单内的 PDF 软件能正常打开和保存；文件保存到磁盘后可能被透明加密；非白名单软件可能无法正确读取这些文件。已有一批历史文件被加密，需要分析与恢复。

FileBoundary 的目标是让这一局面变得可度量、可恢复：管理员权限用于诊断，恢复只通过授权机制进行。

## FileBoundary 做什么

规划范围——每项能力都通过对应 issue 落地：

1. **分析加密机制** —— 枚举 minifilter、过滤驱动与服务配置、注入模块、hook 启发式检测，以及探针文件上的 I/O 行为（[#3](https://github.com/turinglambdaai/fileboundary/issues/3)）。
2. **诊断** —— 输出机器可读的报告：当前过滤栈与各进程的读写行为。
3. **盘点加密文件** —— 批量扫描磁盘，按加密可能性分类，记录文件状态、SHA-256 与格式信息（[#4](https://github.com/turinglambdaai/fileboundary/issues/4)）。
4. **经授权渠道恢复** —— 只通过防护体系认可的机制导出或解密：厂商自己的管理控制台、经白名单应用的导出路径、或所有者合法持有的密钥（[#5](https://github.com/turinglambdaai/fileboundary/issues/5)）。
5. **验证完整性** —— 恢复文件只有通过完整验证管线才可标记 `verified`；复制成功不等于解密成功（[#5](https://github.com/turinglambdaai/fileboundary/issues/5)）。
6. **管理恢复流程** —— 基于 manifest 的选择、每次尝试的审计记录、恢复集合与 manifest 的对账（[docs/recovery-workflow.md](docs/recovery-workflow.md)）。
7. **两个前端** —— 原生 Windows GUI，以及为 agent 与自动化提供版本化 JSON 契约的 CLI（[#7](https://github.com/turinglambdaai/fileboundary/issues/7)）。
8. **工程严谨性** —— Windows CI、自动化测试与双语文档从第一天建立（[#6](https://github.com/turinglambdaai/fileboundary/issues/6)、[#8](https://github.com/turinglambdaai/fileboundary/issues/8)）。

## 硬边界

FileBoundary 是机器所有者的诊断与恢复工具，不是击穿防护的工具：

- 原始文件**只读**打开；写操作只发生在指定的恢复输出目录。
- 管理员权限用于诊断。它**不**意味着拥有加密密钥，FileBoundary 从不如此假设。
- FileBoundary **不**绕过 DLP 或访问控制、不从密钥管理服务或驱动提取密钥、不伪装白名单进程、不破坏防护驱动、不尝试击穿加密体系。
- 「成功」只以**证据**声明：复制成功不是解密；文件头可识别不是明文的证明。完整语义见 [docs/security.md](docs/security.md)。

## 产品形态

- **引擎** —— 全部领域逻辑（诊断、盘点、恢复编排、验证）位于可测试的核心，不依赖任何 UI。
- **CLI** —— 引擎之上的薄适配层：stdout 输出 JSON，stderr 输出人类可读日志；契约见 [docs/cli-contract.md](docs/cli-contract.md)。
- **GUI** —— 原生 Windows 展示层，自身不含业务逻辑。
- **契约** —— 版本化 JSON schema，由 CLI、GUI、测试与 agent 消费方共享。

GUI 能做的，CLI 都能做——agent 对等是架构不变式，不是可选特性。

## 平台要求

- Windows 10 / 11 x64。
- 诊断操作（minifilter 与驱动枚举）需要管理员权限。需要提权的诊断一律显式报告 `requiresElevation`，绝不静默失败。
- 本地优先：无遥测、无云组件、无账号。

## 文档

| 文档 | 内容 |
|---|---|
| [架构](docs/architecture.md) | 模块图、数据流、分类语义、技术姿态 |
| [安全模型](docs/security.md) | 授权模型、硬边界、完整性语义、数据安全 |
| [恢复流程](docs/recovery-workflow.md) | 六阶段授权恢复流程与判定规则 |
| [CLI 契约](docs/cli-contract.md) | 版本化 JSON envelope、命令、退出码、版本策略 |
| [测试](docs/testing.md) | 测试分层、fixtures、红绿规则、CI 门禁 |
| [开发](docs/development.md) | 环境、工作流、产物卫生 |
| [决策记录（ADR）](docs/decisions/) | 架构决策记录 |

`AGENTS.md` 是对所有贡献者（人类或 AI）有约束力的工程宪章。

## 路线图

| 领域 | Issue | 状态 |
|---|---|---|
| 导入并审查 v0.1 原型 | [#1](https://github.com/turinglambdaai/fileboundary/issues/1) | 规划中 |
| 模块化 Windows 应用架构 | [#2](https://github.com/turinglambdaai/fileboundary/issues/2) | 规划中 |
| Windows 文件加密诊断 | [#3](https://github.com/turinglambdaai/fileboundary/issues/3) | 规划中 |
| 加密文件盘点与分类 | [#4](https://github.com/turinglambdaai/fileboundary/issues/4) | 规划中 |
| 授权文件恢复与验证 | [#5](https://github.com/turinglambdaai/fileboundary/issues/5) | 规划中 |
| Windows CI 与自动化测试 | [#6](https://github.com/turinglambdaai/fileboundary/issues/6) | 规划中 |
| 版本化 JSON CLI 契约 | [#7](https://github.com/turinglambdaai/fileboundary/issues/7) | 规划中 |
| 双语文档 | [#8](https://github.com/turinglambdaai/fileboundary/issues/8) | 规划中 |
| Windows 安装包与便携版发布 | [#9](https://github.com/turinglambdaai/fileboundary/issues/9) | 规划中 |

## 开发

`main` 是唯一长期分支。所有变更经 pull request 进入；CI 是合并门禁。贡献前（无论人类还是机器）先读 [`AGENTS.md`](AGENTS.md)。流程细节见 [docs/development.md](docs/development.md)。

## Windows 过滤驱动诊断（开发预览）

Windows 控制台执行 `racket src/cli.rkt doctor`。目前只会执行限时、限输出的只读命令 `fltmc.exe filters` 和 `fltmc.exe instances`，分别报告退出状态、是否截断、是否超时。权限不足或命令失败**不能**解释为系统没有过滤驱动；此时会返回 `partial`（退出码 1）。更全面的驱动、服务和进程模块检查仍在规划中。`verify` 尚未实现，也不声称已能恢复密文。

## 许可

专有——仅限内部使用。尚未授予任何许可，也暂无 LICENSE 文件；不得在所有者控制范围之外分发代码或其产物。
