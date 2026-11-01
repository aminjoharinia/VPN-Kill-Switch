package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/png"
)

// The notification area is always there on Windows.
func trayAvailable() bool { return true }

// trayImage wraps the drawn PNG in an .ico, the only format the Windows
// tray loads. It carries 16, 32 and 64 px versions, so Windows picks a
// sharp one at every display scale instead of shrinking the largest.
func trayImage(pngData []byte) []byte {
	src, err := png.Decode(bytes.NewReader(pngData))
	if err != nil {
		return pngData
	}
	sizes := []int{16, 32, 64}
	images := make([][]byte, len(sizes))
	for i, size := range sizes {
		if size == src.Bounds().Dx() {
			images[i] = pngData
			continue
		}
		var buf bytes.Buffer
		_ = png.Encode(&buf, shrink(src, size))
		images[i] = buf.Bytes()
	}

	var out bytes.Buffer
	// ICONDIR, then one ICONDIRENTRY per image, then the images. PNG
	// entries are valid in an .ico since Windows Vista.
	binary.Write(&out, binary.LittleEndian, [3]uint16{0, 1, uint16(len(sizes))})
	offset := 6 + 16*len(sizes)
	for i, size := range sizes {
		dim := uint8(size)
		if size >= 256 {
			dim = 0
		}
		binary.Write(&out, binary.LittleEndian, struct {
			W, H, Colors, Reserved uint8
			Planes, BitCount       uint16
			Size, Offset           uint32
		}{dim, dim, 0, 0, 1, 32, uint32(len(images[i])), uint32(offset)})
		offset += len(images[i])
	}
	for _, img := range images {
		out.Write(img)
	}
	return out.Bytes()
}

// shrink box-filters a square image down to size×size, averaging in
// premultiplied alpha so edges against transparency stay clean.
func shrink(src image.Image, size int) *image.NRGBA {
	b := src.Bounds()
	factor := b.Dx() / size
	dst := image.NewNRGBA(image.Rect(0, 0, size, size))
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			var r, g, bl, a uint32
			for dy := 0; dy < factor; dy++ {
				for dx := 0; dx < factor; dx++ {
					pr, pg, pb, pa := src.At(b.Min.X+x*factor+dx, b.Min.Y+y*factor+dy).RGBA()
					r, g, bl, a = r+pr, g+pg, bl+pb, a+pa
				}
			}
			if a == 0 {
				continue
			}
			n := uint32(factor * factor)
			dst.SetNRGBA(x, y, color.NRGBA{
				uint8(r * 255 / a), uint8(g * 255 / a), uint8(bl * 255 / a), uint8(a / n >> 8),
			})
		}
	}
	return dst
}
