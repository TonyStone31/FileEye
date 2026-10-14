unit FileEye;

{$mode objfpc}{$H+}
// Copyright (c) 2026 Tony Stone. 0BSD; see LICENSE.

{ TFileEye: point it at a file or a folder and it tells you when a file
  there is created, changed or deleted.  The watching itself is Free
  Pascal's DirWatch; this puts it on the palette, looks at it a few times a
  second from the main thread, and hands over one event per file. }

interface

uses Classes, SysUtils, ExtCtrls, crc, FileEyeDirWatch;

type
  TFileEyeChange = (fcCreated, fcChanged, fcDeleted);

  TFileEyeEvent = procedure(Sender: TObject; const FileName: string; Change: TFileEyeChange) of object;
  TFileEyeErrorEvent = procedure(Sender: TObject; const Message: string) of object;

  TFileEye = class(TComponent)
  private
    WatchPath: string;
    Wanted: boolean;
    Watch: TDirWatch;
    Timer: TTimer;
    Folder, OnlyName: string;
    // what is news since the last look, and the files that were there then
    Seen, Known: TStringList;
    // files this program wrote, with what it left in them
    Ours: TStringList;
    ChangeHandler, OwnHandler: TFileEyeEvent;
    ErrorHandler: TFileEyeErrorEvent;
    ErrorText: string;
    procedure SetPath(const Value: string);
    procedure SetEnabled(Value: boolean);
    procedure Start;
    procedure Stop;
    procedure Look(Sender: TObject);
    procedure Noticed(Sender: TObject; const Event: TFileChangeEvent);
  protected
    procedure Loaded; override;
  public
    destructor Destroy; override;
    // Call right after this program writes or deletes a file it watches:
    // while the file stays as written, its news goes to OnOwnChange.
    procedure Wrote(const FileName: string);
    // Why the last start failed; empty when it did not.
    property LastError: string read ErrorText;
  published
    // A file or a folder. A folder reports the files directly in it, not
    // those in its subfolders. A file need not exist yet: its folder must.
    property Path: string read WatchPath write SetPath;
    // True watches; set it here to start with the form. Nothing is watched
    // in the designer.
    property Enabled: boolean read Wanted write SetEnabled default False;
    // A file was created, changed or deleted. FileName is the full path.
    // Runs on the main thread, once per file however many times the system
    // told us about it.
    property OnChange: TFileEyeEvent read ChangeHandler write ChangeHandler;
    // The same, for a file that still holds what this program said it Wrote.
    property OnOwnChange: TFileEyeEvent read OwnHandler write OwnHandler;
    // Watching could not start - the folder is missing, say. Enabled goes
    // back to False and the message stays in LastError.
    property OnError: TFileEyeErrorEvent read ErrorHandler write ErrorHandler;
  end;

implementation

// What a file holds, as a number; 0 is no file at all.
function Stamp(const FileName: string): PtrUInt;
var
  F: TFileStream;
  Buf: array[0..65535] of byte;
  N: integer;
  Sum: cardinal;
begin
  if not FileExists(FileName) then Exit(0);
  // an empty file is 1
  Sum := 1;
  try
    F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      repeat
        N := F.Read(Buf, SizeOf(Buf));
        if N > 0 then Sum := crc32(Sum, @Buf[0], N);
      until N <= 0;
    finally
      F.Free;
    end;
  except
    // someone else has it locked, so it is not as we left it
    Exit(High(PtrUInt));
  end;
  Result := Sum;
end;

destructor TFileEye.Destroy;
begin
  Stop;
  Timer.Free;
  inherited Destroy;
end;

procedure TFileEye.Loaded;
begin
  inherited Loaded;
  if Wanted then Start;
end;

procedure TFileEye.SetPath(const Value: string);
begin
  if Value = WatchPath then Exit;
  WatchPath := Value;
  if Wanted and not (csLoading in ComponentState) then Start;
end;

procedure TFileEye.SetEnabled(Value: boolean);
begin
  if Value = Wanted then Exit;
  Wanted := Value;
  if (csLoading in ComponentState) or (csDesigning in ComponentState) then Exit;
  if Value then Start
  else
    Stop;
end;

procedure TFileEye.Start;
var
  Target: string;
  Found: TSearchRec;
begin
  Stop;
  ErrorText := '';
  Target := ExcludeTrailingPathDelimiter(ExpandFileName(Path));
  // a file is watched through its folder, which sees it replaced as well as written
  if DirectoryExists(Target) then
  begin
    Folder := Target;
    OnlyName := '';
  end
  else
  begin
    Folder := ExtractFileDir(Target);
    OnlyName := ExtractFileName(Target);
  end;
  // what is there before watching starts, so a file replaced later reads as changed
  Seen := TStringList.Create;
  Known := TStringList.Create;
  Known.Sorted := True;
  Known.CaseSensitive := FileNameCaseSensitive;
  Ours := TStringList.Create;
  Ours.CaseSensitive := FileNameCaseSensitive;
  if OnlyName <> '' then
  begin
    if FileExists(Target) then Known.Add(Target);
  end
  else if FindFirst(IncludeTrailingPathDelimiter(Folder) + AllFilesMask, faAnyFile, Found) = 0 then
  begin
    repeat
      if Found.Attr and faDirectory = 0 then Known.Add(IncludeTrailingPathDelimiter(Folder) + Found.Name);
    until FindNext(Found) <> 0;
    FindClose(Found);
  end;
  if Path = '' then ErrorText := 'Set Path to a file or a folder first.'
  else if not DirectoryExists(Folder) then ErrorText := 'There is no folder ' + Folder + ' to watch.'
  else
  try
    Watch := TDirWatch.Create(nil);
    Watch.BaseDir := Folder;
    Watch.CheckTimeout := 0;
    Watch.AddWatch('', [feModify, feCreate, feDelete]);
    Watch.OnChange := @Noticed;
    Watch.InitWatch;
  except
    on E: Exception do ErrorText := E.Message;
  end;
  if ErrorText <> '' then
  begin
    Stop;
    Wanted := False;
    if Assigned(ErrorHandler) then ErrorHandler(Self, ErrorText);
    Exit;
  end;
  // made once and only switched off: OnChange may stop the eye inside the timer's own event
  if Timer = nil then
  begin
    Timer := TTimer.Create(nil);
    Timer.Interval := 200;
    Timer.OnTimer := @Look;
  end;
  Timer.Enabled := True;
end;

procedure TFileEye.Stop;
begin
  if Timer <> nil then Timer.Enabled := False;
  FreeAndNil(Watch);
  FreeAndNil(Seen);
  FreeAndNil(Known);
  FreeAndNil(Ours);
end;

procedure TFileEye.Wrote(const FileName: string);
var
  FullName: string;
  I: integer;
begin
  // nothing to hide while not watching
  if Ours = nil then Exit;
  FullName := ExpandFileName(FileName);
  I := Ours.IndexOf(FullName);
  if I < 0 then I := Ours.Add(FullName);
  Ours.Objects[I] := TObject(Stamp(FullName));
end;

// What happened to each file since the last look, gathered so a burst of
// writes is one event; a change does not hide that the file is new.
procedure TFileEye.Noticed(Sender: TObject; const Event: TFileChangeEvent);
var
  FullName: string;
  Change: TFileEyeChange;
  I: integer;
begin
  if (OnlyName <> '') and (Event.FileName <> OnlyName) then Exit;
  // no name is the watched folder itself
  if Event.FileName = '' then FullName := Folder
  else
    FullName := IncludeTrailingPathDelimiter(Folder) + Event.FileName;
  if feDelete in Event.Events then Change := fcDeleted
  else if feCreate in Event.Events then Change := fcCreated
  else
    Change := fcChanged;
  I := Seen.IndexOf(FullName);
  if I < 0 then Seen.AddObject(FullName, TObject(PtrInt(Change)))
  // an editor's temporary file, there and gone between two looks, is no news
  else if (Change = fcDeleted) and (TFileEyeChange(PtrInt(Seen.Objects[I])) = fcCreated) and (Known.IndexOf(FullName) < 0) then
    Seen.Delete(I)
  else if not ((Change = fcChanged) and (TFileEyeChange(PtrInt(Seen.Objects[I])) = fcCreated)) then
    Seen.Objects[I] := TObject(PtrInt(Change));
end;

procedure TFileEye.Look(Sender: TObject);
var
  Found: TStringList;
  I, K, J: integer;
  Change: TFileEyeChange;
  Mine: boolean;
begin
  if Watch = nil then Exit;
  while Watch.Check > 0 do ;
  if Seen.Count = 0 then Exit;
  // the handler may stop or restart the eye, so the news gets a list of its own
  Found := Seen;
  Seen := TStringList.Create;
  try
    for I := 0 to Found.Count - 1 do
    begin
      // stopped by the handler
      if Known = nil then Break;
      Change := TFileEyeChange(PtrInt(Found.Objects[I]));
      K := Known.IndexOf(Found[I]);
      // a file saved by renaming a new one over it was there all along
      if (Change = fcCreated) and (K >= 0) then Change := fcChanged;
      if (Change = fcDeleted) and (K >= 0) then Known.Delete(K)
      else if (Change <> fcDeleted) and (K < 0) then Known.Add(Found[I]);
      // ours until someone else changes it
      J := Ours.IndexOf(Found[I]);
      Mine := (J >= 0) and (PtrUInt(Ours.Objects[J]) = Stamp(Found[I]));
      if (J >= 0) and not Mine then Ours.Delete(J);
      if Mine then
      begin
        if Assigned(OwnHandler) then OwnHandler(Self, Found[I], Change);
      end
      else if Assigned(ChangeHandler) then ChangeHandler(Self, Found[I], Change);
    end;
  finally
    Found.Free;
  end;
end;

end.
