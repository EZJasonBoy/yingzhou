; Windows installer for Yingzhou (Inno Setup 6.3 or newer; this file is UTF-8).
;
; tools/package-desktop.sh builds it after the zip. By hand, once that script has filled the Release folder:
;
;   ISCC tools\installer\windows.iss        ->  dist\yingzhou-windows-x64-setup.exe
;
; What the installer does:
; - installs for the current user, without an administrator prompt, into %LOCALAPPDATA%\Programs\Yingzhou
;   (run it with /ALLUSERS to install into Program Files for everyone);
; - Start menu shortcut, optional desktop shortcut, an entry under "Apps & features" with an uninstaller;
; - an upgrade is the new installer run over the old copy: same AppId, same folder;
; - uninstalling keeps subscriptions, history and favourites unless the user asks to delete them.
;
; Silent install: yingzhou-windows-x64-setup.exe /VERYSILENT [/DIR="x:\path"] [/TASKS=""] [/ALLUSERS]

#define AppName "映舟"
#define AppExe "yingzhou.exe"
#ifndef SourceDir
  #define SourceDir SourcePath + "..\..\client\build\windows\x64\runner\Release"
#endif

#if !FileExists(SourceDir + "\" + AppExe) || !DirExists(SourceDir + "\engine\lib") || !DirExists(SourceDir + "\engine\jre")
  #error The Release folder has no client or no engine in it. Run tools/package-desktop.sh, which builds both.
#endif

; The version comes from the client that is being packaged (client/pubspec.yaml, "0.1.0+1" -> 0.1.0).
#define ProductVersion GetStringFileInfo(SourceDir + "\" + AppExe, "ProductVersion")
#if Pos("+", ProductVersion) > 0
  #define AppVersion Copy(ProductVersion, 1, Pos("+", ProductVersion) - 1)
#else
  #define AppVersion ProductVersion
#endif

[Setup]
; Never change AppId: it is how an upgrade and the uninstaller find the installed copy.
AppId={{DDBAD77F-E2CD-4469-A007-578DA63BA090}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Yingzhou contributors
AppCopyright=Copyright (C) 2026 Yingzhou contributors. AGPL-3.0.
VersionInfoVersion={#GetVersionNumbersString(SourceDir + "\" + AppExe)}
VersionInfoDescription={#AppName} Setup

DefaultDirName={autopf}\Yingzhou
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

; The app holds these mutexes while it runs (client/windows/runner/main.cpp). Setup and the uninstaller ask the
; user to close it first: files that are in use cannot be replaced or deleted.
AppMutex=Yingzhou.App.Running,Global\Yingzhou.App.Running

SetupIconFile=..\..\client\windows\runner\resources\app_icon.ico
; The logo in the wizard's corner, one file per display scaling (from tools/brand/render-icons.mjs).
WizardSmallImageFile=wizard-*.bmp
WizardImageAlphaFormat=defined
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
#if Ver >= EncodeVer(7, 0, 0)
WizardStyle=modern dynamic
#else
WizardStyle=modern
#endif
; Asks for a language only when Windows is in neither of the two.
ShowLanguageDialog=auto

Compression=lzma2/max
SolidCompression=yes
OutputDir=..\..\dist
OutputBaseFilename=yingzhou-windows-x64-setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[CustomMessages]
english.RemoveUserData=Also delete your subscriptions, watch history, favourites and settings?%n%nChoose No to keep them for the next time you install {#AppName}.
chinesesimplified.RemoveUserData=是否同时删除订阅、观看历史、收藏和设置？%n%n选“否”会保留它们，以后重新安装还能接着用。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; An upgrade must not leave the old version's files behind: the engine loads every jar in engine\lib, so a
; library that was upgraded or dropped would be loaded next to its replacement.
Type: filesandordirs; Name: "{app}\engine"
Type: filesandordirs; Name: "{app}\data"

[UninstallDelete]
; The client's poster cache (path_provider's application cache folder). A cache, not the user's data: always removed.
Type: filesandordirs; Name: "{localappdata}\Yingzhou"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// The engine is a child process of the app and ends a moment after it. Wait for it, so that its files in
// engine\jre are not left behind as "in use".
function EngineStopped(): Boolean;
var
  Java: String;
begin
  Java := ExpandConstant('{app}\engine\jre\bin\javaw.exe');
  // A running program cannot be opened for writing; this appends nothing.
  Result := not FileExists(Java) or SaveStringToFile(Java, '', True);
end;

procedure WaitForEngine();
var
  I: Integer;
begin
  for I := 1 to 40 do
  begin
    if EngineStopped() then exit;
    Sleep(250);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  WaitForEngine();
  Result := '';
end;

// What the user made stays unless they say otherwise; a silent uninstall never asks and never deletes it.
// Engine data: %USERPROFILE%\.tvbox-next. Client settings: %APPDATA%\Yingzhou.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  EngineData, ClientData: String;
begin
  if CurUninstallStep = usUninstall then
    WaitForEngine();
  if (CurUninstallStep <> usPostUninstall) or UninstallSilent() then exit;
  EngineData := ExpandConstant('{%USERPROFILE}\.tvbox-next');
  ClientData := ExpandConstant('{userappdata}\Yingzhou');
  if not DirExists(EngineData) and not DirExists(ClientData) then exit;
  if MsgBox(CustomMessage('RemoveUserData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
  begin
    DelTree(EngineData, True, True, True);
    DelTree(ClientData, True, True, True);
  end;
end;
