# vrun

一个用 Go 编写的**自解压、自替换（self-replacing）单文件安装器 stub**。

将真实程序 gzip 压缩后通过 `go:embed` 嵌入 stub，编译成**单文件**。用户运行该文件时，stub 会先把自己替换成真正的程序，随后接管参数、IO、环境变量与退出码，表现为"和真实程序一模一样"。

跨平台支持 **Linux / macOS / BSD（unix）/ Windows**，并对 plan9/js 提供了降级实现。

---

## ✨ 特性

- **单文件分发**：真实程序被 gzip 压缩后嵌入二进制，对外只有 1 个可执行文件。
- **自替换安装**：首次运行时，stub 校验自身哈希，未安装则解压 payload 并原子替换当前 exe。
- **快速路径**：已安装时不做任何写操作，直接 `execve`（Unix）或 `fork+wait`（Windows）真实程序。
- **哈希校验**：使用 `xxh64`（[github.com/cespare/xxhash/v2](https://github.com/cespare/xxhash/v2)）对**解压后**内容做完整性校验，构建期注入哈希，运行期 O(1) 校验。
- **并发安全安装**：
  - **Unix**：`flock` 排他锁，进程终止/崩溃由内核自动释放。
  - **Windows**：`LockFileEx`，语义对齐 `flock`。
  - **plan9/js**：`O_EXCL` 锁文件 + 心跳，作为已知限制降级。
- **信号安全**：安装期间收到 `SIGTERM/SIGINT/SIGHUP` 时不丢锁、不吞信号；运行期间透传信号给子进程（Unix），被信号杀死时按 `128+signum` 语义退出。
- **优雅恢复**：Windows 使用 `.old` 备份；被中断的安装下次启动自动恢复。
- **透明进程替换**：Unix 走 `syscall.Exec` 直接替换进程（无额外进程层级）；其它平台走 `fork+wait`，透传 `argv[0]`、stdio、环境与退出码。
- **符号链接友好**：区分 `origPath`（用户视角）与 `realPath`（规范真实路径），symlink 调用时不会误替换链接本身。

---

## 🔧 工作原理

```
┌──────────────────────────────────────────────────────────────┐
│  构建期 (build.sh / build.ps1)                                │
│                                                              │
│   payload(原始程序) ──[gzip]──► payload.gz                    │
│                                        │                     │
│                              tools/hash 计算 xxh64            │
│                                        │                     │
│           go:embed payload.gz + -ldflags -X main.realAppXXH64Hex=... │
│                                        │                     │
│                                        ▼                     │
│                                    installer (stub)          │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  运行期 (installer)                                           │
│                                                              │
│   启动                                                       │
│    │                                                         │
│    ├─ 计算 wantHash（ldflags 注入，O(1)）                     │
│    │                                                         │
│    ├─ 快速路径: realPath 的 xxh64 == wantHash ?              │
│    │      └─ 是 → 直接 runRealApp(origPath)                  │
│    │                                                         │
│    └─ 否 → 进入 installOnce(realPath, wantHash)              │
│           │                                                  │
│           ├─ 加锁 (<exe>.lock)                                │
│           ├─ 恢复上次中断残留                                 │
│           ├─ 双检哈希（等待锁期间可能已被别的实例装好）        │
│           ├─ 解压到 <exe>.new                                │
│           ├─ 校验 .new 的 xxh64                              │
│           ├─ 原子替换（Unix rename / Windows .old+rename）    │
│           ├─ 校验最终文件，失败回滚                           │
│           └─ 解锁 → runRealApp(origPath)                     │
└──────────────────────────────────────────────────────────────┘
```

---

## 📂 目录结构

```
vrun/
├── main.go              # stub 主逻辑：快速路径 / 安装 / 启动真实程序
├── exec_unix.go         # Unix: syscall.Exec 进程替换
├── exec_windows.go      # 非 Unix: 返回 errExecUnsupported
├── lock_unix.go         # Unix: flock 排他锁
├── lock_windows.go      # Windows: LockFileEx 排他锁
├── lock_other.go        # plan9/js: O_EXCL 锁文件 + 心跳（降级）
├── signal_unix.go       # Unix: 安装期信号兜底 + 运行期转发 + 128+signum
├── signal_windows.go    # Windows: 安装期信号兜底
├── signal_other.go      # plan9/js: no-op
├── build.sh             # Linux/macOS 构建脚本
├── build.ps1            # Windows 构建脚本 (PowerShell)
├── tools/
│   ├── hash/main.go     # xxh64 计算工具（支持 -decompress）
│   └── echo/main.go     # 测试用最小 payload
└── go.mod
```

---

## 📦 依赖

- **Go** ≥ 1.27（`go.mod` 中声明为 `go 1.27.3`，可按需调低）
- 运行 `build.sh` 时：
  - `gzip`（若 payload 不是 gzip 格式）
  - 或 `tools/hash`（仓库自带，推荐）
- 运行 `build.ps1` 时：
  - 同上；若无 `tools/hash` 且 payload 非 gzip，需要 `gzip` + `xxhsum`

Go 依赖（`go.mod` 已声明）：

```
github.com/cespare/xxhash/v2 v2.3.0
golang.org/x/sys          v0.50.0
```

---

## 🚀 快速开始

### 1. 克隆并初始化

```bash
git clone https://github.com/456vv/vrun.git
cd vrun
go mod download
```

### 2. 准备一个 payload 程序

可以用仓库自带的 `tools/echo` 做最小验证：

```bash
go build -o /tmp/hello ./tools/echo
```

### 3. 构建 stub

#### Linux / macOS / BSD

```bash
chmod +x build.sh
./build.sh /tmp/hello installer
```

#### Windows (PowerShell)

```powershell
.\build.ps1 -PayloadSrc C:\path\to\hello.exe -Output installer.exe
```

构建产物 `installer` / `installer.exe` 即为可分发的**单文件安装器**。

### 4. 运行

```bash
./installer            # 首次运行：自解压、自替换，然后运行真实程序
./installer --arg xyz  # 后续运行：直接运行真实程序，参数透传
```

首次运行后，`installer` 已经**变成**真实程序本身（内容变为 payload 解压后的二进制）。再次运行时走快速路径，无写盘操作。

---

## 🛠️ 构建脚本详解

### `build.sh`

```bash
./build.sh [payload] [output]
```

- 若未传 `payload` 且当前目录存在 `payload.gz`，则复用；
- 若 `payload` 魔数不是 `1f 8b`（gzip），调用系统 `gzip -9` 压缩；
- 使用 `tools/hash -decompress` 计算**解压后**内容的 `xxh64`（与 stub 运行期语义一致）；
- 通过 `-ldflags="-X main.realAppXXH64Hex=<hex>"` 注入；
- `go build` 生成 `output`（默认 `installer`）。

可选环境变量：

```bash
STUB_PKG=./cmd/installer ./build.sh payload.bin out/installer
```

### `build.ps1`

```powershell
.\build.ps1 [-PayloadSrc <path>] [-Output <path>] [-StubPkg <pkg>]
```

行为与 `build.sh` 一致，额外：
- 优先调用 `go run ./tools/hash -decompress` 计算哈希；
- 若无 `tools/hash`，回退 `gzip -dc | xxhsum -H1`。

---

## 🧠 平台差异

| 能力 | Unix (Linux/macOS/BSD) | Windows | plan9 / js |
|---|---|---|---|
| 锁 | `flock` | `LockFileEx` | `O_EXCL` + 心跳（降级） |
| 进程替换 | `syscall.Exec`（无额外进程） | `fork+wait` | `fork+wait` |
| 原子替换 | `rename` | `.old` + `rename` | `rename` |
| 崩溃后锁自动释放 | ✅ | ✅ | ❌（靠 mtime 超时） |
| 中断恢复 | — | `.old` → exe | — |
| 被信号杀死时退出码 | `128+signum` | `128+signum` | `1` |
| 运行期信号转发 | ✅ | ❌ | ❌ |

> 关于 `plan9 / js` 的已知限制见 `lock_other.go` 头注释（TOCTOU、心跳语义等），日常场景并发安装概率极低，作为降级方案接受。

---

## 🔐 可靠性设计要点

1. **构建期与运行期哈希语义一致**：`tools/hash -decompress` 与 stub 中 `resolvePayloadMeta` 都对解压后的明文计算 `xxh64`，避免"压缩参数不同导致哈希不同"的坑。
2. **`O_EXCL` 写 `.new`**：确保权限参数生效，不会因已存在文件而跳过 `chmod`。
3. **替换前后都校验**：`.new` 写入完成后校验一次；替换后再校验一次；Windows 校验失败会自动回滚到 `.old`。
4. **`fsync` 落盘**：`.new` 写入后 `fsync`，Unix 上 `rename` 后再 `fsync` 父目录，保证断电/崩溃场景元数据持久。
5. **信号窗口管理**：
   - `signal.Notify` 先于 `acquireLock`，杜绝"加锁后、通知前"的信号泄漏锁窗口；
   - `defer` 中"先放锁、再 `signal.Stop`"，杜绝 `signal.Stop` 后默认 handler 直接退出导致锁泄漏；
   - `signal.Stop` 后非阻塞 drain，避免用户 `SIGTERM` 被"安装成功后正常退出"吞掉。
6. **Unix 不删除 lock 文件**：`flock` 保护 inode 而非路径，`unlock` 后再 `unlink` 会让等待者在新 inode 上加锁成功，产生"双持锁"。
7. **symlink 语义**：`origPath` 用于 `exec` 启动（会跟随 symlink），`realPath` 用于锁/替换/校验（指向真实文件），symlink 调用场景下不会误替换链接本身。

---

## 🧪 用自带的 `tools/echo` 验证

```bash
go build -o /tmp/hello ./tools/echo
./build.sh /tmp/hello /tmp/installer
/tmp/installer            # 输出: Hello Welcome
/tmp/installer            # 再次运行仍输出: Hello Welcome（已走快速路径）
```

---

## ❓ 常见问题

**Q：为什么第一次运行比后续慢？**
A：首次运行需要解压 payload、写入 `.new`、替换自身。后续运行只做一次 `xxh64` 校验 + 直接启动真实程序。

**Q：可以把 payload 换成任意二进制吗？**
A：可以。任何非 gzip 输入都会被 `build.sh` / `build.ps1` 用系统 `gzip -9` 压缩后再嵌入。已经是 gzip 的输入会原样复用。

**Q：Windows 上替换失败怎么办？**
A：`replaceOnWindows` 会保留 `<exe>.new`（已校验的正确程序）与 `<exe>.old`（原 stub）。可按错误信息手动改名恢复；或被安全软件占用，重启后重试。

**Q：能否关闭哈希快速路径，改用运行期解压计算？**
A：可以，但不建议——`realAppXXH64Hex` 未注入时会回退到运行期解压计算哈希，启动变慢。只要正确走 `build.sh` / `build.ps1` 就不会命中这个路径。

**Q：如何改锁等待时长 / 心跳间隔？**
A：修改 `main.go` 中的 `lockTimeout` 和 `lockHeartbeat` 常量。

**Q：plan9/js 支持到什么程度？**
A：能编译、能降级运行，但锁为 `O_EXCL` 文件 + 心跳，存在 TOCTOU 与心跳超时误判的已知限制，不作为主要支持平台。

---

## 📄 License

apache 2.0

---

## 🙏 致谢

- [github.com/cespare/xxhash](https://github.com/cespare/xxhash) — 高性能 64 位哈希
- [golang.org/x/sys](https://pkg.go.dev/golang.org/x/sys) — Windows `LockFileEx` 绑定

---

> 如果你觉得这个项目对你有帮助，欢迎 ⭐ Star。Issue / PR 也非常欢迎，尤其是想补齐 plan9/js 原生化锁与信号语义的场景。