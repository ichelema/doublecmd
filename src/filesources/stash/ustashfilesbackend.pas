unit uStashFilesBackend;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, syncobjs,
  uFile, uFileSystemFileSource, DCOSUtils;

type

  { TStashFilesBackend }

  TStashFilesBackend = class
  private
    _lockObject: TCriticalSection;
    _paths: TStringList;
    _onChange: TNotifyEvent;
  private
    procedure notifyChange;
    procedure addPath( const path: String ); inline;
    procedure removePath( const path: String ); inline;
    procedure doAddFromStringArray(const pathsArray: TStringArray);
  public
    constructor Create;
    destructor Destroy; override;

    procedure setListener( const listener: TNotifyEvent );

    procedure clear;
    function count: Integer;
    procedure addPaths( const files: TFiles );
    procedure removePaths( const files: TFiles );

    // Returns a fresh file object owned by the caller, or nil if it is missing.
    function findByFilename(const filename: String): TFile;
    function toFiles: TFiles;
    function toStringArray: TStringArray;

    procedure addFromStringArray(const pathsArray: TStringArray);
    procedure setFromStringArray(const pathsArray: TStringArray);
  end;

var
  stashFilesBackend: TStashFilesBackend;

implementation

uses
  uFileSource;

{ TStashFilesBackend }

constructor TStashFilesBackend.Create;
begin
  _lockObject:= TCriticalSection.Create;;
  _paths:= TStringList.Create;
  _paths.SortStyle:= sslAuto;
  _paths.Duplicates:= dupIgnore;
end;

destructor TStashFilesBackend.Destroy;
begin
  FreeAndNIl( _paths );
  FreeAndNil( _lockObject );
end;

procedure TStashFilesBackend.setListener(const listener: TNotifyEvent);
begin
  _onChange:= listener;
end;

procedure TStashFilesBackend.notifyChange;
begin
  if Assigned(_onChange) then
    _onChange(_paths);
end;

procedure TStashFilesBackend.addPath(const path: String);
begin
  _paths.Add( ExcludeTrailingPathDelimiter(path) );
end;

procedure TStashFilesBackend.removePath(const path: String);
var
  i: Integer;
begin
  if _paths.Find( ExcludeTrailingPathDelimiter(path), i ) then
    _paths.Delete( i );
end;

procedure TStashFilesBackend.clear;
begin
  _lockObject.Acquire;
  try
    _paths.Clear;
  finally
    _lockObject.Release;
  end;
  notifyChange;
end;

function TStashFilesBackend.count: Integer;
begin
  _lockObject.Acquire;
  try
    Result:= _paths.Count;
  finally
    _lockObject.Release;
  end;
end;

procedure TStashFilesBackend.addPaths(const files: TFiles);
var
  i: Integer;
begin
  if files.Count = 0 then
    Exit;
  _lockObject.Acquire;
  try
    for i:= 0 to files.Count-1 do
      self.addPath( files[i].FullPath );
  finally
    _lockObject.Release;
  end;
  notifyChange;
end;

procedure TStashFilesBackend.removePaths(const files: TFiles);
var
  i: Integer;
begin
  _lockObject.Acquire;
  try
    for i:= 0 to files.Count-1 do
      self.removePath( files[i].FullPath );
  finally
    _lockObject.Release;
  end;
  notifyChange;
end;

function TStashFilesBackend.findByFilename(const filename: String): TFile;
var
  i: Integer;
begin
  Result:= nil;
  _lockObject.Acquire;
  try
    for i:= 0 to _paths.Count - 1 do
    begin
      if ExtractFileName(_paths[i]) = filename then
      try
        Exit(TFileSystemFileSource.CreateFileFromFile(_paths[i]));
      except
        on EFileNotFound do ;
      end;
    end;
  finally
    _lockObject.Release;
  end;
end;

function TStashFilesBackend.toFiles: TFiles;
var
  files: TFiles;
  path: String;
  f: TFile;
  i: Integer;
begin
  files:= TFiles.Create( EmptyStr );
  i:= 0;

  _lockObject.Acquire;
  try
    while i < _paths.Count do begin
      path:= _paths[i];
      try
        f:= TFileSystemFileSource.CreateFileFromFile( path );
        files.Add( f );
        inc( i );
      except
        _paths.Delete( i );
      end;
    end;
  finally
    _lockObject.Release;
  end;

  Result:= files;
end;

function TStashFilesBackend.toStringArray: TStringArray;
begin
  _lockObject.Acquire;
  try
    Result:= _paths.ToStringArray;
  finally
    _lockObject.Release;
  end;
end;

procedure TStashFilesBackend.doAddFromStringArray(const pathsArray: TStringArray);
var
  path: String;
begin
  for path in pathsArray do
  begin
    if path.IsEmpty then
      continue;
    if mbFileSystemEntryExists(path) then
      self.addPath(path);
  end;
end;

procedure TStashFilesBackend.addFromStringArray(const pathsArray: TStringArray);
begin
  _lockObject.Acquire;
  try
    doAddFromStringArray( pathsArray );
  finally
    _lockObject.Release;
  end;
  notifyChange;
end;

procedure TStashFilesBackend.setFromStringArray(const pathsArray: TStringArray);
begin
  _lockObject.Acquire;
  try
    _paths.Clear;
    doAddFromStringArray( pathsArray );
  finally
    _lockObject.Release;
  end;
  notifyChange;
end;

initialization
  stashFilesBackend:= TStashFilesBackend.Create;

finalization
  FreeAndNil( stashFilesBackend );

end.

