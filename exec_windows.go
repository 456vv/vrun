//go:build !unix

package main

// tryExecReplace 在非 Unix 平台（Windows/plan9/js）不可用。
func tryExecReplace(path string) error {
	return errExecUnsupported
}
