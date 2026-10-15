package core

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Log is the daemon's activity log, with the macOS daemon's retention: the
// live file is always kill_switch.log, and when a month ends it is renamed
// kill_switch-YYYY-MM.log. Archives older than the previous month are
// deleted. A 5 MB cap archives the live file early if anything floods it.
type Log struct {
	mu        sync.Mutex
	path      string
	fileMonth string
	echo      bool
}

const maxLogBytes = 5 * 1024 * 1024

var std = &Log{path: LogFile, echo: isTerminal(os.Stderr)}

// Under systemd stderr goes to the journal, which would be a second copy
// of every line; echo only when someone runs `vpnks daemon` by hand.
func isTerminal(f *os.File) bool {
	info, err := f.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

// Logf writes one dated line to the daemon log.
func Logf(format string, args ...any) { std.write(fmt.Sprintf(format, args...)) }

func (l *Log) write(message string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	line := now.Format("2006-01-02 15:04:05") + " " + message + "\n"
	if l.echo {
		os.Stderr.WriteString(line)
	}
	l.rotateIfNeeded(now.Format("2006-01"))
	f, err := os.OpenFile(l.path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return
	}
	f.WriteString(line)
	f.Close()
}

func (l *Log) rotateIfNeeded(month string) {
	if l.fileMonth == "" {
		l.fileMonth = monthOfFirstLine(l.path)
		if l.fileMonth == "" {
			l.fileMonth = month
		}
	}
	var size int64
	if info, err := os.Stat(l.path); err == nil {
		size = info.Size()
	}
	if l.fileMonth == month && size <= maxLogBytes {
		return
	}
	if size > 0 {
		l.archive(l.fileMonth)
	}
	l.fileMonth = month
	l.prune(previousMonth(month))
}

// archive renames the live file to kill_switch-<month>.log, or -2, -3… if
// the size cap already archived part of that month.
func (l *Log) archive(month string) {
	base := strings.TrimSuffix(l.path, ".log")
	target := fmt.Sprintf("%s-%s.log", base, month)
	for n := 2; fileExists(target); n++ {
		target = fmt.Sprintf("%s-%s-%d.log", base, month, n)
	}
	_ = os.Rename(l.path, target)
}

func (l *Log) prune(oldest string) {
	dir := filepath.Dir(l.path)
	stem := strings.TrimSuffix(filepath.Base(l.path), ".log")
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		name := e.Name()
		if !strings.HasPrefix(name, stem+"-") || !strings.HasSuffix(name, ".log") {
			continue
		}
		rest := strings.TrimPrefix(name, stem+"-")
		if len(rest) >= 7 && rest[:7] < oldest {
			_ = os.Remove(filepath.Join(dir, name))
		}
	}
}

func previousMonth(month string) string {
	t, err := time.Parse("2006-01", month)
	if err != nil {
		return month
	}
	return t.AddDate(0, -1, 0).Format("2006-01")
}

// monthOfFirstLine is the month of the first dated line, so a log carried
// over from before a restart is archived under the right month.
func monthOfFirstLine(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for i := 0; i < 50 && scanner.Scan(); i++ {
		line := scanner.Text()
		if len(line) >= 7 && line[4] == '-' {
			if _, err := time.Parse("2006-01", line[:7]); err == nil {
				return line[:7]
			}
		}
	}
	return ""
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
