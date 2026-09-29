program syncdirs_regression;

{$mode objfpc}{$H+}
{$modeswitch nestedprocvars}
{$codepage utf8}
{$R ../src/doublecmd.res}

uses
  {$IFDEF UNIX}cthreads, cwstring, BaseUnix,{$ENDIF}
  {$IFDEF LINUX}InitC,{$ENDIF}
  Interfaces, Forms, Classes, SysUtils, FileUtil, IntegerList, LazFileUtils,
  uDCUtils, uGlobs, uGlobsPaths, uPixMapManager, uSpecialDir, uFile,
  uFileSource, uFileSourceListOperation, uFileSourceOperation,
  uFileSourceCopyOperation, uFileSourceOperationTypes,
  uFileSourceOperationOptions, uFileSourceOperationUI, uFileSourceUtil, uFileSystemFileSource,
  uGioFileSource, uSyncDirsModel, uSyncDirsService, uWcxArchiveFileSource,
  uWcxModule, uCryptProc, uFindEx, URIParser;

type
  TSyncDirsCallbacks = class(TObject, ISyncDirsTreeBuilderCallback,
    ISyncDirsSynchronizerCallback, ISyncDirsFileProcessorWithUI)
  public
    AbortScan, AbortSync, FailDelete: Boolean;
    ExcludeName, ExcludeExtension, SelectedExcludeName: String;
    function treeBuilderCheckRunning(const processMessages: Boolean): Boolean;
    function treeBuilderMaskFilt(const f: TFile): Boolean;
    function treeBuilderSelectedFilt(const filename: String): Boolean;
    procedure onTreeBuilderUpdateProgress(const percent: Integer);
    function synchronizerCheckRunning: Boolean;
    function fileProcessorWithUICopyFiles(const sourceFS, targetFS: IFileSource;
      var files: TFiles; const targetPath: String): Boolean;
    function fileProcessorWithUIDeleteFiles(const fs: IFileSource;
      var files: TFiles): Boolean;
    function fileProcessorWithUIDeleteFile(const fs: IFileSource;
      const f: TFile): Boolean;
  end;

  TFailedListOperation = class(TFileSourceListOperation)
  protected
    procedure MainExecute; override;
  end;

  TSkippedCopyOperation = class(TFileSourceCopyOperation)
  public
    procedure MainExecute; override;
  end;

  TTestOperationUI = class(TFileSourceOperationUI)
  public
    Asked: Boolean;
    Response: TFileSourceOperationUIAnswer;
    function AskQuestion(Msg, Question: String;
      PossibleResponses: array of TFileSourceOperationUIResponse;
      DefaultOKResponse: TFileSourceOperationUIResponse;
      DefaultCancelResponse: TFileSourceOperationUIAnswer;
      ActionHandler: TFileSourceOperationUIActionHandler = nil
      ): TFileSourceOperationUIAnswer; override;
  end;

  TTestFileSystem = class(TFileSystemFileSource)
  public
    FailedListPath, FailedCreatePath: String;
    FailCopy: Boolean;
    function CreateListOperation(TargetPath: String): TFileSourceOperation; override;
    function CreateDirectory(const Path: String): Boolean; override;
    function GetOperationsTypes: TFileSourceOperationTypes; override;
    function CreateCopyOperation(var SourceFiles: TFiles;
      TargetPath: String): TFileSourceOperation; override;
    function CreateCopyOutOperation(TargetFileSource: IFileSource;
      var SourceFiles: TFiles; TargetPath: String): TFileSourceOperation; override;
  end;

var
  Failures: Integer = 0;
  Scratch, Fixture, LeftRoot, RightRoot, OutsideRoot: String;
  Callbacks: TSyncDirsCallbacks;
  FileSystem: IFileSource;
  TestFileSystem: TTestFileSystem;
  OperationUI: TTestOperationUI;

procedure Check(Value: Boolean; const MessageText: String);
begin
  if not Value then
    raise Exception.Create(MessageText);
end;

procedure WriteFixture(const Path, Value: String);
var
  Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(Path));
  Stream := TFileStream.Create(Path, fmCreate);
  try
    if Value <> '' then
      Stream.WriteBuffer(Value[1], Length(Value));
  finally
    Stream.Free;
  end;
end;

function ReadFixture(const Path: String): String;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Result <> '' then
      Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure BeginFixture(const Name: String);
begin
  if Fixture <> '' then
    DeleteDirectory(Fixture, False);
  Fixture := Scratch + Name + PathDelim;
  LeftRoot := Fixture + 'left' + PathDelim;
  RightRoot := Fixture + 'right' + PathDelim;
  OutsideRoot := Fixture + 'outside' + PathDelim;
  Check(not DirectoryExists(Fixture), 'fixture already exists: ' + Fixture);
  Check(ForceDirectories(LeftRoot) and ForceDirectories(RightRoot) and
    ForceDirectories(OutsideRoot), 'create fixture roots for ' + Name);
  Callbacks.AbortScan := False;
  Callbacks.AbortSync := False;
  Callbacks.FailDelete := False;
  Callbacks.ExcludeName := '';
  Callbacks.ExcludeExtension := '';
  Callbacks.SelectedExcludeName := '';
  TestFileSystem.FailedListPath := '';
  TestFileSystem.FailedCreatePath := '';
  TestFileSystem.FailCopy := False;
  OperationUI.Asked := False;
  OperationUI.Response := fsourAbort;
end;

function TSyncDirsCallbacks.treeBuilderCheckRunning(
  const processMessages: Boolean): Boolean;
begin
  Result := not AbortScan;
end;

function TSyncDirsCallbacks.treeBuilderMaskFilt(const f: TFile): Boolean;
begin
  Result := (f.Name <> ExcludeName) and
    ((ExcludeExtension = '') or not SameText(ExtractFileExt(f.Name), ExcludeExtension));
end;

function TSyncDirsCallbacks.treeBuilderSelectedFilt(
  const filename: String): Boolean;
begin
  Result := filename <> SelectedExcludeName;
end;

procedure TSyncDirsCallbacks.onTreeBuilderUpdateProgress(const percent: Integer);
begin
end;

function TSyncDirsCallbacks.synchronizerCheckRunning: Boolean;
begin
  Result := not AbortSync;
end;

function TSyncDirsCallbacks.fileProcessorWithUICopyFiles(
  const sourceFS, targetFS: IFileSource; var files: TFiles;
  const targetPath: String): Boolean;
  procedure HandleOperation(const operation: TFileSourceOperation;
    const state: TFileSourceOperationState);
  begin
    if (state = fsosStarting) and (operation is TFileSourceCopyOperation) then
    begin
      TFileSourceCopyOperation(operation).FileExistsOption := fsoofeOverwrite;
      operation.AddUserInterface(OperationUI);
    end;
  end;
begin
  Result := TSyncDirsUtil.copyFiles(sourceFS, targetFS, files, targetPath,
    @HandleOperation);
end;

function TSyncDirsCallbacks.fileProcessorWithUIDeleteFiles(
  const fs: IFileSource; var files: TFiles): Boolean;
  procedure NoopOperationHandle(const operation: TFileSourceOperation;
    const state: TFileSourceOperationState);
  begin
  end;
begin
  Result := TSyncDirsUtil.deleteFiles(fs, files, @NoopOperationHandle);
end;

function TSyncDirsCallbacks.fileProcessorWithUIDeleteFile(
  const fs: IFileSource; const f: TFile): Boolean;
var
  Files: TFiles;
  procedure NoopOperationHandle(const operation: TFileSourceOperation;
    const state: TFileSourceOperationState);
  begin
  end;
begin
  if FailDelete then
    Exit(False);
  Files := TFiles.Create('');
  try
    Files.Add(f.Clone);
    Result := TSyncDirsUtil.deleteFiles(fs, Files, @NoopOperationHandle);
  finally
    Files.Free;
  end;
end;

procedure TFailedListOperation.MainExecute;
begin
  FFiles := TFiles.Create(Path);
  FFiles.Add(TFileSystemFileSource.CreateFile(Path + 'partial-data'));
  RaiseAbortOperation;
end;

procedure TSkippedCopyOperation.MainExecute;
begin
  AskQuestion('', 'Injected copy failure', [fsourSkip, fsourSkipAll, fsourAbort],
    fsourSkip, fsourAbort);
end;

function TTestOperationUI.AskQuestion(Msg, Question: String;
  PossibleResponses: array of TFileSourceOperationUIResponse;
  DefaultOKResponse: TFileSourceOperationUIResponse;
  DefaultCancelResponse: TFileSourceOperationUIAnswer;
  ActionHandler: TFileSourceOperationUIActionHandler): TFileSourceOperationUIAnswer;
begin
  Asked := True;
  Result := Response;
end;

function TTestFileSystem.CreateListOperation(
  TargetPath: String): TFileSourceOperation;
begin
  if (FailedListPath <> '') and SameText(
     ExcludeTrailingPathDelimiter(TargetPath),
     ExcludeTrailingPathDelimiter(FailedListPath)) then
    Result := TFailedListOperation.Create(Self as IFileSource, TargetPath)
  else
    Result := inherited CreateListOperation(TargetPath);
end;

function TTestFileSystem.CreateDirectory(const Path: String): Boolean;
begin
  if (FailedCreatePath <> '') and SameText(
     ExcludeTrailingPathDelimiter(Path),
     ExcludeTrailingPathDelimiter(FailedCreatePath)) then
    Exit(False);
  Result := inherited CreateDirectory(Path);
end;

function TTestFileSystem.GetOperationsTypes: TFileSourceOperationTypes;
begin
  Result := inherited GetOperationsTypes;
  // The injected failure has no alternate directory-creation mechanism.
  if FailedCreatePath <> '' then Exclude(Result, fsoCopyIn);
end;

function TTestFileSystem.CreateCopyOperation(var SourceFiles: TFiles;
  TargetPath: String): TFileSourceOperation;
begin
  if FailCopy then
    Result := TSkippedCopyOperation.Create(Self, Self, SourceFiles, TargetPath)
  else
    Result := inherited CreateCopyOperation(SourceFiles, TargetPath);
end;

function TTestFileSystem.CreateCopyOutOperation(TargetFileSource: IFileSource;
  var SourceFiles: TFiles; TargetPath: String): TFileSourceOperation;
begin
  if FailCopy then
    Result := TSkippedCopyOperation.Create(Self, TargetFileSource, SourceFiles, TargetPath)
  else
    Result := inherited CreateCopyOutOperation(TargetFileSource, SourceFiles, TargetPath);
end;

procedure BuildTree(const Flags: TSyncDirsCompareFlags; out Tree: TTwoLevelTree;
  out Option: TSyncDirsCompareOption; out Sorter: TSyncDirsSortService;
  out Builder: TSyncDirsTreeBuilder);
begin
  Option := TSyncDirsCompareOption.Create(Flags);
  Sorter := TSyncDirsSortService.Create;
  Sorter.sortIndex := 0;
  Sorter.sortDesc := False;
  Tree := TTwoLevelTree.Create;
  Builder := TSyncDirsTreeBuilder.Create(Callbacks, Sorter, Option);
  Builder.fileSourceL := FileSystem;
  Builder.fileSourceR := FileSystem;
  Builder.baseDirL := LeftRoot;
  Builder.baseDirR := RightRoot;
end;

function BuildFlat(const Flags: TSyncDirsCompareFlags;
  out Tree: TTwoLevelTree; out Flat: TFlatDirFileList;
  out Option: TSyncDirsCompareOption): Boolean;
var
  Sorter: TSyncDirsSortService;
  Builder: TSyncDirsTreeBuilder;
begin
  BuildTree(Flags, Tree, Option, Sorter, Builder);
  Flat := TFlatDirFileList.Create;
  try
    Result := Builder.build(Tree);
    if Result then
      Tree.filterFlatListWithFlags(Flat,
        [ffCopyRight, ffCopyLeft, ffEqual, ffNotEqual, ffUnknown, ffDuplicate, ffSingle]);
  finally
    Builder.Free;
    Sorter.Free;
  end;
end;

procedure FreeComparison(var Tree: TTwoLevelTree; var Flat: TFlatDirFileList;
  var Option: TSyncDirsCompareOption);
begin
  Flat.Free;
  Tree.Free;
  Option.Free;
  Flat := nil;
  Tree := nil;
  Option := nil;
end;

function FindFlatPath(const Flat: TFlatDirFileList; const Path: String): Integer;
var
  I: Integer;
  ItemPath: String;
begin
  for I := 0 to Flat.Count - 1 do
  begin
    ItemPath := Flat.path(I);
    if not Flat.fileSyncRec(I).isDir then
      ItemPath := Flat.fileSyncRec(I).relPath + ItemPath;
    if ItemPath = Path then
      Exit(I);
  end;
  Result := -1;
end;

procedure SyncFlat(const Flat: TFlatDirFileList; const Flags: TSyncDirsSyncFlags);
var
  Synchronizer: TSyncDirsSynchronizer;
begin
  Synchronizer := TSyncDirsSynchronizer.Create(Callbacks, Callbacks, Flat);
  try
    Synchronizer.leftFS := FileSystem;
    Synchronizer.rightFS := FileSystem;
    Synchronizer.leftBasePath := LeftRoot;
    Synchronizer.rightBasePath := RightRoot;
    Synchronizer.sync(Flags);
  finally
    Synchronizer.Free;
  end;
end;

procedure TestBidirectionalCopy;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
begin
  BeginFixture('bidirectional');
  WriteFixture(LeftRoot + 'nested/from-left.txt', 'left');
  WriteFixture(RightRoot + 'nested/from-right.txt', 'right');
  WriteFixture(LeftRoot + 'replace.txt', 'newer-left');
  WriteFixture(RightRoot + 'replace.txt', 'older-right');
  WriteFixture(LeftRoot + 'same.txt', 'identical');
  WriteFixture(RightRoot + 'same.txt', 'identical');
  WriteFixture(RightRoot + 'only-right.txt', 'delete me');
  FileSetDate(LeftRoot + 'replace.txt', DateTimeToFileDate(EncodeDate(2024, 1, 2)));
  FileSetDate(RightRoot + 'replace.txt', DateTimeToFileDate(EncodeDate(2024, 1, 1)));
  FileSetDate(LeftRoot + 'same.txt', DateTimeToFileDate(EncodeDate(2024, 1, 3)));
  FileSetDate(RightRoot + 'same.txt', DateTimeToFileDate(EncodeDate(2024, 1, 3)));

  Check(BuildFlat([cfSubdirs, cfEmptyDirs], Tree, Flat, Option),
    'compare bidirectional fixture');
  try
    SyncFlat(Flat, []);
    Check(not FileExists(LeftRoot + 'nested/from-right.txt'),
      'empty sync flags performed a copy');
    SyncFlat(Flat, [sfCopyToLeft]);
    Check(ReadFixture(LeftRoot + 'nested/from-right.txt') = 'right',
      'sfCopyToLeft did not copy the right-only file');
    Check(not FileExists(RightRoot + 'nested/from-left.txt'),
      'sfCopyToLeft copied a left-only file');
    SyncFlat(Flat, [sfCopyToRight]);
    Check(ReadFixture(RightRoot + 'nested/from-left.txt') = 'left',
      'sfCopyToRight did not copy the left-only nested file');
    Check(FileExists(RightRoot + 'only-right.txt') and
      FileExists(LeftRoot + 'only-right.txt'),
      'right-only file did not copy to left');
    Check(ReadFixture(RightRoot + 'replace.txt') = 'newer-left',
      'newer left file was not copied to right');
    Check((ReadFixture(LeftRoot + 'same.txt') = 'identical') and
      (ReadFixture(RightRoot + 'same.txt') = 'identical'),
      'identical files changed during synchronization');
  finally
    FreeComparison(Tree, Flat, Option);
  end;

  WriteFixture(RightRoot + 'replace.txt', 'newer-right');
  FileSetDate(LeftRoot + 'replace.txt', DateTimeToFileDate(EncodeDate(2024, 1, 1)));
  FileSetDate(RightRoot + 'replace.txt', DateTimeToFileDate(EncodeDate(2024, 1, 2)));
  Check(BuildFlat([cfSubdirs], Tree, Flat, Option), 'compare reverse timestamp direction');
  try
    SyncFlat(Flat, [sfCopyToLeft]);
    Check(ReadFixture(LeftRoot + 'replace.txt') = 'newer-right',
      'newer right file was not copied to left');
  finally
    FreeComparison(Tree, Flat, Option);
  end;

  ForceDirectories(RightRoot + 'remove/a/b');
  Check(BuildFlat([cfSubdirs, cfEmptyDirs, cfAsymmetric], Tree, Flat, Option),
    'compare nested empty directories for deletion');
  try
    SyncFlat(Flat, []);
    Check(DirectoryExists(RightRoot + 'remove/a/b'),
      'empty sync flags performed a directory deletion');
    SyncFlat(Flat, [sfDeleteRight]);
    Check(not DirectoryExists(RightRoot + 'remove'),
      'nested empty directories were not removed deepest-first');
  finally
    FreeComparison(Tree, Flat, Option);
  end;
end;

procedure TestAsymmetricNewerRightAndDelete;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
begin
  BeginFixture('asymmetric');
  WriteFixture(LeftRoot + 'dated.txt', 'old-left');
  WriteFixture(RightRoot + 'dated.txt', 'new-right');
  WriteFixture(RightRoot + 'right-only.txt', 'delete');
  FileSetDate(LeftRoot + 'dated.txt', DateTimeToFileDate(EncodeDate(2024, 1, 1)));
  FileSetDate(RightRoot + 'dated.txt', DateTimeToFileDate(EncodeDate(2024, 1, 2)));
  Check(BuildFlat([cfSubdirs, cfAsymmetric], Tree, Flat, Option),
    'compare asymmetric newer-right fixture');
  try
    // Asymmetric mode mirrors the left side, even when the right file is newer.
    SyncFlat(Flat, [sfCopyToRight, sfDeleteRight]);
    Check(ReadFixture(RightRoot + 'dated.txt') = 'old-left',
      'asymmetric synchronization did not replace the newer right file from the left');
    Check(not FileExists(RightRoot + 'right-only.txt'),
      'asymmetric right-only file survived deletion');
  finally
    FreeComparison(Tree, Flat, Option);
  end;
end;

procedure TestEmptyDirectoriesAndCounts;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
  Synchronizer: TSyncDirsSynchronizer;
  Count: TSyncDirsSyncCount;
begin
  BeginFixture('empty-dirs');
  ForceDirectories(RightRoot + 'empty/top/deep');
  ForceDirectories(LeftRoot + 'left-empty/nested');
  Check(BuildFlat([cfSubdirs, cfEmptyDirs], Tree, Flat, Option),
    'compare empty-directory fixture');
  try
    Synchronizer := TSyncDirsSynchronizer.Create(Callbacks, Callbacks, Flat);
    try
      Synchronizer.leftFS := FileSystem;
      Synchronizer.rightFS := FileSystem;
      Synchronizer.leftBasePath := LeftRoot;
      Synchronizer.rightBasePath := RightRoot;
      Count := Synchronizer.count;
      Check((Count.copyToLeftCount = 3) and (Count.copyToRightCount = 2) and
        (Count.copyToLeftSize = 0) and (Count.copyToRightSize = 0),
        'empty-directory preview count/bytes');
    finally
      Synchronizer.Free;
    end;
    SyncFlat(Flat, [sfCopyToLeft]);
    Check(DirectoryExists(LeftRoot + 'empty/top/deep'),
      'nested empty directory was not copied');
    SyncFlat(Flat, [sfCopyToRight]);
    Check(DirectoryExists(RightRoot + 'left-empty/nested'),
      'nested empty directory was not copied in the reverse direction');
  finally
    FreeComparison(Tree, Flat, Option);
  end;
end;

procedure TestFilteredAndUnselectedChildrenProtectDirectory;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
  I, DirIndex: Integer;
  DirRec: TDirSyncRec;
begin
  BeginFixture('filtered-child');
  WriteFixture(RightRoot + 'guard/visible.txt', 'delete');
  WriteFixture(RightRoot + 'guard/hidden.bin', 'preserve');
  Callbacks.ExcludeExtension := '.bin';
  Check(BuildFlat([cfSubdirs, cfEmptyDirs, cfAsymmetric], Tree, Flat, Option),
    'compare filtered-child fixture');
  try
    DirIndex := Tree.indexOfDir('guard');
    Check(DirIndex >= 0, 'guard directory missing from tree');
    DirRec := Tree.dirItem(DirIndex).dirSyncRec;
    Check(DirRec.fileCount(False) = 2,
      'raw right-side child count omitted a mask-filtered file');
    SyncFlat(Flat, [sfDeleteRight]);
    Check(not FileExists(RightRoot + 'guard/visible.txt'),
      'visible file was not deleted');
    Check(ReadFixture(RightRoot + 'guard/hidden.bin') = 'preserve',
      'mask-filtered child was deleted');
    Check(DirectoryExists(RightRoot + 'guard'),
      'directory containing a filtered child was deleted');
  finally
    FreeComparison(Tree, Flat, Option);
  end;

  BeginFixture('unselected-child');
  WriteFixture(RightRoot + 'visible.txt', 'delete');
  WriteFixture(RightRoot + 'unselected.dat', 'preserve');
  Callbacks.SelectedExcludeName := 'unselected.dat';
  Check(BuildFlat([cfSubdirs, cfEmptyDirs, cfAsymmetric, cfOnlySelected],
    Tree, Flat, Option), 'compare unselected-child fixture');
  try
    I := FindFlatPath(Flat, 'visible.txt');
    Check(I >= 0, 'selected file missing from flat tree');
    DirIndex := Tree.indexOfDir('');
    Check((DirIndex >= 0) and (Tree.dirItem(DirIndex).dirSyncRec.fileCount(False) = 2),
      'raw child count omitted an unselected file');
    SyncFlat(Flat, [sfDeleteRight]);
    Check(not FileExists(RightRoot + 'visible.txt'),
      'selected file was not deleted');
    Check(ReadFixture(RightRoot + 'unselected.dat') = 'preserve',
      'unselected child was deleted');
  finally
    FreeComparison(Tree, Flat, Option);
  end;
end;

procedure TestLateFileAndDeleteFailure;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
  Index: Integer;
  Rec: TFileSyncRec;
begin
  BeginFixture('late-child');
  ForceDirectories(RightRoot + 'vanish/empty');
  Check(BuildFlat([cfSubdirs, cfEmptyDirs, cfAsymmetric], Tree, Flat, Option),
    'compare before late child is added');
  try
    WriteFixture(RightRoot + 'vanish/empty/late.txt', 'must survive');
    SyncFlat(Flat, [sfDeleteRight]);
    Check(ReadFixture(RightRoot + 'vanish/empty/late.txt') = 'must survive',
      'directory added after scan was deleted recursively');
  finally
    FreeComparison(Tree, Flat, Option);
  end;

  BeginFixture('delete-failure');
  WriteFixture(RightRoot + 'refuse-delete.txt', 'preserve');
  Check(BuildFlat([cfSubdirs, cfAsymmetric], Tree, Flat, Option),
    'compare before injected delete failure');
  try
    Index := FindFlatPath(Flat, 'refuse-delete.txt');
    Check(Index >= 0, 'deletion candidate missing');
    Rec := Flat.fileSyncRec(Index);
    Callbacks.FailDelete := True;
    SyncFlat(Flat, [sfDeleteRight]);
    Check(FileExists(RightRoot + 'refuse-delete.txt'),
      'injected delete failure changed filesystem');
    Check((Rec.rightFile <> nil) and (Rec.state <> srsDeleted),
      'failed deletion mutated model state');
  finally
    Callbacks.FailDelete := False;
    FreeComparison(Tree, Flat, Option);
  end;
end;

procedure TestCreationFailureAndCancellation;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
begin
  BeginFixture('create-failure');
  WriteFixture(LeftRoot + 'a-fail/file.txt', 'copy');
  WriteFixture(RightRoot + 'z-delete.txt', 'keep until successful copy');
  Check(BuildFlat([cfSubdirs, cfAsymmetric, cfEmptyDirs], Tree, Flat, Option),
    'compare before injected directory creation failure');
  try
    TestFileSystem.FailedCreatePath := RightRoot + 'a-fail';
    SyncFlat(Flat, [sfCopyToRight, sfDeleteRight]);
    Check(not FileExists(RightRoot + 'a-fail/file.txt'),
      'copy continued after destination directory creation failed');
    Check(FileExists(RightRoot + 'z-delete.txt'),
      'deletion ran after directory creation failed');
  finally
    FreeComparison(Tree, Flat, Option);
  end;

  BeginFixture('cancel-sync');
  WriteFixture(RightRoot + 'cancel-me.txt', 'unchanged');
  Check(BuildFlat([cfSubdirs, cfAsymmetric], Tree, Flat, Option),
    'compare before sync cancellation');
  try
    Callbacks.AbortSync := True;
    SyncFlat(Flat, [sfCopyToLeft, sfDeleteRight]);
    Check(not FileExists(LeftRoot + 'cancel-me.txt') and
      FileExists(RightRoot + 'cancel-me.txt'),
      'cancellation before first operation mutated fixtures');
  finally
    Callbacks.AbortSync := False;
    FreeComparison(Tree, Flat, Option);
  end;
end;

procedure TestSkippedCopyStopsDeletion;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
  Response: TFileSourceOperationUIAnswer;
begin
  for Response in [fsourSkip, fsourSkipAll] do
  begin
    BeginFixture('skipped-copy-' + IntToStr(Ord(Response)));
    WriteFixture(LeftRoot + 'copy.txt', 'not copied');
    WriteFixture(RightRoot + 'delete.txt', 'must survive');
    Check(BuildFlat([cfSubdirs, cfAsymmetric], Tree, Flat, Option),
      'compare before skipped-copy test');
    try
      TestFileSystem.FailCopy := True;
      OperationUI.Response := Response;
      SyncFlat(Flat, [sfCopyToRight, sfDeleteRight]);
      Check(OperationUI.Asked, 'injected copy error was not exercised');
      Check(not FileExists(RightRoot + 'copy.txt'), 'failed copy unexpectedly succeeded');
      Check(FileExists(RightRoot + 'delete.txt'), 'deletion continued after a skipped copy');
    finally
      FreeComparison(Tree, Flat, Option);
    end;
  end;
end;

procedure TestBuildFailuresAndSymlinks;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
  Sorter: TSyncDirsSortService;
  Builder: TSyncDirsTreeBuilder;
begin
  BeginFixture('failed-list');
  WriteFixture(LeftRoot + 'partial-data', 'partial');
  TestFileSystem.FailedListPath := LeftRoot;
  BuildTree([cfSubdirs], Tree, Option, Sorter, Builder);
  try
    Check(not Builder.build(Tree), 'partial failed listing reported success');
    Check((Tree.Count = 0) and (Builder.lastError <> ''),
      'failed listing left an actionable partial tree');
  finally
    Builder.Free;
    Sorter.Free;
    Option.Free;
    Tree.Free;
  end;

  BeginFixture('missing-root');
  RemoveDir(LeftRoot);
  BuildTree([cfSubdirs], Tree, Option, Sorter, Builder);
  try
    Check(not Builder.build(Tree), 'missing root reported successful scan');
    Check(Tree.Count = 0, 'missing root produced an actionable tree');
  finally
    Builder.Free;
    Sorter.Free;
    Option.Free;
    Tree.Free;
  end;

  BeginFixture('unreadable-child');
  ForceDirectories(LeftRoot + 'denied');
  ForceDirectories(RightRoot + 'denied');
  TestFileSystem.FailedListPath := LeftRoot + 'denied';
  BuildTree([cfSubdirs], Tree, Option, Sorter, Builder);
  try
    Check(not Builder.build(Tree), 'failed child listing reported success');
    Check(Tree.Count = 0, 'failed child listing left actionable partial data');
  finally
    Builder.Free;
    Sorter.Free;
    Option.Free;
    Tree.Free;
  end;

  BeginFixture('symlink');
  WriteFixture(OutsideRoot + 'outside.txt', 'outside');
  ForceDirectories(LeftRoot + 'inside');
  WriteFixture(LeftRoot + 'inside/real.txt', 'inside');
  Check(fpSymlink(PChar(OutsideRoot), PChar(LeftRoot + 'outside-link')) = 0,
    'create outside symlink');
  Check(fpSymlink(PChar(LeftRoot), PChar(LeftRoot + 'inside/cycle')) = 0,
    'create cyclic symlink');
  Check(BuildFlat([cfSubdirs], Tree, Flat, Option), 'compare symlink fixture');
  try
    Check(FindFlatPath(Flat, 'outside-link/outside.txt') < 0,
      'scanner traversed symlink outside the comparison root');
    Check(FindFlatPath(Flat, 'inside/cycle/inside/real.txt') < 0,
      'scanner followed a cyclic directory symlink');
  finally
    FreeComparison(Tree, Flat, Option);
  end;
end;

procedure TestHierarchyAndSorting;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
  Index, I, DirIndex: Integer;
  Indexes: TIntegerList;
  DirItem: TTwoLevelTreeDirItem;
  SavedOrder: TStringList;
  Sorter: TSyncDirsSortService;
  SortColumns: array[0..5] of Integer = (0, 1, 2, 4, 5, 6);
begin
  BeginFixture('hierarchy');
  WriteFixture(LeftRoot + 'a/b/child.txt', 'left');
  WriteFixture(LeftRoot + 'a/both-side.txt', 'left');
  WriteFixture(LeftRoot + 'left-only.txt', 'left');
  WriteFixture(RightRoot + 'right-only.txt', 'right');
  WriteFixture(RightRoot + 'a-/sibling.txt', 'right');
  WriteFixture(LeftRoot + 'other.txt', 'intervening sibling');
  WriteFixture(RightRoot + 'other.txt', 'intervening sibling');
  Check(BuildFlat([cfSubdirs, cfEmptyDirs], Tree, Flat, Option),
    'compare hierarchy fixture');
  try
    Index := FindFlatPath(Flat, 'a/b/child.txt');
    Check(Index >= 0, 'nested action target missing');
    Indexes := TIntegerList.Create;
    try
      Indexes.Add(Index);
      Flat.setNewAction(Indexes, srsCopyToRight);
      DirIndex := Tree.indexOfDir('a');
      Check((DirIndex >= 0) and
        (Tree.dirItem(DirIndex).dirSyncRec.action = srsCopyToRight),
        'child copy action did not propagate to exact ancestor');
      DirIndex := Tree.indexOfDir('a-');
      Check((DirIndex >= 0) and
        (Tree.dirItem(DirIndex).dirSyncRec.action <> srsCopyToRight),
        'action leaked to a sibling sharing the ancestor prefix');
    finally
      Indexes.Free;
    end;
    DirIndex := Tree.indexOfDir('');
    DirItem := Tree.dirItem(DirIndex);
    Sorter := TSyncDirsSortService.Create;
    try
    for I := Low(SortColumns) to High(SortColumns) do
      begin
        Sorter.sortIndex := SortColumns[I];
        Sorter.sortDesc := False;
        Sorter.sortDirItem(DirItem);
        Check(DirItem.fileCount > 0, 'ascending sort lost entries');
        Sorter.sortDesc := True;
        Sorter.sortDirItem(DirItem);
        Check(DirItem.fileCount > 0, 'descending sort lost entries');
      end;
      Sorter.sortIndex := 0;
      Sorter.sortDesc := False;
      Sorter.sortDirItem(DirItem);
      Check(DirItem.files[0] = 'left-only.txt',
        'ascending name sort is incorrect');
      Sorter.sortDesc := True;
      Sorter.sortDirItem(DirItem);
      Check(DirItem.files[DirItem.fileCount - 1] = 'left-only.txt',
        'descending name sort is incorrect');
    finally
      Sorter.Free;
    end;
    SavedOrder := TStringList.Create;
    try
      for I := 0 to DirItem.fileCount - 1 do
        SavedOrder.Add(DirItem.files[I]);
      Check(SavedOrder.IndexOf('other.txt') >= 0,
        'sorting lost a two-sided entry');
    finally
      SavedOrder.Free;
    end;
  finally
    FreeComparison(Tree, Flat, Option);
  end;
end;

procedure TestClearChildAndLegacyDirectoryHeader;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
  ParentIndex, ChildIndex, SiblingIndex: Integer;
  Indexes: TIntegerList;
  Rec: TFileSyncRec;
begin
  BeginFixture('clear-child');
  WriteFixture(RightRoot + 'a/b-child.txt', 'delete');
  WriteFixture(RightRoot + 'a-/sibling.txt', 'keep');
  WriteFixture(RightRoot + 'other.txt', 'keep');
  Check(BuildFlat([cfSubdirs, cfEmptyDirs, cfAsymmetric], Tree, Flat, Option),
    'compare child deletion fixture');
  try
    ParentIndex := FindFlatPath(Flat, 'a/');
    ChildIndex := FindFlatPath(Flat, 'a/b-child.txt');
    SiblingIndex := FindFlatPath(Flat, 'a-/sibling.txt');
    Check((ParentIndex >= 0) and (ChildIndex >= 0) and (SiblingIndex >= 0),
      'directory, child, or sibling row missing');
    Indexes := TIntegerList.Create;
    try
      Indexes.Add(ParentIndex);
      Flat.setNewAction(Indexes, srsDeleteRight);
      Check(Flat.fileSyncRec(ChildIndex).action = srsDeleteRight,
        'directory delete did not cascade to child');
      Indexes.Clear;
      Indexes.Add(ChildIndex);
      Flat.setNewAction(Indexes, srsDoNothing);
      Check(Flat.fileSyncRec(ParentIndex).action = srsDoNothing,
        'clearing child deletion did not cancel ancestor action');
      Check(Flat.fileSyncRec(SiblingIndex).action = srsDeleteRight,
        'clearing child action leaked to sibling-prefix directory');
    finally
      Indexes.Free;
    end;
  finally
    FreeComparison(Tree, Flat, Option);
  end;

  BeginFixture('legacy-dir-header');
  WriteFixture(LeftRoot + 'context/selected.txt', 'left');
  WriteFixture(RightRoot + 'context/selected.txt', 'right');
  Check(BuildFlat([cfSubdirs], Tree, Flat, Option),
    'compare directory header without empty-directory support');
  try
    ParentIndex := FindFlatPath(Flat, 'context/');
    ChildIndex := FindFlatPath(Flat, 'context/selected.txt');
    Check((ParentIndex >= 0) and (ChildIndex >= 0),
      'legacy directory header or child row missing');
    Rec := Flat.fileSyncRec(ChildIndex);
    Indexes := TIntegerList.Create;
    try
      Indexes.Add(ParentIndex);
      Flat.setNewAction(Indexes, srsCopyToRight);
      Check(Rec.action = srsCopyToRight,
        'directory header action no longer applies to displayed child files');
    finally
      Indexes.Free;
    end;
  finally
    FreeComparison(Tree, Flat, Option);
  end;
end;

procedure TestSameAddressSourceComparison;
var
  SameSource, SeparateSource: IFileSource;
begin
  BeginFixture('source-identity');
  SameSource := FileSystem;
  SeparateSource := TTestFileSystem.Create as IFileSource;
  Check(isCompatibleFileSourceForCopyOperation(SameSource, SameSource),
    'same source instance/address was not considered compatible');
  Check(TSyncDirsUtil.supportsSyncDirs(SameSource, SameSource),
    'same-source listing/copy consultation was rejected');
  Check(not isCompatibleFileSourceForCopyOperation(SameSource, SeparateSource),
    'different source instances with the same address were treated as one source');
  SeparateSource := nil;
  SameSource := nil;
end;

procedure SynchronizeSources(const LeftSource, RightSource: IFileSource;
  const LeftPath, RightPath: String; const Flags: TSyncDirsSyncFlags);
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
  Sorter: TSyncDirsSortService;
  Builder: TSyncDirsTreeBuilder;
  Synchronizer: TSyncDirsSynchronizer;
  CompareFlags: TSyncDirsCompareFlags;
begin
  CompareFlags := [cfSubdirs, cfEmptyDirs, cfIgnoreDate];
  if sfDeleteRight in Flags then Include(CompareFlags, cfAsymmetric);
  BuildTree(CompareFlags, Tree, Option, Sorter, Builder);
  Flat := TFlatDirFileList.Create;
  Synchronizer := TSyncDirsSynchronizer.Create(Callbacks, Callbacks, Flat);
  try
    Builder.fileSourceL := LeftSource;
    Builder.fileSourceR := RightSource;
    Builder.baseDirL := LeftPath;
    Builder.baseDirR := RightPath;
    Check(Builder.build(Tree), 'special-source comparison failed: ' + Builder.lastError);
    Tree.filterFlatListWithFlags(Flat,
      [ffCopyRight, ffCopyLeft, ffEqual, ffNotEqual, ffUnknown, ffDuplicate, ffSingle]);
    Synchronizer.leftFS := LeftSource;
    Synchronizer.rightFS := RightSource;
    Synchronizer.leftBasePath := LeftPath;
    Synchronizer.rightBasePath := RightPath;
    Synchronizer.sync(Flags);
  finally
    Synchronizer.Free;
    Builder.Free;
    Sorter.Free;
    FreeComparison(Tree, Flat, Option);
  end;
end;

procedure TestGioLocalFileSource;
var
  GioSource: IFileSource;
begin
  BeginFixture('gio-local');
  WriteFixture(RightRoot + 'payload/data.txt', 'GIO copy');
  WriteFixture(RightRoot + 'empty-file.txt', '');
  ForceDirectories(RightRoot + 'empty-dir');
  GioSource := TGioFileSource.Create(ParseURI('file:///')) as IFileSource;
  try
    SynchronizeSources(FileSystem, GioSource, LeftRoot, RightRoot, [sfCopyToLeft]);
    Check(ReadFixture(LeftRoot + 'payload/data.txt') = 'GIO copy',
      'GIO synchronization lost file contents');
    Check(FileExists(LeftRoot + 'empty-file.txt') and
      (ReadFixture(LeftRoot + 'empty-file.txt') = ''), 'GIO synchronization lost empty file');
    Check(DirectoryExists(LeftRoot + 'empty-dir'), 'GIO synchronization lost empty directory');
    WriteFixture(LeftRoot + 'reverse.txt', 'copy to GIO');
    ForceDirectories(LeftRoot + 'reverse-empty/deep');
    SynchronizeSources(FileSystem, GioSource, LeftRoot, RightRoot, [sfCopyToRight]);
    Check(ReadFixture(RightRoot + 'reverse.txt') = 'copy to GIO', 'filesystem-to-GIO copy');
    Check(DirectoryExists(RightRoot + 'reverse-empty/deep'), 'filesystem-to-GIO empty dirs');
    ForceDirectories(RightRoot + 'delete-empty/leaf');
    SynchronizeSources(FileSystem, GioSource, LeftRoot, RightRoot, [sfDeleteRight]);
    Check(not DirectoryExists(RightRoot + 'delete-empty'), 'nonrecursive GIO directory removal');
    ForceDirectories(RightRoot + 'uri-empty');
    Check(TSyncDirsUtil.deleteEmptyDirectory(GioSource,
      GioSource.CurrentAddress + RightRoot + 'uri-empty'), 'GIO URI directory removal');
    Check(not DirectoryExists(RightRoot + 'uri-empty'), 'GIO URI directory still exists');
  finally
    GioSource := nil;
  end;
end;

procedure TestOptionalWcxArchiveSource;
var
  PluginPath, ArchivePath: String;
  Module: TWCXModule;
  ArchiveSource: IFileSource;
  Files: TFiles;
begin
  PluginPath := GetEnvironmentVariable('ICH119_ZIP_PLUGIN');
  ArchivePath := GetEnvironmentVariable('ICH119_ZIP_ARCHIVE');
  if (PluginPath = '') or (ArchivePath = '') then
  begin
    WriteLn('SKIP: WCX archive test needs ICH119_ZIP_PLUGIN and ICH119_ZIP_ARCHIVE');
    Exit;
  end;

  BeginFixture('wcx-archive');
  Check(FileExists(PluginPath) and FileExists(ArchivePath),
    'configured WCX plugin or archive does not exist');
  Module := gWCXPlugins.LoadModule(PluginPath);
  Check(Assigned(Module), 'load configured WCX plugin');
  ArchiveSource := TWcxArchiveFileSource.Create(FileSystem, ArchivePath,
    PluginPath, Module.GetPluginCapabilities) as IFileSource;
  WriteFixture(LeftRoot + 'stage/data.txt', 'WCX copy-in');
  ForceDirectories(LeftRoot + 'stage/empty-dir');
  try
    SynchronizeSources(FileSystem, ArchiveSource, LeftRoot + 'stage/',
      ArchiveSource.GetRootDir, [sfCopyToRight]);
    Files := TFiles.Create(LeftRoot + 'stage/');
    try
      Files.Add(TFileSystemFileSource.CreateFileFromFile(LeftRoot + 'stage/data.txt'));
      Check(Callbacks.fileProcessorWithUICopyFiles(FileSystem, ArchiveSource, Files,
        ArchiveSource.GetRootDir + 'auto-parent/'), 'WCX missing-parent CopyIn fallback');
    finally
      Files.Free;
    end;
    SynchronizeSources(FileSystem, ArchiveSource, RightRoot,
      ArchiveSource.GetRootDir, [sfCopyToLeft]);
  finally
    ArchiveSource := nil;
  end;
  Check(ReadFixture(RightRoot + 'data.txt') = 'WCX copy-in',
    'WCX archive copy omitted data file');
  Check(DirectoryExists(RightRoot + 'empty-dir'),
    'WCX archive copy omitted empty directory');
  Check(ReadFixture(RightRoot + 'auto-parent/data.txt') = 'WCX copy-in',
    'WCX directory-creation fallback omitted data');
end;

procedure TestAbortedScan;
var
  Tree: TTwoLevelTree;
  Flat: TFlatDirFileList;
  Option: TSyncDirsCompareOption;
begin
  BeginFixture('aborted-scan');
  WriteFixture(LeftRoot + 'partial.txt', 'data');
  Callbacks.AbortScan := True;
  Check(not BuildFlat([cfSubdirs], Tree, Flat, Option),
    'aborted scan reported success');
  Check((Tree.Count = 0) and (Flat.Count = 0),
    'aborted scan left an actionable partial tree');
  FreeComparison(Tree, Flat, Option);
end;

procedure TestNativeListingStaleErrno;
{$IFDEF LINUX}
var
  Search: TSearchRecEx;
  Status: Integer;
{$ENDIF}
begin
  {$IFDEF LINUX}
  BeginFixture('listing-stale-errno');
  WriteFixture(RightRoot + 'file.txt', 'data');
  fpSetCerrno(ESysENOENT);
  Status := FindFirstEx(RightRoot + '*', 0, Search);
  try
    Check(Status = 0, 'directory listing did not begin');
    while Status = 0 do
    begin
      fpSetCerrno(ESysENOENT);
      Status := FindNextEx(Search);
    end;
    Check(Status = -1, 'stale libc errno was reported as a directory listing failure');
  finally
    FindCloseEx(Search);
  end;
  {$ENDIF}
end;

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
  if Fixture <> '' then
  begin
    DeleteFile(LeftRoot + 'outside-link');
    DeleteFile(LeftRoot + 'inside/cycle');
    DeleteDirectory(Fixture, False);
    Fixture := '';
  end;
end;

begin
  WriteLn('START: sync directories regression');
  if (ParamCount <> 1) or (Copy(ParamStr(1), 1, 13) <> '--config-dir=') or
     (Length(ParamStr(1)) <= 13) then
    raise Exception.Create('Usage: syncdirs_regression --config-dir=<scratch-directory>');
  Scratch := IncludeTrailingPathDelimiter(ExpandFileName(Copy(ParamStr(1), 14, MaxInt)));
  Check(DirectoryExists(Scratch), 'scratch directory must already exist');
  Application.Initialize;
  Application.CaptureExceptions := False;
  gpCfgDir := Scratch;
  gpCmdLineCfgDir := Scratch;
  gpGlobalCfgDir := Scratch;
  gpCacheDir := Scratch + 'cache';
  gpThumbCacheDir := Scratch + 'thumbnails';
  LoadWindowsSpecialDir;
  Check(InitGlobs, 'initialize isolated test configuration');
  InitPasswordStore;
  LoadPixMapManager;
  gListFilesInThread := False;
  gWatchDirs := [];
  gUseTrash := False;
  TestFileSystem := TTestFileSystem.Create;
  FileSystem := TestFileSystem as IFileSource;
  Callbacks := TSyncDirsCallbacks.Create;
  OperationUI := TTestOperationUI.Create;
  try
    RunCheck('nested copies and timestamp direction',
      @TestBidirectionalCopy);
    RunCheck('asymmetric newer-right replacement and right-only delete',
      @TestAsymmetricNewerRightAndDelete);
    RunCheck('empty directory count and byte preview',
      @TestEmptyDirectoriesAndCounts);
    RunCheck('filtered and unselected descendants protect live directories',
      @TestFilteredAndUnselectedChildrenProtectDirectory);
    RunCheck('late files and failed delete preserve data/model',
      @TestLateFileAndDeleteFailure);
    RunCheck('directory creation failure and pre-op cancellation stop safely',
      @TestCreationFailureAndCancellation);
    RunCheck('Skip and SkipAll stop before subsequent deletions',
      @TestSkippedCopyStopsDeletion);
    RunCheck('failed listing, missing root and symlinks',
      @TestBuildFailuresAndSymlinks);
    RunCheck('hierarchy propagation and missing-side sorting',
      @TestHierarchyAndSorting);
    RunCheck('child clear propagation and legacy directory-header scope',
      @TestClearChildAndLegacyDirectoryHeader);
    RunCheck('same-address file-source identity routing',
      @TestSameAddressSourceComparison);
    RunCheck('real GIO local URI backend copy',
      @TestGioLocalFileSource);
    RunCheck('optional WCX archive source copy-in',
      @TestOptionalWcxArchiveSource);
    RunCheck('aborted scan discards partial tree', @TestAbortedScan);
    RunCheck('native listing ignores stale libc errno', @TestNativeListingStaleErrno);
  finally
    OperationUI.Free;
    Callbacks.Free;
    FileSystem := nil;
    TestFileSystem := nil;
  end;
  if Failures > 0 then Halt(1);
  WriteLn('PASS: sync directories regression checks');
end.
