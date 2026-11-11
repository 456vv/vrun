//go:build !unix && !windows

package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// acquireLock 在 plan9/js 等非 Unix 非 Windows 平台用 O_EXCL 锁文件 + 心跳。
//
// 已知限制（方案二不修，保留待后续平台原生化）：
//   - 进程被强杀（无信号语义）时锁文件残留，依赖 mtime 超时（lockTimeout）判 stale
//   - stale 检查 + removeStaleLock 之间存在 TOCTOU 竞争（rename 对象是路径而非 inode）
//   - 持锁进程被挂起超过 lockTimeout 时会被误判 stale，可能双持锁
//
// plan9/js 场景并发安装概率极低，作为已知限制接受。
// Unix 见 lock_unix.go（flock），Windows 见 lock_windows.go（LockFileEx）。
func acquireLock(path string) (func(), error) {
	deadline := time.Now().Add(lockTimeout)
	myPID := strconv.Itoa(os.Getpid())
	for {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err == nil {
			if _, werr := fmt.Fprintf(f, "%s\n", myPID); werr != nil {
				_ = f.Close()
				_ = os.Remove(path)
				return nil, werr
			}
			if cerr := f.Close(); cerr != nil {
				_ = os.Remove(path)
				return nil, cerr
			}

			stop := make(chan struct{})
			heartbeatDone := make(chan struct{})
			go func() {
				defer close(heartbeatDone)
				t := time.NewTicker(lockHeartbeat)
				defer t.Stop()
				for {
					select {
					case <-stop:
						return
					case <-t.C:
						// 心跳前校验内容仍是本进程，防止刷活别人的锁文件（Bug 10）
						data, rerr := os.ReadFile(path)
						if rerr != nil || strings.TrimSpace(string(data)) != myPID {
							return
						}
						now := time.Now()
						_ = os.Chtimes(path, now, now)
					}
				}
			}()

			return func() {
				close(stop)
				<-heartbeatDone
				if data, err := os.ReadFile(path); err == nil && strings.TrimSpace(string(data)) == myPID {
					_ = os.Remove(path)
				}
			}, nil
		}
		if !os.IsExist(err) {
			return nil, err
		}
		if fi, statErr := os.Stat(path); statErr == nil && time.Since(fi.ModTime()) > lockTimeout {
			removeStaleLock(path)
			continue
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("等待安装锁超时（%s）", lockTimeout)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// removeStaleLock 将陈旧锁 rename 到唯一临时名后再删除。
// 已知 TOCTOU 限制：rename 对象是路径而非 inode，竞态窗口内可能移走他人新锁。
func removeStaleLock(path string) {
	stale := path + ".stale." + strconv.Itoa(os.Getpid()) + "." + strconv.FormatInt(time.Now().UnixNano(), 36)
	if err := os.Rename(path, stale); err == nil {
		_ = os.Remove(stale)
	}
}
