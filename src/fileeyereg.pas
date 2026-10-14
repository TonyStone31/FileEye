unit FileEyeReg;

{$mode objfpc}{$H+}
// Copyright (c) 2026 Tony Stone. 0BSD; see LICENSE.

interface

procedure Register;

implementation

uses Classes, LResources, FileEye;

procedure Register;
begin
  RegisterComponents('System', [TFileEye]);
end;

initialization
  {$I fileeyepalette.lrs}
end.
