program filesource_regression;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  Interfaces, Classes, SysUtils, uFile, uFileSource, uFileSystemFileSource,
  uFileSourceUtil, uMountedFileSource, uStashFilesBackend, DCOSUtils;

type
  TMappedFileSystem = class(TFileSystemFileSource)
  public
    Prefix, Target: String;
    function GetRealPath(const APath: String): String; override;
  end;

  TUnsupportedFileSource = class(TFileSource);

  TListener = class
    procedure Changed(Sender: TObject);
  end;

var
  Scratch, FilePath, DirPath, MissingPath, OriginalDir: String;
  FS: TMappedFileSystem;
  Unsupported: TUnsupportedFileSource;
  LocalFileSystem: IFileSource;
  Backend: TStashFilesBackend;
  Files: TFiles;
  Notifications: Integer;

function TMappedFileSystem.GetRealPath(const APath: String): String;
begin
  if Copy(APath, 1, Length(Prefix)) = Prefix then
    Result := Target + Copy(APath, Length(Prefix) + 1, MaxInt)
  else
    Result := APath;
end;

procedure TListener.Changed(Sender: TObject);
begin
  Inc(Notifications);
end;

procedure Check(Value: Boolean; const MessageText: String);
begin
  if not Value then
    raise Exception.Create(MessageText);
end;

procedure TestFileSystem;
var
  LogicalDir, RootPath: String;
begin
  FS := TMappedFileSystem.Create;
  LocalFileSystem := FS;
  try
    Check(FS.FileSystemEntryExists(FilePath, [TFileSourceExistsOption.needFile]) =
      TFileSourceExistsResult.exists, 'file exists');
    Check(FS.FileSystemEntryExists(DirPath, [TFileSourceExistsOption.needDir]) =
      TFileSourceExistsResult.exists, 'directory exists');
    Check(FS.FileSystemEntryExists(MissingPath, [TFileSourceExistsOption.needFile]) =
      TFileSourceExistsResult.notExist, 'missing file');
    Check(FS.FileSystemEntryExists(Scratch, [TFileSourceExistsOption.needDir]) =
      TFileSourceExistsResult.exists, 'directory root');
    RootPath := FS.GetRootDir(Scratch);
    Check(FS.FileSystemEntryExists(RootPath, [TFileSourceExistsOption.needDir]) =
      TFileSourceExistsResult.exists, 'filesystem root');
    Check(FS.FileSystemEntryExists(IncludeTrailingPathDelimiter(RootPath),
      [TFileSourceExistsOption.needDir]) = TFileSourceExistsResult.exists,
      'filesystem root with trailing delimiter');
    Check(FS.FileSystemEntryExists(DirPath + PathDelim,
      [TFileSourceExistsOption.needDir]) = TFileSourceExistsResult.exists,
      'directory trailing delimiter');
    Check(FS.FileSystemEntryExists(FilePath, [TFileSourceExistsOption.needDir]) =
      TFileSourceExistsResult.notExist, 'file is not directory');
    Check(FS.FileSystemEntryExists(DirPath, [TFileSourceExistsOption.needFile]) =
      TFileSourceExistsResult.notExist, 'directory is not file');
    Check(FS.FileSystemEntryExists(FilePath,
      [TFileSourceExistsOption.needFile, TFileSourceExistsOption.needDir]) =
      TFileSourceExistsResult.exists, 'file with both options');
    Check(FS.FileSystemEntryExists(DirPath,
      [TFileSourceExistsOption.needFile, TFileSourceExistsOption.needDir]) =
      TFileSourceExistsResult.exists, 'directory with both options');
    Check(FS.FileSystemEntryExists(MissingPath, []) =
      TFileSourceExistsResult.notExist, 'missing path with no options');
    Check(FS.FileSystemEntryExists(FilePath, []) =
      TFileSourceExistsResult.notExist, 'existing file with no options');

    FS.Prefix := Scratch + 'ich120-mapped' + PathDelim;
    FS.Target := Scratch + 'ich120-real' + PathDelim;
    Check(ForceDirectories(FS.Target), 'create mapping target');
    LogicalDir := FS.Prefix + 'created' + PathDelim;
    Check(FS.CreateDirectory(LogicalDir), 'create mapped directory');
    Check(SysUtils.DirectoryExists(FS.Target + 'created'), 'mapped directory created');
    Check(FS.FileSystemEntryExists(LogicalDir, [TFileSourceExistsOption.needDir]) =
      TFileSourceExistsResult.exists, 'mapped directory check');

    OriginalDir := GetCurrentDir;
    try
      Check(LocalFileSystem.SetCurrentWorkingDirectory(LogicalDir), 'set mapped cwd');
      LogicalDir := GetCurrentDir;
      Check(not LocalFileSystem.SetCurrentWorkingDirectory(FS.Prefix + 'missing'),
        'reject missing mapped cwd');
      Check(GetCurrentDir = LogicalDir,
        'failed navigation preserves cwd');
    finally
      Check(SetCurrentDir(OriginalDir), 'restore working directory');
    end;
  finally
    LocalFileSystem := nil;
  end;
end;

procedure TestUnsupported;
var
  UnsupportedFS: IFileSource;
begin
  Unsupported := TUnsupportedFileSource.Create;
  UnsupportedFS := Unsupported;
  try
    Check(Unsupported.FileSystemEntryExists('anything', []) =
      TFileSourceExistsResult.notSupported, 'default unsupported source');
    Check(uFileSourceUtil.FileExists(UnsupportedFS, 'anything'),
      'FileExists treats unsupported as true');
    Check(uFileSourceUtil.DirectoryExists(UnsupportedFS, 'anything'),
      'DirectoryExists treats unsupported as true');
    Check(uFileSourceUtil.FileOrDirExists(UnsupportedFS, 'anything'),
      'FileOrDirExists treats unsupported as true');
  finally
    UnsupportedFS := nil;
  end;
end;

procedure TestMountedFileSystem;
var
  Mounted: TMountedFileSource;
  MountedRoot, RootPath, AppPath, NewPath, RealRoot, RealApp: String;
  LocalFileSource: IFileSource;
begin
  RealRoot := Scratch + 'ich120-real-root' + PathDelim;
  RealApp := Scratch + 'ich120-real-app' + PathDelim;
  Check(ForceDirectories(RealRoot), 'create mounted root');
  Check(ForceDirectories(RealApp), 'create mounted app path');
  with TFileStream.Create(RealRoot + 'root-file', fmCreate) do Free;
  with TFileStream.Create(RealApp + 'app-file', fmCreate) do Free;

  Mounted := TMountedFileSource.Create;
  LocalFileSource := Mounted;
  try
    { Match iCloud registration order: specific mounts precede the fallback. }
    Mounted.mount(RealApp, PathDelim + 'App' + PathDelim);
    Mounted.mount(RealRoot, PathDelim);
    MountedRoot := Mounted.GetRootDir;
    RootPath := MountedRoot;
    AppPath := MountedRoot + 'App' + PathDelim;
    Check(Mounted.FileSystemEntryExists(RootPath,
      [TFileSourceExistsOption.needDir]) = TFileSourceExistsResult.exists,
      'mounted root with delimiter');
    Check(Mounted.FileSystemEntryExists(ExcludeTrailingPathDelimiter(RootPath),
      [TFileSourceExistsOption.needDir]) = TFileSourceExistsResult.exists,
      'mounted root without delimiter');
    Check(Mounted.FileSystemEntryExists(AppPath,
      [TFileSourceExistsOption.needDir]) = TFileSourceExistsResult.exists,
      'mounted App with delimiter');
    Check(Mounted.FileSystemEntryExists(ExcludeTrailingPathDelimiter(AppPath),
      [TFileSourceExistsOption.needDir]) = TFileSourceExistsResult.exists,
      'mounted App without delimiter');

    OriginalDir := GetCurrentDir;
    try
      Check(LocalFileSource.SetCurrentWorkingDirectory(
        ExcludeTrailingPathDelimiter(AppPath)),
        'set cwd to mounted App');
      Check(not LocalFileSource.SetCurrentWorkingDirectory(AppPath + 'missing'),
        'reject missing mounted cwd');
    finally
      Check(SetCurrentDir(OriginalDir), 'restore working directory after mounted test');
    end;

    NewPath := AppPath + 'created' + PathDelim;
    Check(Mounted.CreateDirectory(NewPath), 'create directory on mounted source');
    Check(SysUtils.DirectoryExists(RealApp + 'created'),
      'mounted directory created physically');
    Check(Mounted.FileSystemEntryExists(NewPath,
      [TFileSourceExistsOption.needDir]) = TFileSourceExistsResult.exists,
      'check mounted created directory');
  finally
    LocalFileSource := nil;
    DeleteFile(RealRoot + 'root-file');
    DeleteFile(RealApp + 'app-file');
    RemoveDir(RealApp + 'created');
    RemoveDir(RealApp);
    RemoveDir(RealRoot);
  end;
end;

procedure TestStashBackend;
var
  Paths: TStringArray;
  EmptyFiles: TFiles;
  FoundFile: TFile;
  Listener: TListener;
begin
  Backend := TStashFilesBackend.Create;
  Listener := TListener.Create;
  try
    SetLength(Paths, 1);
    Paths[0] := FilePath;
    Notifications := 0;
    Backend.setListener(@Listener.Changed);
    Backend.setFromStringArray(Paths);
    Check(Backend.count = 1, 'stash set paths');
    Check(Notifications = 1, 'one notification per mutation');
    Notifications := 0;
    Files := Backend.toFiles;
    try
      Check(Files.Count = 1, 'stash returns real file');
    finally
      Files.Free;
    end;
    Check(Notifications = 0, 'reading stash does not notify');
    FoundFile := Backend.findByFilename('ich120-file');
    try
      Check(Assigned(FoundFile) and (FoundFile.FullPath = FilePath),
        'lookup survives freeing toFiles result');
    finally
      FoundFile.Free;
    end;

    Files := Backend.toFiles;
    try
      Check(Files.Count = 1, 'stash remains valid after result free');
    finally
      Files.Free;
    end;

    Check(DeleteFile(FilePath), 'remove stashed file');
    FoundFile := Backend.findByFilename('ich120-file');
    try
      Check(FoundFile = nil, 'lookup rejects deleted file before list refresh');
    finally
      FoundFile.Free;
    end;
    Files := Backend.toFiles;
    try
      Check(Files.Count = 0, 'stale file is not returned');
    finally
      Files.Free;
    end;
    Check(Backend.count = 0, 'stale file removed from stash');
    Check(Backend.findByFilename('ich120-file') = nil,
      'stale file is not reported');
    with TFileStream.Create(FilePath, fmCreate) do Free;

    Backend.setListener(nil);
    Backend.clear;
    SetLength(Paths, 2);
    Paths[0] := FilePath;
    Paths[1] := MissingPath;
    Backend.setFromStringArray(Paths);
    Check(Backend.count = 1, 'stale path is not retained');
    Files := TFiles.Create('');
    try
      Files.Add(TFile.Create(''));
      Files[0].FullPath := MissingPath;
      Backend.removePaths(Files);
    finally
      Files.Free;
    end;
    Check(Backend.count = 1, 'removing absent path keeps other file');
    Files := TFiles.Create('');
    try
      Files.Add(TFile.Create(''));
      Files[0].FullPath := FilePath;
      Backend.removePaths(Files);
    finally
      Files.Free;
    end;
    Check(Backend.count = 0, 'remove existing path');

    Backend.setListener(@Listener.Changed);
    Notifications := 0;
    EmptyFiles := TFiles.Create('');
    try
      Backend.addPaths(EmptyFiles);
    finally
      EmptyFiles.Free;
    end;
    Check(Notifications = 0, 'empty add does not notify');
  finally
    Backend.Free;
    Listener.Free;
  end;
end;

begin
  WriteLn('START: file source regressions');
  if ParamCount <> 1 then
    raise Exception.Create('Usage: filesource_regression <existing-scratch-directory>');
  Scratch := IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)));
  Check(SysUtils.DirectoryExists(Scratch), 'scratch directory must already exist');
  FilePath := Scratch + 'ich120-file';
  DirPath := Scratch + 'ich120-dir';
  MissingPath := Scratch + 'ich120-missing';
  if mbFileSystemEntryExists(FilePath) or mbFileSystemEntryExists(DirPath) or
     mbFileSystemEntryExists(MissingPath) or
     mbFileSystemEntryExists(Scratch + 'ich120-real') or
     mbFileSystemEntryExists(Scratch + 'ich120-mapped') or
     mbFileSystemEntryExists(Scratch + 'ich120-real-root') or
     mbFileSystemEntryExists(Scratch + 'ich120-real-app') then
    raise Exception.Create('scratch contains reserved ich120 test paths');

  try
    with TFileStream.Create(FilePath, fmCreate) do Free;
    Check(CreateDir(DirPath), 'create test directory');
    WriteLn('CHECK: filesystem existence and mapping');
    TestFileSystem;
    WriteLn('CHECK: unsupported source compatibility');
    TestUnsupported;
    WriteLn('CHECK: mounted paths');
    TestMountedFileSystem;
    WriteLn('CHECK: stash lifetime and notifications');
    TestStashBackend;
    { WFX empty-directory and file/directory existence checks remain manual. }
    WriteLn('PASS: filesystem and stash regression checks');
  finally
    DeleteFile(FilePath);
    RemoveDir(DirPath);
    RemoveDir(Scratch + 'ich120-real' + PathDelim + 'created');
    RemoveDir(Scratch + 'ich120-real');
    DeleteFile(Scratch + 'ich120-real-root' + PathDelim + 'root-file');
    DeleteFile(Scratch + 'ich120-real-app' + PathDelim + 'app-file');
    RemoveDir(Scratch + 'ich120-real-app' + PathDelim + 'created');
    RemoveDir(Scratch + 'ich120-real-root');
    RemoveDir(Scratch + 'ich120-real-app');
  end;
end.
