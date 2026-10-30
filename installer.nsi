; KumaFlow Installer Script for NSIS

;--------------------------------
; Version (passed via /DKUMAFLOW_VERSION=x.x.x from CI, or fallback)

!ifndef KUMAFLOW_VERSION
  !define KUMAFLOW_VERSION "3.0.1"
!endif

;--------------------------------
; Includes

!include "MUI2.nsh"
!include "FileFunc.nsh"

;--------------------------------
; General

; Name and file
Name "KumaFlow"
OutFile "kumaflow-setup.exe"

; Default installation folder
InstallDir "$PROGRAMFILES64\KumaFlow"

; Get installation folder from registry if available
InstallDirRegKey HKCU "Software\KumaFlow" ""

; Request application privileges for Windows Vista+
RequestExecutionLevel admin

;--------------------------------
; Variables

Var StartMenuFolder

;--------------------------------
; Interface Settings

!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_UNICON "${NSISDIR}\Contrib\Graphics\Icons\modern-uninstall.ico"

;--------------------------------
; Pages

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "LICENSE"
!insertmacro MUI_PAGE_DIRECTORY

; Start Menu Folder Page Configuration
!define MUI_STARTMENUPAGE_REGISTRY_ROOT "HKCU" 
!define MUI_STARTMENUPAGE_REGISTRY_KEY "Software\KumaFlow" 
!define MUI_STARTMENUPAGE_REGISTRY_VALUENAME "Start Menu Folder"

!insertmacro MUI_PAGE_STARTMENU Application $StartMenuFolder

!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_WELCOME
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

;--------------------------------
; Languages

!insertmacro MUI_LANGUAGE "English"

;--------------------------------
; Installer Sections

Section "KumaFlow" SecMain

  SetOutPath "$INSTDIR"
  
  ; Copy all files from Release folder
  File /r "build\windows\x64\runner\Release\*.*"
  
  ; Store installation folder
  WriteRegStr HKCU "Software\KumaFlow" "" $INSTDIR
  
  ; Create uninstaller
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  
  ; Create Start Menu shortcuts
  !insertmacro MUI_STARTMENU_WRITE_BEGIN Application
    
    CreateDirectory "$SMPROGRAMS\$StartMenuFolder"
    CreateShortcut "$SMPROGRAMS\$StartMenuFolder\KumaFlow.lnk" "$INSTDIR\kumaflow.exe"
    CreateShortcut "$SMPROGRAMS\$StartMenuFolder\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
  
  !insertmacro MUI_STARTMENU_WRITE_END
  
  ; Create Desktop shortcut
  CreateShortcut "$DESKTOP\KumaFlow.lnk" "$INSTDIR\kumaflow.exe"
  
  ; Write registry keys for Add/Remove Programs
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KumaFlow" \
                   "DisplayName" "KumaFlow - Navidrome Music Player"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KumaFlow" \
                   "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KumaFlow" \
                   "DisplayIcon" "$INSTDIR\kumaflow.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KumaFlow" \
                   "Publisher" "kumaflow"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KumaFlow" \
                   "DisplayVersion" "3.0.1"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KumaFlow" \
                   "URLInfoAbout" "https://github.com/kumaflow/KumaFlow"
  
  ; Calculate and write size
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KumaFlow" \
                     "EstimatedSize" "$0"

SectionEnd

;--------------------------------
; Uninstaller Section

Section "Uninstall"

  ; Remove files
  RMDir /r "$INSTDIR"
  
  ; Remove Start Menu shortcuts
  !insertmacro MUI_STARTMENU_GETFOLDER Application $StartMenuFolder
  
  Delete "$SMPROGRAMS\$StartMenuFolder\KumaFlow.lnk"
  Delete "$SMPROGRAMS\$StartMenuFolder\Uninstall.lnk"
  RMDir "$SMPROGRAMS\$StartMenuFolder"
  
  ; Remove Desktop shortcut
  Delete "$DESKTOP\KumaFlow.lnk"
  
  ; Remove registry keys
  DeleteRegKey HKCU "Software\KumaFlow"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\KumaFlow"

SectionEnd
