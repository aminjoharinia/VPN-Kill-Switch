package main

import (
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

func platformOptions(opts *options.App) {
	opts.Windows = &windows.Options{
		// The title bar follows the system; the page follows the app's own
		// Appearance setting.
		Theme: windows.SystemDefault,
	}
}
