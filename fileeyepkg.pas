{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit FileEyePkg;

{$warn 5023 off : no warning about unused units}
interface

uses
  FileEye, FileEyeReg, FileEyeDirWatch, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('FileEyeReg', @FileEyeReg.Register);
end;

initialization
  RegisterPackage('FileEyePkg', @Register);
end.
