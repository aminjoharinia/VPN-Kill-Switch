; The VPN Kill Switch installer. windows/build.ps1 runs makensis with:
;   ARCH     amd64 | arm64
;   VERSION  26.11.01
;   BUILD    142233
;   BINDIR   folder holding vpn-kill-switch.exe and vpnks.exe
;   ICON     the app icon (.ico)
;   OUTFILE  the installer to write
;
; Installing replaces the app only. The daemon runs from its own copy in
; Daemon\ and keeps protecting you; if the app then says "Daemon is out of
; date", press Update in it. Uninstalling stops the daemon and removes
; every firewall rule first, so it never leaves traffic cut.

Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"

!define APP "VPN Kill Switch"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\VPNKillSwitch"

Name "${APP}"
OutFile "${OUTFILE}"
; Fixed: the daemon and the app find each other under Program Files.
InstallDir "$PROGRAMFILES64\${APP}"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
BrandingText "${APP} ${VERSION}"

VIProductVersion "0.0.0.0"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "ProductVersion" "${VERSION}+${BUILD}"
VIAddVersionKey "FileDescription" "${APP} installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" ""

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\vpn-kill-switch.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open ${APP}"

!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
    SetRegView 64
    ; All users: the Start menu shortcut, and $APPDATA as ProgramData.
    SetShellVarContext all
    !if "${ARCH}" == "arm64"
        ${IfNot} ${IsNativeARM64}
            MessageBox MB_ICONSTOP "This installer is for Windows on ARM. Use the amd64 installer on this PC."
            Abort
        ${EndIf}
    !else
        ${If} ${IsNativeARM64}
            MessageBox MB_ICONSTOP "This PC runs Windows on ARM. Use the arm64 installer."
            Abort
        ${EndIf}
        ${IfNot} ${RunningX64}
            MessageBox MB_ICONSTOP "${APP} needs 64-bit Windows."
            Abort
        ${EndIf}
    !endif
FunctionEnd

Function un.onInit
    SetRegView 64
    SetShellVarContext all
FunctionEnd

Section "Install"
    ; Quit a running app so its file can be replaced; the kill switch
    ; itself keeps running.
    nsExec::Exec 'taskkill /IM vpn-kill-switch.exe /F'
    Sleep 300

    SetOutPath "$INSTDIR"
    File "${BINDIR}\vpn-kill-switch.exe"
    File "${BINDIR}\vpnks.exe"
    File "/oname=vpn-kill-switch.ico" "${ICON}"
    WriteUninstaller "$INSTDIR\uninstall.exe"

    CreateShortcut "$SMPROGRAMS\${APP}.lnk" "$INSTDIR\vpn-kill-switch.exe" "" "$INSTDIR\vpn-kill-switch.ico"

    WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayName" "${APP}"
    WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}+${BUILD}"
    WriteRegStr HKLM "${UNINSTALL_KEY}" "Publisher" "${APP}"
    WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\vpn-kill-switch.ico"
    WriteRegStr HKLM "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKLM "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
    WriteRegStr HKLM "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
    WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoModify" 1
    WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
    nsExec::Exec 'taskkill /IM vpn-kill-switch.exe /F'
    ; Stop the daemon, remove the service and every firewall rule. Never
    ; leave the machine firewalled with nothing left to unfirewall it.
    nsExec::ExecToLog '"$INSTDIR\vpnks.exe" uninstall'

    Delete "$SMPROGRAMS\${APP}.lnk"
    Delete "$INSTDIR\vpn-kill-switch.exe"
    Delete "$INSTDIR\vpnks.exe"
    Delete "$INSTDIR\vpn-kill-switch.ico"
    Delete "$INSTDIR\uninstall.exe"
    RMDir /r "$INSTDIR\Daemon"
    RMDir "$INSTDIR"
    DeleteRegKey HKLM "${UNINSTALL_KEY}"

    ; Settings, history and the activity log stay unless asked.
    IfSilent done
    MessageBox MB_YESNO|MB_DEFBUTTON2 "Also delete the kill switch's settings, history and activity log?" IDNO done
    RMDir /r "$APPDATA\${APP}"
    done:
SectionEnd
