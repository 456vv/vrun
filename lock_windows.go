//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"time"

	"golang.org/x/sys/windows"
)

// acquireLock 在 Windows 上用 LockFileEx 实现排他锁，与 Unix 的 flock 语义对齐：
//   - 进程终止（含 TerminateProcess）或崩溃时内核自动释放锁，天然防 stale
//   - 持锁进程被挂起超过 lockTimeout 时，其他进程仍无法获取锁（不会被误判 stale）
//   - 无需心跳 goroutine，无需 stale 检测，无 TOCTOU 竞争
//
// 返回的 unlock 释放 LockFileEx 并关闭 fd。
//
// 注意：unlock **不** os.Remove(path)。LockFileEx 保护的是句柄/文件对象，
// 若持锁者先 Unlock 后 unlink，等待者可能已在 unlink 前 lock 成功，
// unlink 成功后新进程再用 O_CREAT 创建新文件并 lock 成功——两方同时持锁。
// 保留锁文件（空壳）不影响后续 LockFileEx 正确性。
func acquireLock(path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}

	handle := windows.Handle(f.Fd())
	// 锁范围 [0, 1) 足够互斥；ol 复用同 range 的 Unlock 也正确。
	ol := new(windows.Overlapped)

	deadline := time.Now().Add(lockTimeout)
	for {
		err := windows.LockFileEx(
			handle,
			windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
			0, 1, 0, ol,
		)
		if err == nil {
			break
		}
		if !errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
			_ = f.Close()
			return nil, fmt.Errorf("获取 LockFileEx 失败: %w", err)
		}
		if time.Now().After(deadline) {
			_ = f.Close()
			return nil, fmt.Errorf("等待安装锁超时（%s）", lockTimeout)
		}
		time.Sleep(100 * time.Millisecond)
	}

	return func() {
		_ = windows.UnlockFileEx(handle, 0, 1, 0, ol)
		_ = f.Close()
		// 不删除 path：见函数头注释
	}, nil
}
