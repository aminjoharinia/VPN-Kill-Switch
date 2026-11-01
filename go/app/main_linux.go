package main

import (
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/linux"
)

func platformOptions(opts *options.App) {
	opts.Linux = &linux.Options{
		Icon:             appIcon,
		ProgramName:      "vpn-kill-switch",
		WebviewGpuPolicy: linux.WebviewGpuPolicyOnDemand,
	}
}
