//go:build unix

package main

import (
	"errors"
	"os"
	"syscall"
)

// tryExecReplace 在 Unix（Linux/macOS/BSD）上用真实程序直接替换当前 stub 进程。
func tryExecReplace(path string) error {
	argv := append([]string{os.Args[0]}, os.Args[1:]...)
	if err := syscall.Exec(path, argv, os.Environ()); err != nil {
		return err
	}
	return errors.New("syscall.Exec unexpectedly returned nil")
}
