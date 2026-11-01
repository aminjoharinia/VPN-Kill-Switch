// Package core holds what the daemon and the app share: file locations,
// the configuration, the status file and the stores the daemon publishes.
package core

import (
	"os"
	"time"
)

// ModTime is the file's modification time, zero when it is missing.
func ModTime(path string) (t int64) {
	if info, err := os.Stat(path); err == nil {
		return info.ModTime().UnixNano()
	}
	return 0
}

// WriteInPlace truncates and rewrites an existing file without replacing
// it, so its owner and mode survive. An atomic rename would hand the file
// to whoever wrote it — and the app cannot create files in the root-owned
// state directory anyway.
func WriteInPlace(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return err
	}
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// WriteAtomic replaces a file through a temporary in the same directory.
// Only the daemon uses it, for files nobody else writes.
//
// Windows refuses to replace a file another process has open, and the app
// reads these every second; the read is brief, so a few retries get past
// it instead of dropping the update.
func WriteAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	_ = os.Chmod(tmp, mode)
	var err error
	for attempt := 0; attempt < 20; attempt++ {
		if err = os.Rename(tmp, path); err == nil {
			return nil
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = os.Remove(tmp)
	return err
}
