//go:build !unix && !windows

package main

import (
	"os"
	"os/exec"
	"os/signal"
)

// installSignalsForInstall plan9/js 等平台 syscall 无对应信号常量，no-op。
func installSignalsForInstall(ch chan<- os.Signal) { _ = ch }

// installSignalsForRun plan9/js 不做信号转发。
func installSignalsForRun() chan os.Signal { return nil }

// needsExplicitUnlockOnSignal plan9/js 用 lock_other.go 的 O_EXCL 文件锁，
// 进程退出不会自动删除，需手动清理。
func needsExplicitUnlockOnSignal() bool { return true }

// selfSignalAndExit plan9/js 无 POSIX 信号语义：
//   - plan9 的 syscall 使用 Note（字符串），无法转为 128+N 的数字退出码
//   - js 的 syscall.Signal 语义有限，与 Unix 并不等价
//
// 因此保持 os.Exit(1)；如需 128+signum 需在对应平台单独实现。
func selfSignalAndExit(sig os.Signal) {
	signal.Reset(sig)
	os.Exit(1)
}

// handleSignaledExit plan9/js 无 WaitStatus.Signaled 语义，返回 false 让调用方走 ExitCode。
func handleSignaledExit(exitErr *exec.ExitError) bool { return false }
