package core

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

// 「删除全部数据」把应用自己产生的东西全部抹掉：下载目录、缓存、数据目录
// （设置、用户、追剧、观看记录、已安装模块）都在其中。用户自己导出到相册或
// 另存到别处的视频不在应用目录里，不会被碰到。
//
// 删除完应用通常需要退出：内存里还握着已删掉的文件句柄与索引，继续跑下去
// 会不断报错，退出重开才是干净状态。

// nativeTreeSize 统计目录下普通文件的总字节数。
func nativeTreeSize(root string) int64 {
	var total int64
	_ = filepath.WalkDir(root, func(_ string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		if info, err := entry.Info(); err == nil {
			total += info.Size()
		}
		return nil
	})
	return total
}

// nativeClearDirectory 清空目录内容但保留目录本身，返回没能删掉的项。
func nativeClearDirectory(directory string) []string {
	entries, err := os.ReadDir(directory)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return []string{directory + "：" + err.Error()}
	}
	var leftover []string
	for _, entry := range entries {
		path := filepath.Join(directory, entry.Name())
		if err := os.RemoveAll(path); err != nil {
			leftover = append(leftover, path+"："+err.Error())
		}
	}
	return leftover
}

// deleteAllData 删除下载目录、缓存与数据目录下的全部内容。
//
// 先停掉正在跑的下载与转码：文件被进程占着时 Windows 上删不掉，会留下一堆
// 「正在使用」的残留。返回没能删除的路径，调用方据此提示用户手动处理。
func (engine *nativeEngine) deleteAllData(extra string) ([]string, error) {
	manager := engine.downloads
	engine.mu.Lock()
	defer engine.mu.Unlock()
	manager.mu.Lock()
	if manager.moving {
		manager.mu.Unlock()
		return nil, errors.New("下载目录正在处理，请稍后重试")
	}
	if len(manager.converting) > 0 {
		manager.mu.Unlock()
		return nil, errors.New("请等待下载的分集处理完成后再删除")
	}
	manager.moving = true
	for _, cancel := range manager.active {
		cancel()
	}
	root := manager.root
	manager.mu.Unlock()
	manager.workers.Wait()

	var leftover []string
	// 下载目录可能是用户指定的任意位置（甚至是 SD 卡根下的子目录），
	// 只删这个目录本身，绝不向上删父目录。
	// 默认情况下它就在数据目录里面，清空数据目录时会一并带走，这里先删也无妨。
	if filepath.IsAbs(root) && filepath.Dir(root) != root {
		if err := os.RemoveAll(root); err != nil {
			leftover = append(leftover, root+"："+err.Error())
		}
	}
	// 缓存按白名单清理，和「清理缓存」同一套口径：被占用的文件跳过并记录。
	if _, err := engine.clearCache(extra); err != nil {
		leftover = append(leftover, "缓存："+err.Error())
	}
	// 数据目录放最后：设置、用户、模块都在这里，删掉之后应用就该退出了。
	leftover = append(leftover, nativeClearDirectory(engine.directory)...)
	return leftover, nil
}
