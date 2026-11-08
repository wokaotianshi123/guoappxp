package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMagnetEngineDataDirStaysInsideAppData(t *testing.T) {
	base := t.TempDir()
	dir, err := magnetEngineDataDir(base)
	if err != nil {
		t.Fatal(err)
	}
	if dir != magnetCacheDirectory(base) {
		t.Fatalf("磁力缓存目录 = %s，期望固定在应用数据目录下", dir)
	}
	relative, err := filepath.Rel(base, dir)
	if err != nil || strings.HasPrefix(relative, "..") {
		t.Fatalf("磁力缓存目录越出应用数据目录: %s", dir)
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		t.Fatalf("磁力缓存目录不可访问: %v", err)
	}
	for _, invalid := range []string{"", "   ", "relative/data"} {
		if _, err := magnetEngineDataDir(invalid); err == nil {
			t.Fatalf("无效数据目录 %q 不应被接受", invalid)
		}
	}
}

func TestMagnetEngineResetIsSafeWhenIdle(t *testing.T) {
	magnetEngineReset()
	magnetEngineReset()
}
