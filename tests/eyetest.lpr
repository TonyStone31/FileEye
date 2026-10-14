program eyetest;

{$mode objfpc}{$H+}
// Copyright (c) 2026 Tony Stone. 0BSD; see LICENSE.

{ Puts TFileEye through the ways programs really change files, in a fresh
  folder under the system's temp folder, and says what came out.  Exit code
  is the number of failures. }

uses
  {$ifdef unix}cthreads,{$endif}
  {$ifdef windows}Windows,{$endif}
  Interfaces,
  Forms,
  Classes,
  SysUtils,
  FileEye;

type
  TRecorder = class
    Got: TStringList;
    StopAfter: boolean;
    procedure Changed(Sender: TObject; const FileName: string; Change: TFileEyeChange);
    procedure OwnChanged(Sender: TObject; const FileName: string; Change: TFileEyeChange);
  end;

const
  Kinds: array[TFileEyeChange] of string = ('created', 'changed', 'deleted');

var
  Dir: string;
  Rec: TRecorder;
  Eye: TFileEye;
  Failures: integer = 0;

  procedure TRecorder.Changed(Sender: TObject; const FileName: string; Change: TFileEyeChange);
  begin
    Got.Add(ExtractFileName(FileName) + ' ' + Kinds[Change]);
    if StopAfter then (Sender as TFileEye).Enabled := False;
  end;

  procedure TRecorder.OwnChanged(Sender: TObject; const FileName: string; Change: TFileEyeChange);
  begin
    Got.Add(ExtractFileName(FileName) + ' ' + Kinds[Change] + ' by us');
  end;

  procedure Settle;
  var
    Deadline: QWord;
  begin
    Deadline := GetTickCount64 + 800;
    while GetTickCount64 < Deadline do
    begin
      Application.ProcessMessages;
      Sleep(10);
    end;
  end;

  procedure WriteFile(const Name, Text: string; Append: boolean = False);
  var
    F: TFileStream;
  begin
    if Append and FileExists(Dir + Name) then
    begin
      F := TFileStream.Create(Dir + Name, fmOpenReadWrite);
      F.Seek(0, soEnd);
    end
    else
      F := TFileStream.Create(Dir + Name, fmCreate);
    try
      F.WriteBuffer(Text[1], Length(Text));
    finally
      F.Free;
    end;
  end;

  // How gedit, Kate and LibreOffice save: a new file, renamed over the old one.
  procedure SaveByRename(const Name, Text: string);
  begin
    WriteFile('.' + Name + '.tmp', Text);
    {$ifdef windows}
  MoveFileEx(PChar(Dir + '.' + Name + '.tmp'), PChar(Dir + Name), MOVEFILE_REPLACE_EXISTING);
    {$else}
    RenameFile(Dir + '.' + Name + '.tmp', Dir + Name);
    {$endif}
  end;

  // Each expected line must have come; with Only set, nothing else may have.
  procedure Expect(const Step: string; const Wanted: array of string; Only: boolean = False);
  var
    W: string;
    Missing: boolean;
  begin
    Settle;
    Missing := False;
    for W in Wanted do
      if Rec.Got.IndexOf(W) < 0 then Missing := True;
    if Missing or (Only and (Rec.Got.Count <> Length(Wanted))) then
    begin
      Inc(Failures);
      WriteLn('FAIL ', Step, ': got [', Rec.Got.CommaText, ']');
    end
    else
      WriteLn('ok   ', Step, ' [', Rec.Got.CommaText, ']');
    Rec.Got.Clear;
  end;

begin
  Application.Initialize;
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'fileeye-test-' + IntToStr(GetTickCount64) + PathDelim;
  ForceDirectories(Dir);
  Rec := TRecorder.Create;
  Rec.Got := TStringList.Create;
  Eye := TFileEye.Create(nil);
  Eye.OnChange := @Rec.Changed;
  Eye.OnOwnChange := @Rec.OwnChanged;

  WriteLn('A folder: ', Dir);
  Eye.Path := Dir;
  Eye.Enabled := True;
  Settle;
  WriteFile('a.txt', 'one');
  Expect('new file', ['a.txt created']);
  WriteFile('a.txt', ' two', True);
  Expect('written in place', ['a.txt changed'], True);
  SaveByRename('a.txt', 'three, longer');
  Expect('saved by rename', ['a.txt changed'], True);
  RenameFile(Dir + 'a.txt', Dir + 'c.txt');
  Expect('renamed', ['a.txt deleted', 'c.txt created'], True);
  DeleteFile(Dir + 'c.txt');
  Expect('deleted', ['c.txt deleted'], True);

  WriteLn('One file: ', Dir, 'note.md');
  WriteFile('note.md', 'first');
  Eye.Path := Dir + 'note.md';
  Settle;
  Rec.Got.Clear;
  WriteFile('note.md', ' more', True);
  Expect('written in place', ['note.md changed'], True);
  SaveByRename('note.md', 'saved by an editor');
  Expect('saved by rename', ['note.md changed'], True);
  WriteFile('other.txt', 'not watched');
  Expect('another file', [], True);
  DeleteFile(Dir + 'note.md');
  Expect('deleted', ['note.md deleted'], True);
  WriteFile('note.md', 'back');
  Expect('created again', ['note.md created'], True);
  Rec.StopAfter := True;
  WriteFile('note.md', ' and', True);
  Expect('stopped from OnChange', ['note.md changed'], True);
  Rec.StopAfter := False;
  WriteFile('note.md', ' forth', True);
  Expect('nothing once stopped', [], True);
  Eye.Enabled := True;
  Settle;
  WriteFile('note.md', ' again', True);
  Expect('started again', ['note.md changed'], True);
  // how an editor tells its own saves from everyone else's
  WriteFile('note.md', 'saved by us');
  Eye.MarkOwnWrite(Dir + 'note.md');
  Expect('our own save', ['note.md changed by us'], True);
  SaveByRename('note.md', 'saved by us, the careful way');
  Eye.MarkOwnWrite(Dir + 'note.md');
  Expect('our own save by rename', ['note.md changed by us'], True);
  WriteFile('note.md', ' then someone else', True);
  Expect('someone else after us', ['note.md changed'], True);
  WriteFile('note.md', ' and again', True);
  Expect('and again', ['note.md changed'], True);
  WriteFile('note.md', 'ours');
  Eye.MarkOwnWrite(Dir + 'note.md');
  WriteFile('note.md', ' and theirs before the eye looked', True);
  Expect('someone else straight after us', ['note.md changed'], True);
  DeleteFile(Dir + 'note.md');
  Eye.MarkOwnWrite(Dir + 'note.md');
  Expect('deleted by us', ['note.md deleted by us'], True);
  WriteFile('note.md', 'theirs');
  Expect('then made by someone else', ['note.md created'], True);

  Eye.Free;
  DeleteFile(Dir + 'note.md');
  DeleteFile(Dir + 'other.txt');
  RemoveDir(Dir);
  WriteLn(Failures, ' failed');
  ExitCode := Failures;
end.
