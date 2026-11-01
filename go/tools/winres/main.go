// winres writes the Windows resources the two programs carry — the icon
// and the application manifest — as a .syso object the Go linker picks up
// from the package directory, and the icon as a standalone .ico for the
// installer and shortcuts. windows/build.sh runs it; it has no
// dependencies outside the standard library.
//
//	go run ./tools/winres -arch amd64 -manifest gui -out app/rsrc_windows_amd64.syso \
//	    -ico output/app.ico 32.png 64.png 128.png 256.png
//
// The icon PNGs are square, one per size; a 16 px version is made from the
// 32 px one.
package main

import (
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"sort"
)

// Common Controls 6 (themed dialogs), per-monitor DPI awareness (sharp text
// at every display scale) and asInvoker: the app elevates only the CLI,
// through UAC, when it needs to.
const guiManifest = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1" xmlns:asmv3="urn:schemas-microsoft-com:asm.v3">
  <assemblyIdentity type="win32" name="VPNKillSwitch.App" version="1.0.0.0" processorArchitecture="*"/>
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
    </dependentAssembly>
  </dependency>
  <asmv3:application>
    <asmv3:windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">permonitorv2,permonitor</dpiAwareness>
    </asmv3:windowsSettings>
  </asmv3:application>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security>
  </trustInfo>
</assembly>
`

// The CLI runs unelevated for status and elevated for changes; asInvoker
// keeps Windows from guessing (a program run with "install" in its
// arguments is otherwise not affected, but one named like an installer is).
const cliManifest = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity type="win32" name="VPNKillSwitch.vpnks" version="1.0.0.0" processorArchitecture="*"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security>
  </trustInfo>
</assembly>
`

const (
	rtIcon      = 3
	rtGroupIcon = 14
	rtManifest  = 24
	// Wails loads the window icon from this group (winc.AppIconID).
	appIconID = 3
	langEnUS  = 0x0409
)

type resource struct {
	typ, id uint16
	data    []byte
}

func main() {
	arch := flag.String("arch", "amd64", "amd64 or arm64")
	manifest := flag.String("manifest", "gui", "gui or cli")
	out := flag.String("out", "", "the .syso to write")
	ico := flag.String("ico", "", "also write the icon as a standalone .ico")
	flag.Parse()
	if *out == "" || flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "usage: winres -arch amd64|arm64 -manifest gui|cli -out file.syso [-ico file.ico] icon.png…")
		os.Exit(2)
	}

	images, err := loadIcons(flag.Args())
	if err != nil {
		fail(err)
	}

	m := guiManifest
	if *manifest == "cli" {
		m = cliManifest
	}
	res := []resource{{rtManifest, 1, []byte(m)}}
	group := groupIconDir(images)
	for i, img := range images {
		res = append(res, resource{rtIcon, uint16(i + 1), img.png})
	}
	res = append(res, resource{rtGroupIcon, appIconID, group})

	machine, reloc := uint16(0x8664), uint16(0x0003) // IMAGE_REL_AMD64_ADDR32NB
	if *arch == "arm64" {
		machine, reloc = 0xAA64, 0x0002 // IMAGE_REL_ARM64_ADDR32NB
	}
	if err := os.WriteFile(*out, coff(machine, reloc, res), 0o644); err != nil {
		fail(err)
	}
	if *ico != "" {
		if err := os.WriteFile(*ico, icoFile(images), 0o644); err != nil {
			fail(err)
		}
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "winres:", err)
	os.Exit(1)
}

type iconImage struct {
	size int
	png  []byte
}

func loadIcons(paths []string) ([]iconImage, error) {
	var out []iconImage
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			return nil, err
		}
		img, err := png.Decode(bytes.NewReader(data))
		if err != nil {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
		size := img.Bounds().Dx()
		if size != img.Bounds().Dy() || size > 256 {
			return nil, fmt.Errorf("%s: icons must be square and at most 256 px", p)
		}
		out = append(out, iconImage{size, data})
		if size == 32 {
			var buf bytes.Buffer
			if err := png.Encode(&buf, shrink(img, 16)); err != nil {
				return nil, err
			}
			out = append(out, iconImage{16, buf.Bytes()})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].size < out[j].size })
	return out, nil
}

// shrink box-filters a square image down by an integer factor, averaging
// in premultiplied alpha.
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
			dst.SetNRGBA(x, y, color.NRGBA{uint8(r * 255 / a), uint8(g * 255 / a), uint8(bl * 255 / a), uint8(a / n >> 8)})
		}
	}
	return dst
}

func dim(size int) uint8 {
	if size >= 256 {
		return 0 // 0 means 256 in icon directories
	}
	return uint8(size)
}

// groupIconDir is GRPICONDIR: like an .ico header, but each entry names a
// resource ID (2 bytes) where an .ico has a file offset (4 bytes).
func groupIconDir(images []iconImage) []byte {
	var b bytes.Buffer
	binary.Write(&b, binary.LittleEndian, [3]uint16{0, 1, uint16(len(images))})
	for i, img := range images {
		b.Write([]byte{dim(img.size), dim(img.size), 0, 0})
		binary.Write(&b, binary.LittleEndian, uint16(1))  // planes
		binary.Write(&b, binary.LittleEndian, uint16(32)) // bits per pixel
		binary.Write(&b, binary.LittleEndian, uint32(len(img.png)))
		binary.Write(&b, binary.LittleEndian, uint16(i+1))
	}
	return b.Bytes()
}

func icoFile(images []iconImage) []byte {
	var b bytes.Buffer
	binary.Write(&b, binary.LittleEndian, [3]uint16{0, 1, uint16(len(images))})
	offset := 6 + 16*len(images)
	for _, img := range images {
		b.Write([]byte{dim(img.size), dim(img.size), 0, 0})
		binary.Write(&b, binary.LittleEndian, uint16(1))
		binary.Write(&b, binary.LittleEndian, uint16(32))
		binary.Write(&b, binary.LittleEndian, uint32(len(img.png)))
		binary.Write(&b, binary.LittleEndian, uint32(offset))
		offset += len(img.png)
	}
	for _, img := range images {
		b.Write(img.png)
	}
	return b.Bytes()
}

// coff builds an object file with one .rsrc section holding the resource
// tree — type, then ID, then language — followed by the data. Each data
// entry's address is relative to the section, so it carries a relocation
// the linker resolves against the section's final address.
func coff(machine, relocType uint16, res []resource) []byte {
	sort.SliceStable(res, func(i, j int) bool {
		if res[i].typ != res[j].typ {
			return res[i].typ < res[j].typ
		}
		return res[i].id < res[j].id
	})
	var types []uint16
	byType := map[uint16][]int{}
	for i, r := range res {
		if len(byType[r.typ]) == 0 {
			types = append(types, r.typ)
		}
		byType[r.typ] = append(byType[r.typ], i)
	}

	const dirSize, entrySize, dataEntrySize = 16, 8, 16
	// Offsets of every table, in the order they are laid out.
	rootSize := dirSize + entrySize*len(types)
	typeDir := map[uint16]int{}
	at := rootSize
	for _, t := range types {
		typeDir[t] = at
		at += dirSize + entrySize*len(byType[t])
	}
	langDir := make([]int, len(res))
	for i := range res {
		langDir[i] = at
		at += dirSize + entrySize
	}
	dataEntry := make([]int, len(res))
	for i := range res {
		dataEntry[i] = at
		at += dataEntrySize
	}
	blob := make([]int, len(res))
	for i, r := range res {
		at = (at + 7) &^ 7
		blob[i] = at
		at += len(r.data)
	}
	size := (at + 3) &^ 3

	sec := make([]byte, size)
	le := binary.LittleEndian
	dir := func(off, ids int) { le.PutUint16(sec[off+14:], uint16(ids)) }
	entry := func(off int, id uint16, target int, subdir bool) {
		le.PutUint32(sec[off:], uint32(id))
		v := uint32(target)
		if subdir {
			v |= 0x80000000
		}
		le.PutUint32(sec[off+4:], v)
	}
	dir(0, len(types))
	for k, t := range types {
		entry(dirSize+entrySize*k, t, typeDir[t], true)
		dir(typeDir[t], len(byType[t]))
		for n, i := range byType[t] {
			entry(typeDir[t]+dirSize+entrySize*n, res[i].id, langDir[i], true)
		}
	}
	for i, r := range res {
		dir(langDir[i], 1)
		entry(langDir[i]+dirSize, langEnUS, dataEntry[i], false)
		le.PutUint32(sec[dataEntry[i]:], uint32(blob[i])) // relocated
		le.PutUint32(sec[dataEntry[i]+4:], uint32(len(r.data)))
		copy(sec[blob[i]:], r.data)
	}

	const fileHeader, sectionHeader, relocSize, symbolSize = 20, 40, 10, 18
	rawAt := fileHeader + sectionHeader
	relocAt := rawAt + size
	symAt := relocAt + relocSize*len(res)

	var b bytes.Buffer
	w := func(v any) { binary.Write(&b, le, v) }
	// IMAGE_FILE_HEADER
	w(machine)
	w(uint16(1)) // sections
	w(uint32(0)) // timestamp: reproducible builds
	w(uint32(symAt))
	w(uint32(1)) // symbols
	w(uint16(0)) // no optional header
	w(uint16(0)) // characteristics
	// IMAGE_SECTION_HEADER
	b.WriteString(".rsrc\x00\x00\x00")
	w(uint32(0)) // virtual size
	w(uint32(0)) // virtual address
	w(uint32(size))
	w(uint32(rawAt))
	w(uint32(relocAt))
	w(uint32(0)) // line numbers
	w(uint16(len(res)))
	w(uint16(0))
	w(uint32(0x40000040)) // initialized data, readable
	b.Write(sec)
	// IMAGE_RELOCATION per data entry, against symbol 0 (the section).
	for i := range res {
		w(uint32(dataEntry[i]))
		w(uint32(0))
		w(relocType)
	}
	// IMAGE_SYMBOL for the section, then an empty string table.
	b.WriteString(".rsrc\x00\x00\x00")
	w(uint32(0)) // value
	w(int16(1))  // section number
	w(uint16(0)) // type
	w(uint8(3))  // IMAGE_SYM_CLASS_STATIC
	w(uint8(0))  // aux symbols
	w(uint32(4)) // string table size
	return b.Bytes()
}
