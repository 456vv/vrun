//go:build windows

package main

import (
	"os"
	"os/exec"
	"os/signal"
	"syscall"
)

// installSignalsForInstall Windows 仅注册编译期存在的信号。
func installSignalsForInstall(ch chan<- os.Signal) {
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
}

// installSignalsForRun Windows 不做 fork+wait 信号转发。
func installSignalsForRun() chan os.Signal { return nil }

// needsExplicitUnlockOnSignal Windows 使用 LockFileEx，进程终止时内核自动释放锁，
// 与 Unix 的 flock 语义一致；信号路径**不**手动 unlock。
func needsExplicitUnlockOnSignal() bool { return false }

// selfSignalAndExit Windows 无法重发 POSIX 信号，直接以 128+signum 退出，
// 与 Unix 的 shell 约定保持一致。
func selfSignalAndExit(sig os.Signal) {
	signal.Reset(sig)
	if s, ok := sig.(syscall.Signal); ok {
		os.Exit(128 + int(s))
	}
	os.Exit(1)
}

// handleSignaledExit Windows 上 syscall.WaitStatus.Signaled() 恒为 false。
func handleSignaledExit(exitErr *exec.ExitError) bool { return false }
