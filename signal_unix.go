//go:build unix

package main

import (
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

func installSignalsForInstall(ch chan<- os.Signal) {
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
}

func installSignalsForRun() chan os.Signal {
	ch := make(chan os.Signal, 2)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGINT, syscall.SIGQUIT)
	return ch
}

// needsExplicitUnlockOnSignal Unix 上 flock 在进程退出时由内核自动释放，
// 信号路径**不**手动 unlock（B5/B10）。
func needsExplicitUnlockOnSignal() bool { return false }

func selfSignalAndExit(sig os.Signal) {
	signal.Reset(sig)
	if p, err := os.FindProcess(os.Getpid()); err == nil {
		_ = p.Signal(sig)
	}
	time.Sleep(50 * time.Millisecond)
	if s, ok := sig.(syscall.Signal); ok {
		os.Exit(128 + int(s))
	}
	os.Exit(1)
}

func handleSignaledExit(exitErr *exec.ExitError) bool {
	if ws, ok := exitErr.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		selfSignalAndExit(ws.Signal())
		return true
	}
	return false
}
