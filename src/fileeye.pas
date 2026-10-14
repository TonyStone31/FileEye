unit FileEye;

{$mode objfpc}{$H+}
// Copyright (c) 2026 Tony Stone. 0BSD; see LICENSE.

{ TFileEye: point it at a file or a folder and it tells you when a file
  there is created, changed or deleted.  The watching itself is Free
  Pascal's DirWatch; this puts it on the palette, checks it a few times a
  second from the main thread, and hands over one event per file. }

interface

uses Classes, SysUtils, ExtCtrls, md5, FileEyeDirWatch;

type
  TFileEyeChange = (fcCreated, fcChanged, fcDeleted);

  TFileEyeEvent = procedure(Sender: TObject; const FileName: string; Change: TFileEyeChange) of object;
  TFileEyeErrorEvent = procedure(Sender: TObject; const Message: string) of object;

  TFileEye = class(TComponent)
  private
    FPath: string;
    FEnabled: boolean;
    FWatch: TDirWatch;
    FTimer: TTimer;
    // the watched folder, and the one file in it when Path is a file
    FFolder, FFileName: string;
    // changes since the last tick, and the files that were there then
    FPending, FKnown: TStringList;
    // files this program wrote, each with the MD5 of what it left in them
    FOwnWrites: TStringList;
    FOnChange, FOnOwnChange: TFileEyeEvent;
    FOnError: TFileEyeErrorEvent;
    FLastError: string;
    procedure SetPath(const Value: string);
    procedure SetEnabled(Value: boolean);
    procedure Start;
    procedure Stop;
    procedure TimerTick(Sender: TObject);
    procedure WatchChange(Sender: TObject; const Event: TFileChangeEvent);
  protected
    procedure Loaded; override;
  public
    destructor Destroy; override;
    // Call right after this program writes or deletes a file it watches:
    // while the file stays as written, its changes go to OnOwnChange.
    procedure MarkOwnWrite(const FileName: string);
    // Why the last start failed; empty when it did not.
    property LastError: string read FLastError;
  published
    // A file or a folder. A folder reports the files directly in it, not
    // those in its subfolders. A file need not exist yet: its folder must.
    property Path: string read FPath write SetPath;
    // True watches; set it here to start with the form. Nothing is watched
    // in the designer.
    property Enabled: boolean read FEnabled write SetEnabled default False;
    // A file was created, changed or deleted. FileName is the full path.
    // Runs on the main thread, once per file however many times the system
    // told us about it.
    property OnChange: TFileEyeEvent read FOnChange write FOnChange;
    // The same, for a file that still holds what MarkOwnWrite saw in it.
    property OnOwnChange: TFileEyeEvent read FOnOwnChange write FOnOwnChange;
    // Watching could not start - the folder is missing, say. Enabled goes
    // back to False and the message stays in LastError.
    property OnError: TFileEyeErrorEvent read FOnError write FOnError;
  end;

implementation

type
  TOwnWrite = class
    Digest: TMD5Digest;
  end;

destructor TFileEye.Destroy;
begin
  Stop;
  FTimer.Free;
  inherited Destroy;
end;

procedure TFileEye.Loaded;
begin
  inherited Loaded;
  if FEnabled then Start;
end;

procedure TFileEye.SetPath(const Value: string);
begin
  if Value = FPath then Exit;
  FPath := Value;
  if FEnabled and not (csLoading in ComponentState) then Start;
end;

procedure TFileEye.SetEnabled(Value: boolean);
begin
  if Value = FEnabled then Exit;
  FEnabled := Value;
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
  FLastError := '';
  Target := ExcludeTrailingPathDelimiter(ExpandFileName(FPath));
  // a file is watched through its folder, which sees it replaced as well as written
  if DirectoryExists(Target) then
  begin
    FFolder := Target;
    FFileName := '';
  end
  else
  begin
    FFolder := ExtractFileDir(Target);
    FFileName := ExtractFileName(Target);
  end;
  // what is there before watching starts, so a file replaced later reads as changed
  FPending := TStringList.Create;
  FKnown := TStringList.Create;
  FKnown.Sorted := True;
  FKnown.CaseSensitive := FileNameCaseSensitive;
  FOwnWrites := TStringList.Create;
  FOwnWrites.CaseSensitive := FileNameCaseSensitive;
  FOwnWrites.OwnsObjects := True;
  if FFileName <> '' then
  begin
    if FileExists(Target) then FKnown.Add(Target);
  end
  else if FindFirst(IncludeTrailingPathDelimiter(FFolder) + AllFilesMask, faAnyFile, Found) = 0 then
  begin
    repeat
      if Found.Attr and faDirectory = 0 then FKnown.Add(IncludeTrailingPathDelimiter(FFolder) + Found.Name);
    until FindNext(Found) <> 0;
    FindClose(Found);
  end;
  if FPath = '' then FLastError := 'Set Path to a file or a folder first.'
  else if not DirectoryExists(FFolder) then FLastError := 'There is no folder ' + FFolder + ' to watch.'
  else
  try
    FWatch := TDirWatch.Create(nil);
    FWatch.BaseDir := FFolder;
    FWatch.CheckTimeout := 0;
    FWatch.AddWatch('', [feModify, feCreate, feDelete]);
    FWatch.OnChange := @WatchChange;
    FWatch.InitWatch;
  except
    on E: Exception do FLastError := E.Message;
  end;
  if FLastError <> '' then
  begin
    Stop;
    FEnabled := False;
    if Assigned(FOnError) then FOnError(Self, FLastError);
    Exit;
  end;
  // made once and only switched off: OnChange may stop the eye inside the timer's own event
  if FTimer = nil then
  begin
    FTimer := TTimer.Create(nil);
    FTimer.Interval := 200;
    FTimer.OnTimer := @TimerTick;
  end;
  FTimer.Enabled := True;
end;

procedure TFileEye.Stop;
begin
  if FTimer <> nil then FTimer.Enabled := False;
  FreeAndNil(FWatch);
  FreeAndNil(FPending);
  FreeAndNil(FKnown);
  FreeAndNil(FOwnWrites);
end;

procedure TFileEye.MarkOwnWrite(const FileName: string);
var
  FullName: string;
  I: integer;
begin
  // nothing to hide while not watching
  if FOwnWrites = nil then Exit;
  FullName := ExpandFileName(FileName);
  I := FOwnWrites.IndexOf(FullName);
  if I < 0 then I := FOwnWrites.AddObject(FullName, TOwnWrite.Create);
  // a file that cannot be read, or is gone, gives all zeros
  TOwnWrite(FOwnWrites.Objects[I]).Digest := MD5File(FullName);
end;

// What happened to each file since the last tick, gathered so a burst of
// writes is one event; a change does not hide that the file is new.
procedure TFileEye.WatchChange(Sender: TObject; const Event: TFileChangeEvent);
var
  FullName: string;
  Change: TFileEyeChange;
  I: integer;
begin
  if (FFileName <> '') and (Event.FileName <> FFileName) then Exit;
  // no name is the watched folder itself
  if Event.FileName = '' then FullName := FFolder
  else
    FullName := IncludeTrailingPathDelimiter(FFolder) + Event.FileName;
  if feDelete in Event.Events then Change := fcDeleted
  else if feCreate in Event.Events then Change := fcCreated
  else
    Change := fcChanged;
  I := FPending.IndexOf(FullName);
  if I < 0 then FPending.AddObject(FullName, TObject(PtrInt(Change)))
  // an editor's temporary file, there and gone between two ticks, is no news
  else if (Change = fcDeleted) and (TFileEyeChange(PtrInt(FPending.Objects[I])) = fcCreated) and (FKnown.IndexOf(FullName) < 0) then
    FPending.Delete(I)
  else if not ((Change = fcChanged) and (TFileEyeChange(PtrInt(FPending.Objects[I])) = fcCreated)) then
    FPending.Objects[I] := TObject(PtrInt(Change));
end;

procedure TFileEye.TimerTick(Sender: TObject);
var
  Changes: TStringList;
  I, K, J: integer;
  Change: TFileEyeChange;
  IsOwn: boolean;
begin
  if FWatch = nil then Exit;
  while FWatch.Check > 0 do ;
  if FPending.Count = 0 then Exit;
  // the handler may stop or restart the eye, so the changes get a list of their own
  Changes := FPending;
  FPending := TStringList.Create;
  try
    for I := 0 to Changes.Count - 1 do
    begin
      // stopped by the handler
      if FKnown = nil then Break;
      Change := TFileEyeChange(PtrInt(Changes.Objects[I]));
      K := FKnown.IndexOf(Changes[I]);
      // a file saved by renaming a new one over it was there all along
      if (Change = fcCreated) and (K >= 0) then Change := fcChanged;
      if (Change = fcDeleted) and (K >= 0) then FKnown.Delete(K)
      else if (Change <> fcDeleted) and (K < 0) then FKnown.Add(Changes[I]);
      // ours until someone else changes it
      J := FOwnWrites.IndexOf(Changes[I]);
      IsOwn := (J >= 0) and MD5Match(TOwnWrite(FOwnWrites.Objects[J]).Digest, MD5File(Changes[I]));
      if (J >= 0) and not IsOwn then FOwnWrites.Delete(J);
      if IsOwn then
      begin
        if Assigned(FOnOwnChange) then FOnOwnChange(Self, Changes[I], Change);
      end
      else if Assigned(FOnChange) then FOnChange(Self, Changes[I], Change);
    end;
  finally
    Changes.Free;
  end;
end;

end.
