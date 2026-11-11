package main

import (
	"bytes"
	"compress/gzip"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/cespare/xxhash/v2"
)

//go:embed payload.gz
var compressedPayload []byte

// 由构建脚本通过 -ldflags 注入：
//
//	-X main.realAppXXH64Hex=<hex>
var realAppXXH64Hex string

const (
	lockTimeout = 30 * time.Second
	// lockHeartbeat 仅 plan9/js（lock_other.go 的 O_EXCL 锁）使用；
	// Unix 用 flock、Windows 用 LockFileEx，均由内核管理锁生命周期，无需心跳。
	lockHeartbeat = 10 * time.Second
)

var (
	fallbackWarnOnce = sync.Once{}
	// oldCleanupWarnOnce 保证 .old 删除失败提示在每次进程生命周期内只输出一次
	oldCleanupWarnOnce = sync.Once{}
	// tryExecReplace 在非 Unix 平台返回此哨兵值，调用方据此不打印"execve 失败"的误导日志
	errExecUnsupported = errors.New("exec replace not supported on this platform")
)

func main() {
	origPath, realPath, err := resolveExePaths()
	if err != nil {
		log.Fatalf("[stub] 获取可执行文件路径失败: %v", err)
	}

	wantHash, err := resolvePayloadMeta()
	if err != nil {
		log.Fatalf("[stub] 计算 payload 哈希失败: %v", err)
	}

	// 快速路径（无锁）：已安装则直接运行
	if payloadMatches(realPath, wantHash) {
		cleanupResiduals(realPath)
		launchWithRetry(origPath, realPath, wantHash)
		return
	}

	// 需要安装：installOnce 内部持锁 + 双检
	if err := installOnce(realPath, wantHash); err != nil {
		if payloadMatches(realPath, wantHash) {
			launchWithRetry(origPath, realPath, wantHash)
			return
		}
		log.Fatalf("[stub] 安装真实程序失败: %v", err)
	}

	launchWithRetry(origPath, realPath, wantHash)
}

// resolveExePaths 返回 (origPath, realPath)：
//   - origPath：用户视角的路径（os.Executable 原样，尽量绝对化但不 resolve symlink），
//     用于 execve / exec.Command 启动真实程序；execve 会跟随 symlink 到实际文件，
//     因此替换完成后 origPath 依然指向正确文件。
//   - realPath：规范化真实路径，用于 install / 锁 / 替换 / 校验。
//     若 EvalSymlinks 失败（权限、网络路径等异常场景），退化为 Abs(origPath)，
//     与旧逻辑一致（等价于"没有 resolve symlink"）。
func resolveExePaths() (origPath, realPath string, err error) {
	origPath, err = os.Executable()
	if err != nil {
		return "", "", err
	}
	// origPath 尽量绝对化，但保留 symlink 语义（不 resolve）
	if abs, aerr := filepath.Abs(origPath); aerr == nil {
		origPath = abs
	}
	// realPath：优先 EvalSymlinks，失败 fallback 到 Abs
	if p, eerr := filepath.EvalSymlinks(origPath); eerr == nil {
		realPath = p
	} else if abs, aerr := filepath.Abs(origPath); aerr == nil {
		realPath = abs
	} else {
		realPath = origPath
	}
	return origPath, realPath, nil
}

// cleanupResiduals 在确认 exe 已是正确版本后，尽力清理历史残留文件。
// 快速路径每次启动都会调用；删除失败不阻塞启动。
//
// 仅 Windows 上提示 .old 删除失败：Unix 正常替换路径不产生 .old，
// 出现时多为异常恢复残留，"被占用"措辞在 Unix 上有误导性。
func cleanupResiduals(exePath string) {
	_ = os.Remove(exePath + ".new")
	_ = os.Remove(exePath + ".bad")
	if err := os.Remove(exePath + ".old"); err != nil && !os.IsNotExist(err) {
		if runtime.GOOS == "windows" {
			oldCleanupWarnOnce.Do(func() {
				log.Printf("[stub] 提示: 暂无法删除 %s（可能被占用），不影响使用", exePath+".old")
			})
		}
	}
}

// resolvePayloadMeta 返回 payload 的哈希。
//   - 注入了 realAppXXH64Hex：O(1)
//   - 未注入：解压计算（只读，不落盘）
func resolvePayloadMeta() (uint64, error) {
	if realAppXXH64Hex != "" {
		h, perr := strconv.ParseUint(realAppXXH64Hex, 16, 64)
		if perr != nil {
			return 0, fmt.Errorf("解析注入的 realAppXXH64Hex 失败: %w", perr)
		}
		return h, nil
	}

	fallbackWarnOnce.Do(func() {
		log.Println("[stub] 警告: 未注入 realAppXXH64Hex，回退到运行时解压计算（启动较慢）。")
		log.Println("[stub] 建议使用 tools/hash + -ldflags 注入哈希以避免每次启动解压。")
	})
	if len(compressedPayload) == 0 {
		return 0, errors.New("嵌入的 payload.gz 为空，请检查构建流程")
	}
	r, err := gzip.NewReader(bytes.NewReader(compressedPayload))
	if err != nil {
		return 0, err
	}
	defer r.Close()

	h := xxhash.New()
	if _, err := io.Copy(h, r); err != nil {
		return 0, err
	}
	return h.Sum64(), nil
}

// payloadMatches 判定磁盘上的 exe 是否已经是正确版本（仅比哈希）。
// 入参必须是 realPath（规范化的真实文件路径）。
func payloadMatches(exePath string, wantHash uint64) bool {
	got, err := fileXXH64(exePath)
	return err == nil && got == wantHash
}

func fileXXH64(path string) (uint64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	h := xxhash.New()
	if _, err := io.Copy(h, f); err != nil {
		return 0, err
	}
	return h.Sum64(), nil
}

// installOnce 持锁安装。
//   - 入参 exePath 必须是 realPath（规范化真实路径），否则会替换 symlink 本身
//   - 锁内先恢复中断残留（.old → exe），再双检，再替换
//   - 安装期间收到终止信号：Unix/Windows 上**不**手动 unlock
//     （flock / LockFileEx 由内核在进程退出时释放，提前放锁会让其他实例
//     在写文件期间抢占，引发 .new/exe 并发写）；
//     plan9/js 上锁是 O_EXCL 文件，需要手动 unlock。
//
// 信号处理顺序保证：
//   - signal.Notify 前置于 acquireLock，杜绝锁泄漏窗口
//   - defer 中"先放锁，再 signal.Stop"，杜绝默认 handler 直接退出导致锁泄漏
//   - defer 中 signal.Stop 后非阻塞 drain 并补发遗留信号，杜绝信号被吞
func installOnce(exePath string, wantHash uint64) (err error) {
	// 信号处理必须在 acquireLock 之前注册：否则 acquireLock 返回到
	// signal.Notify 之间的窗口内若 SIGTERM 到达，Go 默认 handler 直接
	// os.Exit，锁会泄漏。
	sigCh := make(chan os.Signal, 1)
	installSignalsForInstall(sigCh)

	var (
		unlockFn   func()
		unlockOnce sync.Once
	)
	safeUnlock := func() {
		unlockOnce.Do(func() {
			if unlockFn != nil {
				unlockFn()
			}
		})
	}

	// 信号兜底：安装期间被 SIGTERM/SIGINT/SIGHUP 终止时：
	//   - Unix/Windows：锁由内核在进程退出时自动释放，**不**手动放锁，
	//     避免提前放锁引发 .new/exe 并发写。
	//   - plan9/js：O_EXCL 文件锁不会自动删除，需显式 unlock。
	done := make(chan struct{})
	go func() {
		select {
		case sig := <-sigCh:
			if needsExplicitUnlockOnSignal() {
				safeUnlock()
			}
			selfSignalAndExit(sig)
		case <-done:
		}
	}()

	defer func() {
		close(done)
		// 顺序必须是"先放锁，再撤销 signal handler"。signal.Stop 之后若
		// 恰好有信号到达，Go 默认 handler 会直接 os.Exit，不执行后续
		// defer；放锁在前保证此窗口内无锁泄漏。
		safeUnlock()
		signal.Stop(sigCh)
		// signal.Stop 后 sigCh 里可能有已缓冲但未被 goroutine 读取的信号，
		// 非阻塞 drain 后补发，避免用户发送 SIGTERM 却被"正常完成安装并
		// 启动子程序"吞掉。
		select {
		case sig := <-sigCh:
			selfSignalAndExit(sig)
		default:
		}
	}()

	unlockFn, err = acquireLock(exePath + ".lock")
	if err != nil {
		return fmt.Errorf("获取安装锁失败: %w", err)
	}

	// 锁内恢复上次异常退出的残留
	recoverFromInterruptedInstall(exePath)

	// 双检：等待锁期间另一实例可能已装好
	if payloadMatches(exePath, wantHash) {
		cleanupOldBackup(exePath)
		_ = os.Remove(exePath + ".new")
		return nil
	}

	_ = os.Remove(exePath + ".new")

	log.Println("[stub] 检测到未安装/哈希不匹配，开始解压并替换自身...")
	if exErr := extractAndReplace(exePath, wantHash); exErr != nil {
		return exErr
	}

	got, hErr := fileXXH64(exePath)
	if hErr != nil || got != wantHash {
		// Windows 有 .old 备份可回滚；Unix 上 rename 原子替换无备份
		if runtime.GOOS == "windows" {
			if rbErr := rollback(exePath); rbErr != nil {
				return fmt.Errorf("替换后校验失败(%v)，回滚也失败(%v)", hErr, rbErr)
			}
			if hErr != nil {
				return fmt.Errorf("替换后校验失败(%v)，已回滚到原 stub", hErr)
			}
			return fmt.Errorf("替换后哈希不匹配(want=%016x got=%016x)，已回滚到原 stub", wantHash, got)
		}
		if hErr != nil {
			return fmt.Errorf("替换后校验失败(%v)；请重新运行程序重试", hErr)
		}
		return fmt.Errorf("替换后哈希不匹配(want=%016x got=%016x)；请重新运行程序重试", wantHash, got)
	}

	log.Println("[stub] 替换完成并校验通过。")
	cleanupOldBackup(exePath)
	return nil
}

// extractAndReplace 写 .new → 校验 .new → 替换 exe（exePath 为 realPath）。
func extractAndReplace(exePath string, wantHash uint64) error {
	if len(compressedPayload) == 0 {
		return errors.New("嵌入的 payload.gz 为空")
	}
	tmpPath := exePath + ".new"
	// 保底清理：writeFileFromReader 用 O_EXCL 创建，路径必须干净
	_ = os.Remove(tmpPath)

	r, err := gzip.NewReader(bytes.NewReader(compressedPayload))
	if err != nil {
		return fmt.Errorf("创建 gzip 读取器失败: %w", err)
	}
	defer r.Close()

	if err := writeFileFromReader(tmpPath, r, exePerm(exePath)); err != nil {
		return fmt.Errorf("写入临时文件失败: %w", err)
	}

	if got, hErr := fileXXH64(tmpPath); hErr != nil || got != wantHash {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("临时文件校验失败: want=%016x got=%016x err=%v", wantHash, got, hErr)
	}

	if runtime.GOOS == "windows" {
		return replaceOnWindows(exePath, tmpPath)
	}

	if err := os.Rename(tmpPath, exePath); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("重命名新程序失败: %w", err)
	}
	// fsync 父目录，确保 rename 元数据持久化
	syncDir(filepath.Dir(exePath))
	return nil
}

// replaceOnWindows 用"旧备份 + rename"策略完成自我替换。
// 注：Windows 对运行中 exe 的 rename 依赖系统策略；若被安全软件/占用锁阻塞，
// 需用户重启后重试。
func replaceOnWindows(exePath, tmpPath string) error {
	oldPath := exePath + ".old"
	if err := os.Remove(oldPath); err != nil && !os.IsNotExist(err) {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("清理旧备份 %s 失败: %w", oldPath, err)
	}
	if err := os.Rename(exePath, oldPath); err != nil {
		// 保留 tmpPath 供手动修复（tmp 是已校验过的正确程序）
		return fmt.Errorf("重命名当前存根失败(%v)；可手动将 %q 改名为 %q", err, tmpPath, exePath)
	}
	if err := os.Rename(tmpPath, exePath); err != nil {
		if rbErr := os.Rename(oldPath, exePath); rbErr != nil {
			return fmt.Errorf("重命名新程序失败(%v)，且回滚失败(%v)；请手动将 %q 或 %q 改名为 %q",
				err, rbErr, oldPath, tmpPath, exePath)
		}
		_ = os.Remove(tmpPath)
		return fmt.Errorf("重命名新程序失败: %w", err)
	}
	return nil
}

// rollback 仅 Windows 有 .old 备份可回滚；Unix 原子替换无备份返回 nil。
func rollback(exePath string) error {
	if runtime.GOOS != "windows" {
		return nil
	}
	oldPath := exePath + ".old"
	if _, err := os.Stat(oldPath); err != nil {
		return fmt.Errorf(".old 备份不存在，无法回滚: %w", err)
	}
	badPath := exePath + ".bad"
	_ = os.Remove(badPath)
	if err := os.Rename(exePath, badPath); err != nil {
		return fmt.Errorf("移走坏文件失败: %w", err)
	}
	if err := os.Rename(oldPath, exePath); err != nil {
		_ = os.Rename(badPath, exePath)
		return fmt.Errorf("恢复 .old 失败: %w", err)
	}
	_ = os.Remove(badPath)
	return nil
}

// recoverFromInterruptedInstall 处理上次异常退出的残留。必须在持锁后调用。
func recoverFromInterruptedInstall(exePath string) {
	if _, err := os.Stat(exePath); os.IsNotExist(err) {
		oldPath := exePath + ".old"
		if _, err := os.Stat(oldPath); err == nil {
			if err := os.Rename(oldPath, exePath); err != nil {
				log.Printf("[stub] 警告: 尝试从 %s 恢复主程序失败: %v", oldPath, err)
			} else {
				log.Printf("[stub] 已从 %s 恢复主程序", oldPath)
			}
		}
	}
	if _, err := os.Stat(exePath); err == nil {
		_ = os.Remove(exePath + ".bad")
	}
}

func cleanupOldBackup(exePath string) {
	oldPath := exePath + ".old"
	if err := os.Remove(oldPath); err != nil && !os.IsNotExist(err) {
		log.Printf("[stub] 提示: 暂无法删除 %s（可能被当前进程占用），不影响使用", oldPath)
	}
}

// exePerm 继承原可执行文件权限并确保有执行位。
func exePerm(exePath string) os.FileMode {
	if fi, err := os.Stat(exePath); err == nil {
		return fi.Mode().Perm() | 0o111
	}
	return 0o755
}

// syncDir 尽力 fsync 目录；不支持目录 fsync 的平台上静默忽略。
func syncDir(dir string) {
	d, err := os.Open(dir)
	if err != nil {
		return
	}
	_ = d.Sync()
	_ = d.Close()
}

// writeFileFromReader 写文件并 fsync。
// 用 O_EXCL 创建，确保权限参数生效（O_TRUNC 打开已存在文件不改权限）。
// 调用方负责保证路径不存在（extractAndReplace 已 remove）。
func writeFileFromReader(path string, r io.Reader, perm os.FileMode) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_EXCL, perm)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, r); err != nil {
		_ = f.Close()
		_ = os.Remove(path)
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(path)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(path)
		return err
	}
	return nil
}

// launchWithRetry 包装 runRealApp。
//
// 参数区分：
//   - origPath：用户视角路径，用于 execve / exec.Command 启动（会跟随 symlink）
//   - realPath：规范化真实路径，用于 payloadMatches 校验（与安装目标一致）
//
// Windows 下另一实例 replaceOnWindows 期间 exe 短暂不存在（.old 与 .new 的窗口），
// 若启动前校验失败则短退避重试；其他平台直接调用 runRealApp（Unix 走 execve）。
// 重试耗尽仍失败则报告明确错误，避免启动错误版本或误导性 execve 失败。
func launchWithRetry(origPath, realPath string, wantHash uint64) {
	if runtime.GOOS != "windows" {
		runRealApp(origPath)
		return
	}
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(200*attempt) * time.Millisecond)
		}
		if payloadMatches(realPath, wantHash) {
			runRealApp(origPath)
			return
		}
	}
	log.Fatalf("[stub] 真实程序当前不可用（可能正被另一实例替换），请稍后重试: %s (orig=%s)", realPath, origPath)
}

// runRealApp 启动磁盘上的真实程序，并透传参数/IO/环境变量/退出码。
// 入参 path 应为 origPath（用户视角路径）。execve / exec.Command 会跟随 symlink，
// 因此在 realPath 已完成替换后，origPath 仍能正确指向真实程序。
func runRealApp(path string) {
	// Unix 优先 execve 直接替换进程
	execErr := tryExecReplace(path)
	if execErr == nil {
		return // 防御性：未来若 tryExecReplace 改为成功返回 nil 表示"已替换但未返回"
	}
	if !errors.Is(execErr, errExecUnsupported) {
		log.Printf("[stub] execve 失败，回退 fork+wait: %v", execErr)
	}

	cmd := exec.Command(path, os.Args[1:]...)
	// 关键：argv[0] 与 execve 路径保持一致，兼容 busybox / 多调用名工具
	cmd.Args[0] = os.Args[0]
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	cmd.Env = os.Environ()

	// Start 成功后再注册信号转发，避免信号在 cmd.Process==nil 时被丢弃
	if err := cmd.Start(); err != nil {
		log.Fatalf("[stub] 启动真实程序失败: %v", err)
	}

	sigCh := installSignalsForRun()
	var stopCh chan struct{}
	if sigCh != nil {
		stopCh = make(chan struct{})
		go func() {
			for {
				select {
				case <-stopCh:
					return
				case sig := <-sigCh:
					if cmd.Process != nil {
						_ = cmd.Process.Signal(sig)
					}
				}
			}
		}()
	}

	err := cmd.Wait()

	if sigCh != nil {
		signal.Stop(sigCh)
		close(stopCh)
	}

	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			// 子进程被信号杀死时 ExitCode() 返回 -1（stub 会错误地以 255 退出）。
			// handleSignaledExit 在 Unix 上重发同信号给自身，让父 shell 正确感知
			// "被信号终止"；Windows/plan9 直接返回 false，走 ExitCode 分支。
			if handleSignaledExit(exitErr) {
				return
			}
			os.Exit(exitErr.ExitCode())
		}
		log.Fatalf("[stub] 启动真实程序失败: %v", err)
	}
}
