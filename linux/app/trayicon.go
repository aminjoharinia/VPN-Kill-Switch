package main

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"math"
)

// Tray icons are drawn here rather than shipped as files, so every state
// in every style is one function and stays crisp at any panel size.
//
// The macOS menu bar shows a word (ON / CUT / ARMED / OFF) on a hazard-
// striped pill. A Linux tray slot is a small square, too small for a word,
// so the state is carried by the dot's colour on the same stripes, and the
// word goes in the tooltip and the menu.

// Dark-theme halves of the Daftar tones: the panel is dark on Ubuntu, and
// the striped plate is dark in either theme.
var (
	toneGood    = rgb(0x81C784)
	toneCaution = rgb(0xFF8A65)
	toneDanger  = rgb(0xEF7B7B)
	toneArmed   = rgb(0x8CC4F0)
	hazardAmber = rgb(0xF2CF55)
	hazardDark  = rgb(0x3B2B26)
	plate       = color.NRGBA{0x1C, 0x0F, 0x0B, 0xE6}
)

func rgb(hex uint32) color.NRGBA {
	return color.NRGBA{uint8(hex >> 16), uint8(hex >> 8), uint8(hex), 0xFF}
}

type shape func(x, y float64) bool

type layer struct {
	inside shape
	fill   color.NRGBA
}

const iconSize = 64

// render paints the layers in order with 4×4 supersampling per pixel.
func render(layers []layer) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, iconSize, iconSize))
	const ss = 4
	for py := 0; py < iconSize; py++ {
		for px := 0; px < iconSize; px++ {
			var r, g, b, a float64
			for sy := 0; sy < ss; sy++ {
				for sx := 0; sx < ss; sx++ {
					x := float64(px) + (float64(sx)+0.5)/ss
					y := float64(py) + (float64(sy)+0.5)/ss
					var cr, cg, cb, ca float64
					for _, l := range layers {
						if !l.inside(x, y) {
							continue
						}
						la := float64(l.fill.A) / 255
						cr = float64(l.fill.R)*la + cr*(1-la)
						cg = float64(l.fill.G)*la + cg*(1-la)
						cb = float64(l.fill.B)*la + cb*(1-la)
						ca = la + ca*(1-la)
					}
					r, g, b, a = r+cr, g+cg, b+cb, a+ca
				}
			}
			n := float64(ss * ss)
			if a == 0 {
				continue
			}
			// Un-premultiply.
			img.SetNRGBA(px, py, color.NRGBA{
				uint8(math.Round(r / a)), uint8(math.Round(g / a)), uint8(math.Round(b / a)),
				uint8(math.Round(a / n * 255)),
			})
		}
	}
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

func circle(cx, cy, r float64) shape {
	return func(x, y float64) bool { return (x-cx)*(x-cx)+(y-cy)*(y-cy) <= r*r }
}

func roundedSquare(inset, radius float64) shape {
	lo, hi := inset, iconSize-inset
	return func(x, y float64) bool {
		if x < lo || x > hi || y < lo || y > hi {
			return false
		}
		cx := math.Max(lo+radius, math.Min(x, hi-radius))
		cy := math.Max(lo+radius, math.Min(y, hi-radius))
		return (x-cx)*(x-cx)+(y-cy)*(y-cy) <= radius*radius
	}
}

func and(a, b shape) shape { return func(x, y float64) bool { return a(x, y) && b(x, y) } }

// stripes leaning 20°, like the app icon's hazard tape.
func stripes(band, gap float64) shape {
	lean := math.Tan(20 * math.Pi / 180)
	period := band + gap
	return func(x, y float64) bool {
		u := x + (iconSize-y)*lean
		m := math.Mod(u, period)
		if m < 0 {
			m += period
		}
		return m < band
	}
}

// trayIcon draws the state: tone is the dot colour; busy shows three dots;
// hollow draws a ring, so "off" differs from "cut" by shape and not only
// by two close shades of red and orange.
func trayIcon(tone color.NRGBA, busy, hollow, striped bool) []byte {
	var layers []layer
	if striped {
		body := roundedSquare(2, 14)
		layers = append(layers,
			layer{body, hazardDark},
			layer{and(body, stripes(9, 10)), hazardAmber},
			layer{circle(32, 32, 20), plate},
		)
	} else {
		// A plain dot with a dark ring, legible on light and dark panels.
		layers = append(layers, layer{circle(32, 32, 24), plate})
	}
	if busy {
		for _, cx := range []float64{20, 32, 44} {
			layers = append(layers, layer{circle(cx, 32, 5), tone})
		}
	} else {
		r := 17.0
		if striped {
			r = 11
		}
		layers = append(layers, layer{circle(32, 32, r), tone})
		if hollow {
			layers = append(layers, layer{circle(32, 32, r*0.55), plate})
		}
	}
	return render(layers)
}
