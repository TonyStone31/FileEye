unit DemoMain;

{$mode objfpc}{$H+}
// Copyright (c) 2026 Tony Stone. 0BSD; see LICENSE.

interface

uses Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs, FileEye;

type
  TDemoForm = class(TForm)
    PathEdit: TEdit;
    FolderButton: TButton;
    FileButton: TButton;
    WatchBox: TCheckBox;
    ClearButton: TButton;
    Log: TListBox;
    Eye: TFileEye;
    FolderDialog: TSelectDirectoryDialog;
    FileDialog: TOpenDialog;
    procedure FolderButtonClick(Sender: TObject);
    procedure FileButtonClick(Sender: TObject);
    procedure WatchBoxChange(Sender: TObject);
    procedure ClearButtonClick(Sender: TObject);
    procedure EyeChange(Sender: TObject; const FileName: string; Change: TFileEyeChange);
    procedure EyeError(Sender: TObject; const Message: string);
  end;

var
  DemoForm: TDemoForm;

implementation

{$R *.lfm}

const
  Kinds: array[TFileEyeChange] of string = ('created', 'changed', 'deleted');

procedure TDemoForm.FolderButtonClick(Sender: TObject);
begin
  if FolderDialog.Execute then PathEdit.Text := FolderDialog.FileName;
end;

procedure TDemoForm.FileButtonClick(Sender: TObject);
begin
  if FileDialog.Execute then PathEdit.Text := FileDialog.FileName;
end;

procedure TDemoForm.WatchBoxChange(Sender: TObject);
begin
  Eye.Path := PathEdit.Text;
  Eye.Enabled := WatchBox.Checked;
  if Eye.Enabled then Log.Items.Add('Watching ' + Eye.Path);
end;

procedure TDemoForm.ClearButtonClick(Sender: TObject);
begin
  Log.Clear;
end;

procedure TDemoForm.EyeChange(Sender: TObject; const FileName: string; Change: TFileEyeChange);
begin
  Log.Items.Add(TimeToStr(Now) + '  ' + Kinds[Change] + '  ' + ExtractFileName(FileName));
  Log.ItemIndex := Log.Count - 1;
end;

procedure TDemoForm.EyeError(Sender: TObject; const Message: string);
begin
  WatchBox.Checked := False;
  Log.Items.Add(Message);
end;

end.
