//go:build unix

package main

import (
	"fmt"
	"os"
	"syscall"
	"time"
)

// acquireLock 在 Unix（Linux/macOS/BSD）上用 flock 实现排他锁：
//   - 进程终止（含 SIGKILL）或崩溃时内核自动释放锁，天然防 stale
//   - 持锁进程被 SIGSTOP/SIGTSTP 挂起超过 lockTimeout 时，其他进程仍无法获取锁
//   - 无需心跳 goroutine
//
// 返回的 unlock 释放 flock 并关闭 fd。
//
// 注意（B4 修复）：unlock **不再** os.Remove(path)。
// flock 保护的是 inode 而非路径。
func acquireLock(path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}

	deadline := time.Now().Add(lockTimeout)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EAGAIN {
			_ = f.Close()
			return nil, fmt.Errorf("获取 flock 失败: %w", err)
		}
		if time.Now().After(deadline) {
			_ = f.Close()
			return nil, fmt.Errorf("等待安装锁超时（%s）", lockTimeout)
		}
		time.Sleep(100 * time.Millisecond)
	}

	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
		// 不删除 path：见函数头注释（B4）
	}, nil
}
