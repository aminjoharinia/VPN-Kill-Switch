package daemon

import (
	"time"

	"golang.org/x/sys/windows/svc"

	"vpnks/internal/core"
)

// Power broadcast event types (PBT_*) delivered with SERVICE_CONTROL_POWEREVENT.
const (
	pbtAPMSuspend         = 0x4
	pbtAPMResumeAutomatic = 0x12 // sent on every resume, with or without a user
)

type service struct{}

// IsService reports whether the service control manager started us.
func IsService() bool {
	ok, err := svc.IsWindowsService()
	return err == nil && ok
}

// RunService runs the daemon under the service control manager until it
// asks us to stop.
func RunService() error { return svc.Run(core.ServiceName, service{}) }

func (service) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	stop := make(chan string, 1)
	done := make(chan struct{})
	go func() {
		New(core.LoadConfig()).Run(stop)
		close(done)
	}()
	accepts := svc.AcceptStop | svc.AcceptShutdown | svc.AcceptPowerEvent
	status <- svc.Status{State: svc.Running, Accepts: accepts}

	for {
		select {
		case r := <-requests:
			switch r.Cmd {
			case svc.Interrogate:
				status <- r.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				reason := "service stop"
				if r.Cmd == svc.Shutdown {
					reason = "system shutdown"
				}
				stop <- reason
				select {
				case <-done:
				case <-time.After(10 * time.Second):
				}
				return false, 0
			case svc.PowerEvent:
				switch r.EventType {
				case pbtAPMSuspend:
					notifyPower(true)
				case pbtAPMResumeAutomatic:
					notifyPower(false)
				}
			}
		case <-done:
			// Run never returns on its own: treat it as a crash, so the
			// recovery actions restart us.
			return true, 1
		}
	}
}

// notifyPower never blocks the service control handler.
func notifyPower(sleeping bool) {
	select {
	case servicePower <- sleeping:
	default:
	}
}
