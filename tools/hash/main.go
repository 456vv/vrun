package main

import (
	"bytes"
	"compress/gzip"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/cespare/xxhash/v2"
)

func main() {
	path := flag.String("file", "", "要计算 xxh64 的文件路径")
	decompress := flag.Bool("decompress", false,
		"若输入是 gzip 则先解压再计算哈希（与 stub 中 realAppXXH64Hex 的语义对齐）")
	flag.Parse()

	if *path == "" {
		fmt.Fprintln(os.Stderr, "用法: go run ./tools/hash [-decompress] -file <path>")
		os.Exit(2)
	}

	data, err := os.ReadFile(*path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读取文件失败: %v\n", err)
		os.Exit(1)
	}

	h := xxhash.New()
	if *decompress && len(data) >= 2 && data[0] == 0x1F && data[1] == 0x8B {
		r, gerr := gzip.NewReader(bytes.NewReader(data))
		if gerr != nil {
			fmt.Fprintf(os.Stderr, "创建 gzip 读取器失败: %v\n", gerr)
			os.Exit(1)
		}
		defer r.Close()
		if _, cerr := io.Copy(h, r); cerr != nil {
			fmt.Fprintf(os.Stderr, "解压计算哈希失败: %v\n", cerr)
			os.Exit(1)
		}
	} else {
		h.Write(data)
	}

	fmt.Printf("%016x\n", h.Sum64())
}
