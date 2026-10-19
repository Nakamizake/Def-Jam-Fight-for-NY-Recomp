; Def Jam: Fight for NY (PC port) - Inno Setup script.
;
; Built by scripts/package.ps1, which stages the files and passes AppVersion, StageDir and
; OutputDir. The package holds the runtime, the recompiler and a compiler toolchain only;
; the game itself is built on the player's machine from their own disc image
; (setup\build-game.ps1), right after the files are installed.
;
; Per-user install: no administrator rights, nothing outside the chosen folder except the
; Start menu entries, the optional desktop shortcut and the uninstall entry (HKCU).

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #define StageDir "..\build\package\stage"
#endif
#ifndef OutputDir
  #define OutputDir "..\build\package"
#endif
#define AppName "Def Jam: Fight for NY (PC port)"
#define ShortName "Def Jam Fight for NY"

[Setup]
AppId={{EE1476CB-E33D-4B0B-B14F-8CE9E9E79008}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=DefJamFFNY-Port contributors
DefaultDirName={autopf}\DefJamFFNY
DefaultGroupName={#ShortName}
DisableProgramGroupPage=yes
DisableDirPage=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=DefJamFFNY-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
InfoBeforeFile=before-you-install.txt
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\DefJam.exe
; The game is built into the install folder, so it needs room beyond the files themselves.
ExtraDiskSpaceRequired=4000000000
#ifdef TestInstall
; Developer test builds (package.ps1 -TestInstall): no uninstall entry in the registry and no
; shortcuts, so a test install writes nothing outside its folder.
CreateUninstallRegKey=no
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
; Test installs (see TestInstall above) create no shortcuts.
#ifndef TestInstall
Name: "{group}\{#ShortName}"; Filename: "{app}\DefJam.exe"
Name: "{group}\Rebuild game files"; Filename: "{app}\DefJam.exe"; Parameters: "--rebuild"
Name: "{group}\Optimize for this PC"; Filename: "{app}\DefJam.exe"; Parameters: "--optimize"
Name: "{group}\Game folder"; Filename: "{app}"
Name: "{group}\Uninstall {#ShortName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#ShortName}"; Filename: "{app}\DefJam.exe"; Tasks: desktopicon
#endif

[Run]
; Optional and off by default. It runs first and is waited for, so with both ticked the game
; starts once the optimization is done instead of alongside it.
Filename: "{app}\DefJam.exe"; Parameters: "--optimize"; Description: "Optimize the game for this PC now (optional, about 20 minutes; also in the Start menu)"; Flags: postinstall unchecked skipifsilent; Check: GameIsBuilt
Filename: "{app}\DefJam.exe"; Description: "Play now"; Flags: postinstall nowait skipifsilent; Check: GameIsBuilt

[UninstallDelete]
; Built on this machine by build-game.ps1, so not in the uninstall log.
Type: filesandordirs; Name: "{app}\game"
Type: filesandordirs; Name: "{app}\module"
Type: filesandordirs; Name: "{app}\work"
Type: filesandordirs; Name: "{app}\logs"

[Code]
const
  GameId = 'GNWE69';

var
  DiscPage: TInputFileWizardPage;

// Reads the disc header: a plain GameCube image has the magic C2 33 9F 3D at 0x1C and the
// disc id in its first six bytes. Returns '' when the file cannot be read.
function ReadDiscHeader(const Path: String; var DiscId: String): Boolean;
var
  Stream: TFileStream;
  Header: AnsiString;
begin
  Result := False;
  DiscId := '';
  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Header, 32);
      if Stream.Read(Header, 32) = 32 then
      begin
        DiscId := Copy(Header, 1, 6);
        Result := (Ord(Header[29]) = $C2) and (Ord(Header[30]) = $33) and
                  (Ord(Header[31]) = $9F) and (Ord(Header[32]) = $3D);
      end;
    finally
      Stream.Free;
    end;
  except
    Result := False;
  end;
end;

function IsGameDisc(const Path: String): Boolean;
var
  DiscId: String;
begin
  Result := ReadDiscHeader(Path, DiscId) and (DiscId = GameId);
end;

// First matching .iso directly in Dir, or '' .
function FindDiscIn(const Dir: String): String;
var
  Found: TFindRec;
begin
  Result := '';
  if FindFirst(AddBackslash(Dir) + '*.iso', Found) then
  try
    repeat
      if IsGameDisc(AddBackslash(Dir) + Found.Name) then
      begin
        Result := AddBackslash(Dir) + Found.Name;
        Exit;
      end;
    until not FindNext(Found);
  finally
    FindClose(Found);
  end;
end;

// The disc image next to the installer, or in a folder next to it.
function FindDiscNearSetup(): String;
var
  Source: String;
  Found: TFindRec;
begin
  Source := ExpandConstant('{src}');
  Result := FindDiscIn(Source);
  if Result <> '' then Exit;
  if FindFirst(AddBackslash(Source) + '*', Found) then
  try
    repeat
      if ((Found.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
         (Found.Name <> '.') and (Found.Name <> '..') then
      begin
        Result := FindDiscIn(AddBackslash(Source) + Found.Name);
        if Result <> '' then Exit;
      end;
    until not FindNext(Found);
  finally
    FindClose(Found);
  end;
end;

// A reinstall over a built game can rebuild without the disc.
function HaveExtractedGame(): Boolean;
begin
  Result := FileExists(AddBackslash(WizardDirValue) + 'game\sys\main.dol');
end;

function GameIsBuilt(): Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\module\g' + GameId + '_recomp.dll')) and
            FileExists(ExpandConstant('{app}\game\sys\main.dol'));
end;

procedure InitializeWizard();
begin
  DiscPage := CreateInputFilePage(wpSelectDir,
    'Game disc', 'Where is your Def Jam: Fight for NY disc image?',
    'The game is built on this PC from your own copy of the disc. Choose a plain .iso of ' +
    'the GameCube USA release (disc id ' + GameId + '). Building takes several minutes ' +
    'after the files are installed.');
  DiscPage.Add('Disc image (.iso):', 'GameCube disc image (*.iso)|*.iso|All files|*.*', '.iso');
  // /ISO="path" on the command line (unattended installs), else a disc next to the installer.
  DiscPage.Values[0] := ExpandConstant('{param:ISO|}');
  if DiscPage.Values[0] = '' then
    DiscPage.Values[0] := FindDiscNearSetup();
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = DiscPage.ID) and (DiscPage.Values[0] = '') and HaveExtractedGame() then
    DiscPage.SubCaptionLabel.Caption :=
      'A game built by an earlier install was found in this folder. Leave the field empty ' +
      'to rebuild from it, or choose a disc image to extract it again.';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Path, DiscId: String;
begin
  Result := True;
  if CurPageID <> DiscPage.ID then Exit;

  Path := Trim(DiscPage.Values[0]);
  if (Path = '') and HaveExtractedGame() then Exit;
  Result := False;
  if Path = '' then
    MsgBox('Choose your disc image to continue.', mbError, MB_OK)
  else if not FileExists(Path) then
    MsgBox('File not found:' + #13#10 + Path, mbError, MB_OK)
  else if LowerCase(ExtractFileExt(Path)) <> '.iso' then
    MsgBox('Only plain .iso images can be used.' + #13#10#13#10 +
      'To convert an .rvz, .gcz or .nkit image, in Dolphin: right-click the game > ' +
      'Convert File..., format ISO.', mbError, MB_OK)
  else if not ReadDiscHeader(Path, DiscId) then
    MsgBox('That .iso is not a plain GameCube disc image. It may be compressed (NKit, or ' +
      'an RVZ/GCZ renamed to .iso), or the release for another console.' + #13#10#13#10 +
      'In Dolphin: right-click the game > Convert File..., format ISO, no compression.',
      mbError, MB_OK)
  else if DiscId <> GameId then
    MsgBox('That is a GameCube disc, but not Def Jam: Fight for NY (USA).' + #13#10 +
      'Disc id read: ' + DiscId + ', expected: ' + GameId + '.', mbError, MB_OK)
  else
    Result := True;
end;

// Builds the game once the files are in place, in a console window the player can follow.
procedure CurStepChanged(CurStep: TSetupStep);
var
  Parameters: String;
  ResultCode: Integer;
begin
  if CurStep <> ssPostInstall then Exit;

  Parameters := '-NoProfile -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\setup\build-game.ps1') + '"';
  if Trim(DiscPage.Values[0]) <> '' then
    Parameters := Parameters + ' -Iso "' + Trim(DiscPage.Values[0]) + '"';
  if WizardSilent() then
    Parameters := Parameters + ' -NoPause';

  WizardForm.StatusLabel.Caption := 'Building the game from your disc. This takes several minutes...';
  WizardForm.FilenameLabel.Caption := 'Progress is shown in the console window.';
  if not Exec('powershell.exe', Parameters, ExpandConstant('{app}'), SW_SHOW,
              ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    MsgBox('The game could not be built. The files are installed, so you can try again ' +
      'from the Start menu (' + '{#ShortName}' + ' > Rebuild game files) or by starting the ' +
      'game.' + #13#10#13#10 + 'Details: ' + ExpandConstant('{app}\logs\build-game.log'),
      mbError, MB_OK);
end;

// Saves and settings live in userdata\. Keep them unless the player says otherwise, so a
// reinstall or an upgrade does not lose them.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  UserData: String;
begin
  if CurUninstallStep <> usUninstall then Exit;
  UserData := ExpandConstant('{app}\userdata');
  if DirExists(UserData) and not UninstallSilent() then
    if MsgBox('Also delete your saves and settings?' + #13#10#13#10 + UserData,
              mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      DelTree(UserData, True, True, True);
end;
