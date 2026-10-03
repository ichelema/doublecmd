program archive_regression;

{
  ICH-118: archive file source regression.

  Drives the real WCX ZIP plugin and the real MultiArchive 7z addon through
  the application's file source operations: create, copy into root and into
  new subdirectories, empty directories, timestamps, copy-out, archive-to-
  archive copy through the temporary file system (as the main window does),
  delete, refresh and ZIP symbolic links with both FollowLinks values.

  Build and run from the repository root (see doc/ICH-118.md):

    lazbuild --skip-dependencies --build-all --ws=qt6 tests/archive_regression.lpi
    QT_QPA_PLATFORM=offscreen ./units/x86_64-linux-archive-tests/archive_regression \
      --config-dir=<empty-scratch-dir> [--follow-links]
}

{$mode objfpc}{$H+}
{$R ../src/doublecmd.res}

uses
  {$IFDEF UNIX}cthreads, cwstring, BaseUnix, Unix,{$ENDIF}
  Interfaces, Forms, Classes, SysUtils, FileUtil, LazFileUtils,
  uGlobs, uGlobsPaths, uSpecialDir, uFile, uFileSource, uFileSourceOperation,
  uFileSourceListOperation, uFileSystemFileSource, uTempFileSystemFileSource,
  uWcxArchiveFileSource, uWcxModule, uMultiArchiveFileSource, uMultiArc,
  uDCUtils, uCryptProc, DCOSUtils, DCStrUtils;

var
  Scratch, Data, OutDir, PluginPath: String;
  FileSystem: IFileSource;
  FollowLinks: Boolean;
  Failures: Integer = 0;

procedure Check(Value: Boolean; const MessageText: String);
begin
  if not Value then
    raise Exception.Create(MessageText);
end;

procedure WriteText(const Path, Text: String);
begin
  ForceDirectories(ExtractFileDir(Path));
  with TFileStream.Create(Path, fmCreate) do
  try
    WriteBuffer(Text[1], Length(Text));
  finally
    Free;
  end;
end;

function ReadText(const Path: String): String;
begin
  with TFileStream.Create(Path, fmOpenRead) do
  try
    SetLength(Result, Size);
    if Size > 0 then ReadBuffer(Result[1], Size);
  finally
    Free;
  end;
end;

procedure Run(Operation: TFileSourceOperation; const What: String);
begin
  try
    Operation.Execute;
    Check(Operation.Result = fsorFinished, What + ': operation did not finish');
  finally
    Operation.Free;
  end;
end;

function LocalFiles(const Base: String; const Names: array of String): TFiles;
var
  Name: String;
begin
  Result := TFiles.Create(IncludeTrailingPathDelimiter(Base));
  for Name in Names do
    Result.Add(TFileSystemFileSource.CreateFileFromFile(Result.Path + Name));
end;

{ Lists one archive directory through the file source; Names receives the
  entry names (directories with a trailing delimiter). }
function ListDir(FS: IFileSource; const Path: String): TFiles;
var
  Op: TFileSourceListOperation;
begin
  Op := FS.CreateListOperation(Path) as TFileSourceListOperation;
  try
    Op.Execute;
    Check(Op.Result = fsorFinished, 'list ' + Path);
    Result := Op.ReleaseFiles;
  finally
    Op.Free;
  end;
end;

function Names(Files: TFiles): String;
var
  I: Integer;
  List: TStringList;
begin
  List := TStringList.Create;
  try
    List.Sorted := True;
    for I := 0 to Files.Count - 1 do
      if Files[I].Name = '..' then
        Continue
      else if Files[I].IsDirectory then
        List.Add(Files[I].Name + PathDelim)
      else
        List.Add(Files[I].Name);
    List.Delimiter := ' ';
    Result := List.DelimitedText;
  finally
    List.Free;
  end;
end;

function Select(Files: TFiles; const Wanted: array of String): TFiles;
var
  I: Integer;
  Name: String;
begin
  Result := TFiles.Create(Files.Path);
  for Name in Wanted do
  begin
    for I := 0 to Files.Count - 1 do
      if Files[I].Name = Name then
      begin
        Result.Add(Files[I].Clone);
        Break;
      end;
  end;
  Check(Result.Count = Length(Wanted), 'select ' + Files.Path + ': entry missing');
end;

procedure CopyIn(FS: IFileSource; Files: TFiles; const Target: String);
begin
  try
    Run(FS.CreateCopyInOperation(FileSystem, Files, Target), 'copy into ' + Target);
  finally
    Files.Free;
  end;
end;

procedure CopyOut(FS: IFileSource; const ArchiveDir: String;
  const Wanted: array of String; const Target: String);
var
  Listed, Files: TFiles;
begin
  ForceDirectories(Target);
  Listed := ListDir(FS, ArchiveDir);
  try
    Files := Select(Listed, Wanted);
    try
      Run(FS.CreateCopyOutOperation(FileSystem, Files, IncludeTrailingPathDelimiter(Target)),
        'copy out of ' + ArchiveDir);
    finally
      Files.Free;
    end;
  finally
    Listed.Free;
  end;
end;

{ Archive-to-archive copy exactly as TfrmMain.CopyFiles does it: copy out to
  a temporary file system source, then copy the cloned source list in. }
procedure ArchiveToArchive(Source: IFileSource; const SourceDir: String;
  const Wanted: array of String; Target: IFileSource; const TargetDir: String);
var
  Temp: IFileSource;
  Listed, Files, TargetFiles: TFiles;
begin
  Temp := TTempFileSystemFileSource.Create;
  Listed := ListDir(Source, SourceDir);
  try
    Files := Select(Listed, Wanted);
    TargetFiles := Files.Clone;
    try
      Run(Source.CreateCopyOutOperation(Temp, Files, Temp.GetRootDir), 'copy out to temp');
      ChangeFileListRoot(Temp.GetRootDir, TargetFiles);
      Run(Target.CreateCopyInOperation(Temp, TargetFiles, TargetDir), 'copy temp into ' + TargetDir);
    finally
      Files.Free;
      TargetFiles.Free;
    end;
  finally
    Listed.Free;
    Temp := nil;
  end;
end;

function IsDir(FS: IFileSource; const Path: String): Boolean;
begin
  Result := FS.FileSystemEntryExists(Path, [TFileSourceExistsOption.needDir]) =
    TFileSourceExistsResult.exists;
end;

function IsFile(FS: IFileSource; const Path: String): Boolean;
begin
  Result := FS.FileSystemEntryExists(Path, [TFileSourceExistsOption.needFile]) =
    TFileSourceExistsResult.exists;
end;

function SameTime(const A, B: String): Boolean;
begin
  // ZIP stores DOS times with two-second resolution.
  Result := Abs(FileAge(A) - FileAge(B)) <= 2;
end;

{ Shared scenario for both archive back ends. Root is FS.GetRootDir. }
procedure Exercise(FS: IFileSource; const Kind: String);
var
  Root, Out1, Out2: String;
  Listed, ToDelete: TFiles;
begin
  Root := FS.GetRootDir;

  // 1. create the archive from the root: file, nested tree, empty directory
  CopyIn(FS, LocalFiles(Data, ['data.txt', 'nested']), Root);
  Check(IsDir(FS, Root), Kind + ': root is not a directory');
  Check(IsDir(FS, ExcludeTrailingPathDelimiter(Root)), Kind + ': root without delimiter');
  Check(not IsFile(FS, Root), Kind + ': root reported as file');
  Check(IsFile(FS, Root + 'data.txt'), Kind + ': data.txt not in archive');
  Check(IsDir(FS, Root + 'nested/inner'), Kind + ': nested/inner missing');
  Check(IsDir(FS, Root + 'nested/empty'), Kind + ': empty directory lost');
  Check(IsFile(FS, Root + 'nested/inner/file2.txt'), Kind + ': nested file missing');
  Check(not IsDir(FS, Root + 'data.txt'), Kind + ': file reported as directory');
  Check(not IsFile(FS, Root + 'missing.txt'), Kind + ': missing file reported');
  Check(FS.SetCurrentWorkingDirectory(Root + 'nested/inner/'), Kind + ': cwd nested/inner');
  Check(FS.SetCurrentWorkingDirectory(Root), Kind + ': cwd root');
  Check(not FS.SetCurrentWorkingDirectory(Root + 'nested/none/'), Kind + ': cwd into missing dir');

  // 2. copy into a new subdirectory, the archive tool must create the path
  CopyIn(FS, LocalFiles(Data, ['late.txt', 'nested']), Root + 'sub/deeper/');
  Check(IsFile(FS, Root + 'sub/deeper/late.txt'), Kind + ': late.txt not in subdir');
  Check(IsDir(FS, Root + 'sub/deeper/nested/empty'), Kind + ': empty dir not in subdir');
  Check(IsFile(FS, Root + 'sub/deeper/nested/inner/file2.txt'), Kind + ': nested file not in subdir');
  Listed := ListDir(FS, Root + 'sub/deeper/');
  try
    Check(Names(Listed) = 'late.txt nested/', Kind + ': subdir listing is ' + Names(Listed));
  finally
    Listed.Free;
  end;
  Listed := ListDir(FS, Root);
  try
    Check(Names(Listed) = 'data.txt nested/ sub/', Kind + ': root listing is ' + Names(Listed));
  finally
    Listed.Free;
  end;

  // 3. copy out and compare content and timestamps
  Out1 := OutDir + Kind + '-root' + PathDelim;
  CopyOut(FS, Root, ['data.txt', 'nested'], Out1);
  Check(ReadText(Out1 + 'data.txt') = 'first', Kind + ': data.txt content');
  Check(ReadText(Out1 + 'nested/inner/file2.txt') = 'second', Kind + ': file2.txt content');
  Check(DirectoryExists(Out1 + 'nested/empty'), Kind + ': empty dir not extracted');
  Check(SameTime(Out1 + 'data.txt', Data + 'data.txt'), Kind + ': data.txt mtime lost');
  Check(SameTime(Out1 + 'nested/inner/file2.txt', Data + 'nested/inner/file2.txt'),
    Kind + ': file2.txt mtime lost');
  Out2 := OutDir + Kind + '-sub' + PathDelim;
  CopyOut(FS, Root + 'sub/deeper/', ['late.txt', 'nested'], Out2);
  Check(ReadText(Out2 + 'late.txt') = 'third', Kind + ': late.txt content');
  Check(SameTime(Out2 + 'late.txt', Data + 'late.txt'), Kind + ': late.txt mtime lost');
  Check(DirectoryExists(Out2 + 'nested/empty'), Kind + ': subdir empty dir not extracted');

  // 4. delete from the archive and make sure the view refreshes
  Listed := ListDir(FS, Root);
  try
    ToDelete := Select(Listed, ['data.txt']);
    Run(FS.CreateDeleteOperation(ToDelete), Kind + ': delete data.txt');
  finally
    Listed.Free;
  end;
  Check(not IsFile(FS, Root + 'data.txt'), Kind + ': data.txt still listed after delete');
  Listed := ListDir(FS, Root);
  try
    Check(Names(Listed) = 'nested/ sub/', Kind + ': listing after delete is ' + Names(Listed));
  finally
    Listed.Free;
  end;
end;

var
  Zip, SevenZip: IFileSource;
  ZipPath, SevenZipPath, LinkOut: String;
  Module: TWCXModule;
  Addon: TMultiArcItem;
  I: Integer;
  Listed: TFiles;

procedure RunCheck(const Name: String; Test: TProcedure);
begin
  try
    Test;
    WriteLn('PASS: ', Name);
  except
    on E: Exception do
    begin
      Inc(Failures);
      WriteLn(StdErr, 'FAIL: ', Name, ': ', E.Message);
      DumpExceptionBackTrace(StdErr);
    end;
  end;
end;

procedure TestZip;
begin
  Module := gWCXPlugins.LoadModule(PluginPath);
  Check(Assigned(Module), 'load ' + PluginPath);
  ZipPath := Scratch + 'fixture.zip';
  Zip := TWcxArchiveFileSource.Create(FileSystem, ZipPath, PluginPath,
    Module.GetPluginCapabilities) as IFileSource;
  Exercise(Zip, 'zip');
end;

procedure TestSevenZip;
begin
  SevenZipPath := Scratch + 'fixture.7z';
  SevenZip := TMultiArchiveFileSource.CreateByArchiveName(FileSystem, SevenZipPath) as IFileSource;
  Check(Assigned(SevenZip), 'no enabled MultiArc addon for .7z');
  Exercise(SevenZip, '7z');
end;

procedure TestArchiveToArchive;
var
  Out: String;
begin
  ArchiveToArchive(Zip, Zip.GetRootDir + 'sub/deeper/', ['late.txt', 'nested'],
    SevenZip, SevenZip.GetRootDir + 'from-zip/');
  Check(IsFile(SevenZip, SevenZip.GetRootDir + 'from-zip/late.txt'), '7z: late.txt from zip missing');
  Check(IsDir(SevenZip, SevenZip.GetRootDir + 'from-zip/nested/empty'), '7z: empty dir from zip missing');
  Out := OutDir + 'zip-to-7z' + PathDelim;
  CopyOut(SevenZip, SevenZip.GetRootDir + 'from-zip/', ['late.txt', 'nested'], Out);
  Check(ReadText(Out + 'late.txt') = 'third', 'zip->7z: late.txt content');
  Check(ReadText(Out + 'nested/inner/file2.txt') = 'second', 'zip->7z: file2.txt content');
  Check(SameTime(Out + 'late.txt', Data + 'late.txt'), 'zip->7z: late.txt mtime lost');

  ArchiveToArchive(SevenZip, SevenZip.GetRootDir + 'sub/deeper/', ['late.txt', 'nested'],
    Zip, Zip.GetRootDir + 'from-7z/x/');
  Check(IsFile(Zip, Zip.GetRootDir + 'from-7z/x/late.txt'), 'zip: late.txt from 7z missing');
  Check(IsDir(Zip, Zip.GetRootDir + 'from-7z/x/nested/empty'), 'zip: empty dir from 7z missing');
  Out := OutDir + '7z-to-zip' + PathDelim;
  CopyOut(Zip, Zip.GetRootDir + 'from-7z/x/', ['late.txt', 'nested'], Out);
  Check(ReadText(Out + 'late.txt') = 'third', '7z->zip: late.txt content');
  Check(ReadText(Out + 'nested/inner/file2.txt') = 'second', '7z->zip: file2.txt content');
  Check(SameTime(Out + 'late.txt', Data + 'late.txt'), '7z->zip: late.txt mtime lost');
end;

procedure TestExternalRefresh;
begin
  // modify the archive behind the file source's back, the list must follow
  WriteText(Data + 'external.txt', 'fourth');
  Check(fpSystem('7z a -y ' + QuoteStr(SevenZipPath) + ' ' + QuoteStr(Data + 'external.txt') +
    ' >/dev/null') = 0, 'external 7z add failed');
  // a view refresh (list operation) must pick the change up
  Listed := ListDir(SevenZip, SevenZip.GetRootDir);
  try
    Check(Pos('external.txt', Names(Listed)) > 0, '7z: externally added file not listed after refresh');
  finally
    Listed.Free;
  end;
  Check(IsFile(SevenZip, SevenZip.GetRootDir + 'external.txt'),
    '7z: externally added file not found after refresh');
end;

procedure TestZipSymlinks;
var
  Root: String;
begin
  Root := Zip.GetRootDir;
  LinkOut := OutDir + 'zip-links' + PathDelim;
  CopyIn(Zip, LocalFiles(Data, ['links']), Root);
  Check(IsDir(Zip, Root + 'links'), 'zip: links dir missing');
  if FollowLinks then
  begin
    // links are replaced by their targets, the recursive link must not recurse forever
    Check(IsFile(Zip, Root + 'links/file-link.txt'), 'zip follow: file link missing');
    Check(IsFile(Zip, Root + 'links/dir-link/inner/file2.txt'), 'zip follow: dir link not expanded');
    Check(IsDir(Zip, Root + 'links/dir-link/empty'), 'zip follow: empty dir in link not expanded');
    CopyOut(Zip, Root + 'links/', ['file-link.txt', 'dir-link'], LinkOut);
    Check(not FileIsSymlink(LinkOut + 'file-link.txt'), 'zip follow: extracted link is a symlink');
    Check(ReadText(LinkOut + 'file-link.txt') = 'first', 'zip follow: file link content');
    Check(ReadText(LinkOut + 'dir-link/inner/file2.txt') = 'second', 'zip follow: dir link content');
  end
  else
  begin
    Check(IsFile(Zip, Root + 'links/file-link.txt'), 'zip: file link entry missing');
    Check(not IsFile(Zip, Root + 'links/dir-link/inner/file2.txt'), 'zip: dir link was expanded');
    CopyOut(Zip, Root + 'links/', ['file-link.txt', 'dir-link', 'loop'], LinkOut);
    Check(FileIsSymlink(LinkOut + 'file-link.txt'), 'zip: file link not extracted as symlink');
    Check(ReadSymLink(LinkOut + 'file-link.txt') = '../data.txt', 'zip: file link target');
    Check(FileIsSymlink(LinkOut + 'dir-link'), 'zip: dir link not extracted as symlink');
    Check(ReadSymLink(LinkOut + 'dir-link') = '../nested', 'zip: dir link target');
    Check(FileIsSymlink(LinkOut + 'loop'), 'zip: recursive link not extracted as symlink');
  end;
end;

begin
  WriteLn('START: archive file source regression');
  if (ParamCount < 1) or (Copy(ParamStr(1), 1, 13) <> '--config-dir=') then
    raise Exception.Create('Usage: archive_regression --config-dir=<empty-scratch-directory> [--follow-links]');
  Scratch := IncludeTrailingPathDelimiter(ExpandFileName(Copy(ParamStr(1), 14, MaxInt)));
  FollowLinks := (ParamCount >= 2) and (ParamStr(2) = '--follow-links');
  Check(DirectoryExists(Scratch), 'scratch directory must already exist');
  Check(FindAllFiles(Scratch, '*', False).Count = 0, 'scratch directory must be empty');

  PluginPath := GetEnvironmentVariable('ICH118_ZIP_PLUGIN');
  if PluginPath = '' then
    PluginPath := ExpandFileName('plugins/wcx/zip/zip.wcx');
  Check(FileExists(PluginPath), 'zip.wcx not found: ' + PluginPath);
  Check(FindDefaultExecutablePath('7z') <> '', '7z executable not found');

  Application.Initialize;
  Application.CaptureExceptions := False;
  gpCfgDir := Scratch;
  gpCmdLineCfgDir := Scratch;
  gpGlobalCfgDir := Scratch;
  gpCacheDir := Scratch + 'cache';
  gpThumbCacheDir := Scratch + 'thumbnails';
  LoadWindowsSpecialDir;
  // the ZIP plugin reads FollowLinks from zip.ini when it is loaded
  WriteText(Scratch + 'zip.ini', '[Configuration]' + LineEnding +
    'FollowLinks=' + IntToStr(Ord(FollowLinks)) + LineEnding);
  // enable the 7z addon from the shipped defaults
  CopyFile(ExpandFileName('default/multiarc.ini'), Scratch + 'multiarc.ini');
  Check(InitGlobs, 'initialize isolated test configuration');
  InitPasswordStore;
  for I := 0 to gMultiArcList.Count - 1 do
  begin
    Addon := gMultiArcList.Items[I];
    Addon.FEnabled := (gMultiArcList.Names[I] = '7Z');
  end;
  gListFilesInThread := False;
  gWatchDirs := [];

  Data := Scratch + 'data' + PathDelim;
  OutDir := Scratch + 'out' + PathDelim;
  WriteText(Data + 'data.txt', 'first');
  WriteText(Data + 'nested/inner/file2.txt', 'second');
  ForceDirectories(Data + 'nested/empty');
  WriteText(Data + 'late.txt', 'third');
  ForceDirectories(Data + 'links');
  Check(fpSymlink('../data.txt', PChar(Data + 'links/file-link.txt')) = 0, 'make file symlink');
  Check(fpSymlink('../nested', PChar(Data + 'links/dir-link')) = 0, 'make dir symlink');
  Check(fpSymlink('..', PChar(Data + 'links/loop')) = 0, 'make recursive symlink');
  // give the fixtures a timestamp distinct from "now"
  FileSetDate(Data + 'data.txt', DateTimeToFileDate(EncodeDate(2024, 3, 5) + EncodeTime(10, 20, 30, 0)));
  FileSetDate(Data + 'nested/inner/file2.txt', DateTimeToFileDate(EncodeDate(2023, 7, 8) + EncodeTime(1, 2, 4, 0)));
  FileSetDate(Data + 'late.txt', DateTimeToFileDate(EncodeDate(2022, 11, 12) + EncodeTime(13, 14, 16, 0)));

  FileSystem := TFileSystemFileSource.GetFileSource;
  try
    RunCheck('WCX ZIP create, subdirectories, copy-out, delete', @TestZip);
    RunCheck('MultiArchive 7z create, subdirectories, copy-out, delete', @TestSevenZip);
    if Assigned(Zip) and Assigned(SevenZip) then
    begin
      RunCheck('archive-to-archive copies through the temporary file system', @TestArchiveToArchive);
      RunCheck('external modification is picked up', @TestExternalRefresh);
      if FollowLinks then
        RunCheck('ZIP symbolic links with FollowLinks=1', @TestZipSymlinks)
      else
        RunCheck('ZIP symbolic links with FollowLinks=0', @TestZipSymlinks);
    end;
  finally
    Zip := nil;
    SevenZip := nil;
    FileSystem := nil;
  end;
  if Failures > 0 then
  begin
    WriteLn('FAIL: ', Failures, ' archive check(s) failed');
    Halt(1);
  end;
  WriteLn('PASS: archive regression checks');
end.
