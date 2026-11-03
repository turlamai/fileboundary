FileBoundary (portable) / 便携版
================================

How to start / 如何启动:
  Double-click "RivetHost.exe" below (or "FileBoundary.cmd").
  双击本目录下的 RivetHost.exe（或 FileBoundary.cmd）。

What it does / 它做什么 (read-only unless you explicitly run Decrypt / Pad Twin):
  Scan        - classify files: which carry the E-SafeNet encryption wrapper / 扫描识别哪些文件带加密壳
  Diagnostics - list the Windows filter-driver stack (minifilter inventory) / 枚举系统过滤驱动
  Check Export- compare an encrypted original with an already-authorized exported file / 比对密文与已授权导出
  Decrypt     - decrypt a wrapped file using YOUR policy pad (FILEBOUNDARY_PAD env var) / 用你的 pad 密钥解密
  Pad Twin    - recover the policy pad from one aligned plaintext/ciphertext pair / 从明文/密文对恢复 pad

Headless CLI (for agents) / 无头命令行（供 agent 使用）:
  Use the source distribution (FileBoundary-v<version>-source.tar.gz) with Racket CS 9.3,
  then: racket src/cli.rkt help
  使用源码发行包并安装 Racket CS 9.3 后运行上述命令。

Never delete an encrypted original based on a FileBoundary result.
不要依据 FileBoundary 的任何结果删除加密原文件。
