// VPN Kill Switch for Linux: the window and the tray item. Like the macOS
// app it holds no privileges of its own; it reads what the daemon
// publishes and asks for a password (polkit) whenever it changes anything
// that needs root.
package main

import (
	"embed"
	"log"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/linux"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed frontend/dist/icon.png
var appIcon []byte

func main() {
	app := NewApp()
	err := wails.Run(&options.App{
		Title:     "VPN Kill Switch",
		Width:     1000,
		Height:    700,
		MinWidth:  780,
		MinHeight: 560,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		// The light page grey, so the first frame does not flash white.
		BackgroundColour: &options.RGBA{R: 0xE3, G: 0xE4, B: 0xE7, A: 0xFF},
		OnStartup:        app.startup,
		OnShutdown:       app.shutdown,
		// Closing the window keeps the tray item — and the status it
		// shows — alive; Quit from the tray ends the app. See beforeClose.
		OnBeforeClose: app.beforeClose,
		SingleInstanceLock: &options.SingleInstanceLock{
			UniqueId:               "com.vpnkillswitch.linux",
			OnSecondInstanceLaunch: app.onSecondInstance,
		},
		Bind: []interface{}{app},
		Linux: &linux.Options{
			Icon:             appIcon,
			ProgramName:      "vpn-kill-switch",
			WebviewGpuPolicy: linux.WebviewGpuPolicyOnDemand,
		},
	})
	if err != nil {
		log.Fatal(err)
	}
}
