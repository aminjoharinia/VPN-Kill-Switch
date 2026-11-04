package daemon

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// A minimal binding to the Windows Filtering Platform management API
// (fwpuclnt.dll): just what the kill switch needs — a provider and a
// sublayer of our own, filters added and removed in one transaction, and a
// lookup to confirm the block is in force. Struct layouts follow
// fwpmtypes.h for 64-bit Windows (amd64 and arm64); wfp_windows_test.go
// checks them.

var (
	modfwpuclnt = windows.NewLazySystemDLL("fwpuclnt.dll")

	procFwpmEngineOpen0              = modfwpuclnt.NewProc("FwpmEngineOpen0")
	procFwpmEngineClose0             = modfwpuclnt.NewProc("FwpmEngineClose0")
	procFwpmTransactionBegin0        = modfwpuclnt.NewProc("FwpmTransactionBegin0")
	procFwpmTransactionCommit0       = modfwpuclnt.NewProc("FwpmTransactionCommit0")
	procFwpmTransactionAbort0        = modfwpuclnt.NewProc("FwpmTransactionAbort0")
	procFwpmProviderAdd0             = modfwpuclnt.NewProc("FwpmProviderAdd0")
	procFwpmProviderDeleteByKey0     = modfwpuclnt.NewProc("FwpmProviderDeleteByKey0")
	procFwpmSubLayerAdd0             = modfwpuclnt.NewProc("FwpmSubLayerAdd0")
	procFwpmSubLayerDeleteByKey0     = modfwpuclnt.NewProc("FwpmSubLayerDeleteByKey0")
	procFwpmFilterAdd0               = modfwpuclnt.NewProc("FwpmFilterAdd0")
	procFwpmFilterDeleteByKey0       = modfwpuclnt.NewProc("FwpmFilterDeleteByKey0")
	procFwpmFilterGetByKey0          = modfwpuclnt.NewProc("FwpmFilterGetByKey0")
	procFwpmFilterCreateEnumHandle0  = modfwpuclnt.NewProc("FwpmFilterCreateEnumHandle0")
	procFwpmFilterEnum0              = modfwpuclnt.NewProc("FwpmFilterEnum0")
	procFwpmFilterDestroyEnumHandle0 = modfwpuclnt.NewProc("FwpmFilterDestroyEnumHandle0")
	procFwpmFreeMemory0              = modfwpuclnt.NewProc("FwpmFreeMemory0")
	procFwpmGetAppIdFromFileName0    = modfwpuclnt.NewProc("FwpmGetAppIdFromFileName0")
)

// MARK: Types (fwptypes.h, fwpmtypes.h)

type fwpmDisplayData0 struct {
	name        *uint16
	description *uint16
}

type fwpmSession0 struct {
	sessionKey           windows.GUID
	displayData          fwpmDisplayData0
	flags                uint32
	txnWaitTimeoutInMSec uint32
	processID            uint32
	sid                  *windows.SID
	username             *uint16
	kernelMode           int32
}

type fwpByteBlob struct {
	size uint32
	data *uint8
}

type fwpmProvider0 struct {
	providerKey  windows.GUID
	displayData  fwpmDisplayData0
	flags        uint32
	providerData fwpByteBlob
	serviceName  *uint16
}

type fwpmSublayer0 struct {
	subLayerKey  windows.GUID
	displayData  fwpmDisplayData0
	flags        uint32
	providerKey  *windows.GUID
	providerData fwpByteBlob
	weight       uint16
}

// fwpValue0 is FWP_VALUE0 and FWP_CONDITION_VALUE0: a type tag and a
// pointer-sized union. 64-bit integers, byte blobs and address masks are
// passed by pointer.
type fwpValue0 struct {
	typ   uint32
	value uintptr
}

type fwpmFilterCondition0 struct {
	fieldKey       windows.GUID
	matchType      uint32
	conditionValue fwpValue0
}

type fwpmAction0 struct {
	typ        uint32
	filterType windows.GUID // or calloutKey
}

type fwpmFilter0 struct {
	filterKey           windows.GUID
	displayData         fwpmDisplayData0
	flags               uint32
	providerKey         *windows.GUID
	providerData        fwpByteBlob
	layerKey            windows.GUID
	subLayerKey         windows.GUID
	weight              fwpValue0
	numFilterConditions uint32
	filterCondition     *fwpmFilterCondition0
	action              fwpmAction0
	_                   [4]byte      // the union below is 8-byte aligned
	providerContextKey  windows.GUID // union with rawContext (UINT64)
	reserved            *windows.GUID
	filterID            uint64
	effectiveWeight     fwpValue0
}

type fwpV4AddrAndMask struct {
	addr uint32 // host byte order
	mask uint32
}

type fwpV6AddrAndMask struct {
	addr         [16]byte
	prefixLength uint8
}

// MARK: Constants

const (
	rpcCAuthnWinNT = 10

	fwpEmpty          = 0
	fwpUint8          = 1
	fwpUint16         = 2
	fwpUint32         = 3
	fwpUint64         = 4
	fwpByteArray16    = 11
	fwpByteBlobType   = 12
	fwpV4AddrMaskType = 0x100
	fwpV6AddrMaskType = 0x101

	fwpMatchEqual       = 0
	fwpMatchFlagsAllSet = 6

	fwpActionBlock  = 0x1001
	fwpActionPermit = 0x1002

	fwpmProviderFlagPersistent = 0x1
	fwpmSublayerFlagPersistent = 0x1
	fwpmFilterFlagPersistent   = 0x1

	fwpConditionFlagIsLoopback = 0x1

	ipprotoICMPv6 = 58
	ipprotoUDP    = 17

	// FWP_E_* results worth telling apart.
	fwpEAlreadyExists  = 0x80320009
	fwpEFilterNotFound = 0x80320003
	fwpENotFound       = 0x80320008
	fwpEInUse          = 0x8032000A
)

var (
	layerALEAuthConnectV4    = windows.GUID{Data1: 0xc38d57d1, Data2: 0x05a7, Data3: 0x4c33, Data4: [8]byte{0x90, 0x4f, 0x7f, 0xbc, 0xee, 0xe6, 0x0e, 0x82}}
	layerALEAuthConnectV6    = windows.GUID{Data1: 0x4a72393b, Data2: 0x319f, Data3: 0x44bc, Data4: [8]byte{0x84, 0xc3, 0xba, 0x54, 0xdc, 0xb3, 0xb6, 0xb4}}
	layerALEAuthRecvAcceptV4 = windows.GUID{Data1: 0xe1cd9fe7, Data2: 0xf4b5, Data3: 0x4273, Data4: [8]byte{0x96, 0xc0, 0x59, 0x2e, 0x48, 0x7b, 0x86, 0x50}}
	layerALEAuthRecvAcceptV6 = windows.GUID{Data1: 0xa3b42c97, Data2: 0x9f04, Data3: 0x4672, Data4: [8]byte{0xb8, 0x7e, 0xce, 0xe9, 0xc4, 0x83, 0x25, 0x7f}}

	conditionIPLocalInterface = windows.GUID{Data1: 0x4cd62a49, Data2: 0x59c3, Data3: 0x4969, Data4: [8]byte{0xb7, 0xf3, 0xbd, 0xa5, 0xd3, 0x28, 0x90, 0xa4}}
	conditionIPRemoteAddress  = windows.GUID{Data1: 0xb235ae9a, Data2: 0x1d64, Data3: 0x49b8, Data4: [8]byte{0xa4, 0x4c, 0x5f, 0xf3, 0xd9, 0x09, 0x50, 0x45}}
	conditionIPRemotePort     = windows.GUID{Data1: 0xc35a604d, Data2: 0xd22b, Data3: 0x4e1a, Data4: [8]byte{0x91, 0xb4, 0x68, 0xf6, 0x74, 0xee, 0x67, 0x4b}}
	conditionIPLocalPort      = windows.GUID{Data1: 0x0c1ba1af, Data2: 0x5765, Data3: 0x453f, Data4: [8]byte{0xaf, 0x22, 0xa8, 0xf7, 0x91, 0xac, 0x77, 0x5b}}
	conditionIPProtocol       = windows.GUID{Data1: 0x3971ef2b, Data2: 0x623e, Data3: 0x4f9a, Data4: [8]byte{0x8c, 0xb1, 0x6e, 0x79, 0xb8, 0x06, 0xb9, 0xa7}}
	conditionALEAppID         = windows.GUID{Data1: 0xd78e1e87, Data2: 0x8644, Data3: 0x4ea5, Data4: [8]byte{0x94, 0x37, 0xd8, 0x09, 0xec, 0xef, 0xc9, 0x71}}
	conditionFlags            = windows.GUID{Data1: 0x632ce23b, Data2: 0x5167, Data3: 0x435c, Data4: [8]byte{0x86, 0xd7, 0xe9, 0x03, 0x68, 0x4a, 0xa8, 0x0c}}
	// ICMP type and code ride in the port fields.
	conditionICMPType = conditionIPLocalPort
)

// MARK: Calls

func wfpCall(p *windows.LazyProc, args ...uintptr) error {
	if err := p.Find(); err != nil {
		return err
	}
	r, _, _ := p.Call(args...)
	if r != 0 {
		return windows.Errno(r)
	}
	return nil
}

func isWFPError(err error, code uint32) bool {
	var errno windows.Errno
	return errors.As(err, &errno) && uint32(errno) == code
}

// wfpArena keeps alive the Go memory a filter points into until the call
// that reads it has returned. The pointers sit in uintptr fields, which the
// garbage collector does not follow.
type wfpArena struct{ keep []any }

func (a *wfpArena) str(s string) *uint16 {
	p, _ := windows.UTF16PtrFromString(s)
	a.keep = append(a.keep, p)
	return p
}

func (a *wfpArena) ptr(v any, p unsafe.Pointer) uintptr {
	a.keep = append(a.keep, v)
	return uintptr(p)
}

func (a *wfpArena) uint64(v uint64) fwpValue0 {
	p := new(uint64)
	*p = v
	return fwpValue0{typ: fwpUint64, value: a.ptr(p, unsafe.Pointer(p))}
}

func (a *wfpArena) v4Net(addr, mask uint32) fwpValue0 {
	p := &fwpV4AddrAndMask{addr: addr, mask: mask}
	return fwpValue0{typ: fwpV4AddrMaskType, value: a.ptr(p, unsafe.Pointer(p))}
}

func (a *wfpArena) v6Net(addr [16]byte, prefix uint8) fwpValue0 {
	p := &fwpV6AddrAndMask{addr: addr, prefixLength: prefix}
	return fwpValue0{typ: fwpV6AddrMaskType, value: a.ptr(p, unsafe.Pointer(p))}
}

// wfpEngine is one session with the filtering engine, kept open for the
// daemon's lifetime. It is not dynamic: what it adds outlives the process,
// so a crashed daemon leaves the block standing (fail closed) until the
// service restarts it.
type wfpEngine struct {
	mu     sync.Mutex
	handle windows.Handle
}

var engine wfpEngine

// open returns the session, opening it on first use or after a failure
// (the Base Filtering Engine can restart under us).
func (e *wfpEngine) open() (windows.Handle, error) {
	if e.handle != 0 {
		return e.handle, nil
	}
	var a wfpArena
	session := fwpmSession0{
		displayData: fwpmDisplayData0{name: a.str("VPN Kill Switch"), description: a.str("vpnks daemon")},
		// Never wait forever for another program's transaction.
		txnWaitTimeoutInMSec: 10000,
	}
	var h windows.Handle
	err := wfpCall(procFwpmEngineOpen0, 0, rpcCAuthnWinNT, 0,
		uintptr(unsafe.Pointer(&session)), uintptr(unsafe.Pointer(&h)))
	runtime.KeepAlive(&a)
	if err != nil {
		return 0, fmt.Errorf("FwpmEngineOpen0: %w", err)
	}
	e.handle = h
	return h, nil
}

func (e *wfpEngine) reset() {
	if e.handle != 0 {
		_ = wfpCall(procFwpmEngineClose0, uintptr(e.handle))
		e.handle = 0
	}
}

// transact runs fn inside one WFP transaction, so the filtering engine
// switches from the old rules to the new ones in a single step: no packet
// ever sees a half-loaded set.
func (e *wfpEngine) transact(fn func(h windows.Handle) error) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	h, err := e.open()
	if err != nil {
		return err
	}
	if err := wfpCall(procFwpmTransactionBegin0, uintptr(h), 0); err != nil {
		// A dead session is the usual cause; the next call reopens.
		e.reset()
		return fmt.Errorf("FwpmTransactionBegin0: %w", err)
	}
	if err := fn(h); err != nil {
		_ = wfpCall(procFwpmTransactionAbort0, uintptr(h))
		return err
	}
	if err := wfpCall(procFwpmTransactionCommit0, uintptr(h)); err != nil {
		e.reset()
		return fmt.Errorf("FwpmTransactionCommit0: %w", err)
	}
	return nil
}

func addProvider(h windows.Handle, key windows.GUID, name string) error {
	var a wfpArena
	p := fwpmProvider0{
		providerKey: key,
		displayData: fwpmDisplayData0{name: a.str(name), description: a.str("Blocks traffic outside the VPN tunnel when the tunnel stops working")},
		flags:       fwpmProviderFlagPersistent,
	}
	err := wfpCall(procFwpmProviderAdd0, uintptr(h), uintptr(unsafe.Pointer(&p)), 0)
	runtime.KeepAlive(&a)
	if err != nil && !isWFPError(err, fwpEAlreadyExists) {
		return fmt.Errorf("FwpmProviderAdd0: %w", err)
	}
	return nil
}

func addSublayer(h windows.Handle, key, provider windows.GUID, name string, weight uint16) error {
	var a wfpArena
	s := fwpmSublayer0{
		subLayerKey: key,
		displayData: fwpmDisplayData0{name: a.str(name), description: a.str("VPN kill switch rules")},
		flags:       fwpmSublayerFlagPersistent,
		providerKey: &provider,
		weight:      weight,
	}
	err := wfpCall(procFwpmSubLayerAdd0, uintptr(h), uintptr(unsafe.Pointer(&s)), 0)
	runtime.KeepAlive(&a)
	if err != nil && !isWFPError(err, fwpEAlreadyExists) {
		return fmt.Errorf("FwpmSubLayerAdd0: %w", err)
	}
	return nil
}

// wfpFilter is one filter to add.
type wfpFilter struct {
	key        windows.GUID // zero: the engine assigns one
	name       string
	layer      windows.GUID
	weight     uint8 // within our sublayer: 15 is evaluated first
	action     uint32
	conditions []fwpmFilterCondition0
}

func addFilter(h windows.Handle, a *wfpArena, provider, sublayer windows.GUID, persistent bool, f wfpFilter) error {
	filter := fwpmFilter0{
		filterKey:   f.key,
		displayData: fwpmDisplayData0{name: a.str(f.name)},
		providerKey: &provider,
		layerKey:    f.layer,
		subLayerKey: sublayer,
		weight:      fwpValue0{typ: fwpUint8, value: uintptr(f.weight)},
		action:      fwpmAction0{typ: f.action},
	}
	if persistent {
		filter.flags = fwpmFilterFlagPersistent
	}
	if len(f.conditions) > 0 {
		filter.numFilterConditions = uint32(len(f.conditions))
		filter.filterCondition = &f.conditions[0]
	}
	var id uint64
	err := wfpCall(procFwpmFilterAdd0, uintptr(h), uintptr(unsafe.Pointer(&filter)), 0, uintptr(unsafe.Pointer(&id)))
	runtime.KeepAlive(f.conditions)
	runtime.KeepAlive(a)
	if err != nil {
		return fmt.Errorf("FwpmFilterAdd0 (%s): %w", f.name, err)
	}
	return nil
}

// filtersOf lists the keys of every filter the provider owns. The
// enumeration takes no template — all filters on the machine, a few
// thousand at most — so it depends on nothing but the provider key in
// each result.
func filtersOf(h windows.Handle, provider windows.GUID) ([]windows.GUID, error) {
	var enum windows.Handle
	if err := wfpCall(procFwpmFilterCreateEnumHandle0, uintptr(h), 0, uintptr(unsafe.Pointer(&enum))); err != nil {
		return nil, fmt.Errorf("FwpmFilterCreateEnumHandle0: %w", err)
	}
	defer wfpCall(procFwpmFilterDestroyEnumHandle0, uintptr(h), uintptr(enum))

	var keys []windows.GUID
	for {
		var entries **fwpmFilter0
		var n uint32
		if err := wfpCall(procFwpmFilterEnum0, uintptr(h), uintptr(enum), 256,
			uintptr(unsafe.Pointer(&entries)), uintptr(unsafe.Pointer(&n))); err != nil {
			return nil, fmt.Errorf("FwpmFilterEnum0: %w", err)
		}
		if n == 0 {
			return keys, nil
		}
		for _, f := range unsafe.Slice(entries, n) {
			if f.providerKey != nil && *f.providerKey == provider {
				keys = append(keys, f.filterKey)
			}
		}
		_ = wfpCall(procFwpmFreeMemory0, uintptr(unsafe.Pointer(&entries)))
	}
}

func deleteFilter(h windows.Handle, key windows.GUID) error {
	err := wfpCall(procFwpmFilterDeleteByKey0, uintptr(h), uintptr(unsafe.Pointer(&key)))
	if err != nil && !isWFPError(err, fwpEFilterNotFound) {
		return fmt.Errorf("FwpmFilterDeleteByKey0: %w", err)
	}
	return nil
}

func filterExists(h windows.Handle, key windows.GUID) (bool, error) {
	var f *fwpmFilter0
	err := wfpCall(procFwpmFilterGetByKey0, uintptr(h), uintptr(unsafe.Pointer(&key)), uintptr(unsafe.Pointer(&f)))
	if err == nil {
		_ = wfpCall(procFwpmFreeMemory0, uintptr(unsafe.Pointer(&f)))
		return true, nil
	}
	if isWFPError(err, fwpEFilterNotFound) {
		return false, nil
	}
	return false, err
}

// appID is the filtering engine's identity for a program: its path in NT
// device form. Freed with freeAppID once the filters naming it are added.
func appID(path string) (*fwpByteBlob, error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	var blob *fwpByteBlob
	if err := wfpCall(procFwpmGetAppIdFromFileName0, uintptr(unsafe.Pointer(p)), uintptr(unsafe.Pointer(&blob))); err != nil {
		return nil, fmt.Errorf("FwpmGetAppIdFromFileName0: %w", err)
	}
	return blob, nil
}

func freeAppID(blob *fwpByteBlob) {
	if blob != nil {
		_ = wfpCall(procFwpmFreeMemory0, uintptr(unsafe.Pointer(&blob)))
	}
}
