unit uFileSystemListOperation;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  uFileSourceListOperation,
  uFileSource
  ;

type

  { TFileSystemListOperation }

  TFileSystemListOperation = class(TFileSourceListOperation)
  private
    procedure FlatView(const APath: String);
  public
    constructor Create(aFileSource: IFileSource; aPath: String); override;
    procedure MainExecute; override;
  end;

implementation

uses
  DCOSUtils, uFile, uFindEx, uOSUtils, uFileSystemFileSource
  {$IFDEF UNIX}
  , BaseUnix
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  , Windows
  {$ENDIF};

function IsDirectoryReadable(const FileSource: IFileSource; const Path: String): Boolean;
var
  RealPath: String;
begin
  RealPath:= FileSource.GetRealPath(Path);
  Result:= DirectoryExists(RealPath);
  {$IFDEF UNIX}
  Result:= Result and (fpAccess(PChar(RealPath), R_OK or X_OK) = 0);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result:= Result and mbFileAccess(RealPath, fmOpenRead);
  {$ENDIF}
end;

function IsNormalEndOfSearch(const ErrorCode: Integer): Boolean;
begin
  {$IFDEF UNIX}
  Result:= ErrorCode = -1;
  {$ELSE}
  Result:= ErrorCode = ERROR_NO_MORE_FILES;
  {$ENDIF}
end;

function IsEmptySearchResult(const ErrorCode: Integer): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result:= (ErrorCode = ERROR_FILE_NOT_FOUND) or IsNormalEndOfSearch(ErrorCode);
  {$ELSE}
  Result:= IsNormalEndOfSearch(ErrorCode);
  {$ENDIF}
end;

procedure TFileSystemListOperation.FlatView(const APath: String);
var
  AFile: TFile;
  sr: TSearchRecEx;
  FindResult: Integer;
begin
  try
    FindResult:= FindFirstEx(APath + '*', 0, sr);
    if FindResult = 0 then
    begin
      repeat
        CheckOperationState;
        if (sr.Name <> '.') and (sr.Name <> '..') then
          if FPS_ISDIR(sr.Attr) then
            FlatView(APath + sr.Name + DirectorySeparator)
          else begin
            AFile := TFileSystemFileSource.CreateFile(APath, @sr);
            FFiles.Add(AFile);
          end;
        FindResult:= FindNextEx(sr);
      until FindResult <> 0;
      if not IsNormalEndOfSearch(FindResult) then
        RaiseAbortOperation;
    end
    else if not IsEmptySearchResult(FindResult) or
            not IsDirectoryReadable(FileSource, APath) then
      RaiseAbortOperation;
  finally
    FindCloseEx(sr);
  end;
end;

constructor TFileSystemListOperation.Create(aFileSource: IFileSource; aPath: String);
begin
  FFiles := TFiles.Create(aPath);
  inherited Create(aFileSource, aPath);
end;

procedure TFileSystemListOperation.MainExecute;
var
  AFile: TFile;
  sr: TSearchRecEx;
  IsRootPath, Found: Boolean;
  FindResult: Integer;
begin
  FFiles.Clear;

  if FFlatView then
  begin
    FlatView(Path);
    Exit;
  end;

  IsRootPath := FileSource.IsPathAtRoot(Path);

  FindResult:= FindFirstEx(FFiles.Path + '*', 0, sr);
  Found:= FindResult = 0;
  try
    if not Found then
    begin
      if not IsEmptySearchResult(FindResult) or
         not IsDirectoryReadable(FileSource, Path) then
        RaiseAbortOperation;

      if not IsRootPath then
      begin
        AFile := TFileSystemFileSource.CreateFile(Path);
        AFile.Name := '..';
        AFile.Attributes := faFolder;
        FFiles.Add(AFile);
      end;
    end
    else
    begin
      repeat
        CheckOperationState;

        if (sr.Name <> '.') and not ((sr.Name='..') and IsRootPath) then
        begin
          AFile := TFileSystemFileSource.CreateFile(Path, @sr);
          FFiles.Add(AFile);
        end;
        FindResult:= FindNextEx(sr);
      until FindResult<>0;
      if not IsNormalEndOfSearch(FindResult) then
        RaiseAbortOperation;
    end;
  finally
    FindCloseEx(sr);
  end;
end;

end.
