unit uSyncDirsService;

{$mode ObjFPC}{$H+}
{$interfaces CORBA}
{$modeswitch nestedprocvars}

interface

uses
  Classes, SysUtils, SysConst, syncobjs, IntegerList,
  LazFileUtils, {$IFDEF UNIX}BaseUnix,{$ENDIF}
  DCStrUtils, DCOSUtils, DCClassesUtf8, uDCUtils,
  uDebug, uGlobs,
  uFile, uFileSource, uFileSourceManager, uFileSourceUtil,
  uFileSourceProperty, uFileSourceOperation, uFileSourceListOperation, uFileSourceCopyOperation, uFileSourceOperationTypes,
  uSyncDirsModel;

const
  SYNC_REC_STATE_SYMBOL: array[TSyncRecState] of String = (
    '?',
    '=',
    '!=',
    '<-',
    '->',
    'X_',
    '_X',
    'XX',
    '',

    'ERR(NextAction)',
    'ERR(NoAction)',
    'ERR(DEL)'
  );

type

  { TSyncDirsOperationHandle }

  TSyncDirsOperationHandle = procedure ( const operation: TFileSourceOperation; const state: TFileSourceOperationState ) is nested;

  { TSyncDirsUtil }

  TSyncDirsUtil = class
  public
    class function consultCopyOperation(var params: TFileSourceConsultParams): Boolean;
    class function consultAndConfirmCopyOperation(var params: TFileSourceConsultParams): Boolean;
    class function supportsSyncDirs(const sourceFS: IFileSource; const targetFS: IFileSource): Boolean;
    class function listDirectory(const fs: IFileSource; const path: String;
      out files: TFiles): Boolean;
    class function isLiveDirectoryEmpty(const fs: IFileSource; const path: String;
      out isEmpty: Boolean): Boolean;
    class function deleteEmptyDirectory(const fs: IFileSource; const path: String): Boolean;
    class function createDirectory(const fs: IFileSource; const path: String;
      const operationHandle: TSyncDirsOperationHandle): Boolean;
  public
    class function selectionToStringList(
      const filteredList: TFlatDirFileList;
      const indexes: TIntegerList;
      const option: TSyncDirsCompareOption ): TStringList;
  public
    class function copyFiles(
      const sourceFS: IFileSource;
      const targetFS: IFileSource;
      var files: TFiles;
      const targetPath: String;
      const operationHandle: TSyncDirsOperationHandle ): Boolean;
    class function deleteFiles(
      const fs: IFileSource;
      var files: TFiles;
      const operationHandle: TSyncDirsOperationHandle ): Boolean;
  end;

  { ISyncDirsFileProcessorWithUI }

  ISyncDirsFileProcessorWithUI = interface
    function fileProcessorWithUICopyFiles(
      const sourceFS: IFileSource;
      const targetFS: IFileSource;
      var files: TFiles;
      const targetPath: String): Boolean;
    function fileProcessorWithUIDeleteFiles(
      const fs: IFileSource;
      var files: TFiles): Boolean;
    function fileProcessorWithUIDeleteFile(
      const fs: IFileSource;
      const f: TFile): Boolean;
  end;

  { TSyncDirsSortService }

  TSyncDirsSortService = class
  private
    _sortIndex: Integer;
    _sortDesc: Boolean;
  public
    procedure sortTree( const tree: TTwoLevelTree );
    procedure sortDirItem( const dirItem: TTwoLevelTreeDirItem );

    property sortIndex: Integer write _sortIndex;
    property sortDesc: Boolean write _sortDesc;
  end;

  { TSyncDirsDeleteService }

  TSyncDirsDeleteService = class
  private
    _fileProcessor: ISyncDirsFileProcessorWithUI;
    _filteredList: TFlatDirFileList;
    _leftFS: IFileSource;
    _rightFS: IFileSource;
  public
    constructor Create( const fileProcessor: ISyncDirsFileProcessorWithUI; const filteredList: TFlatDirFileList );
    procedure delete( const indexes: TIntegerList; const deleteLeft: Boolean; const deleteRight: Boolean );

    property leftFS: IFileSource write _leftFS;
    property rightFS: IFileSource write _rightFS;
  end;

  { ISyncDirsTreeBuilderCallback }

  ISyncDirsTreeBuilderCallback = interface
    function treeBuilderCheckRunning( const processMessages: Boolean ): Boolean;
    function treeBuilderMaskFilt( const f: TFile ): Boolean;
    function treeBuilderSelectedFilt( const filename: String ): Boolean;
    procedure onTreeBuilderUpdateProgress( const percent: Integer );
  end;

  { TSyncDirsTreeBuilder }

  TSyncDirsTreeBuilder = class
  private
    _callback: ISyncDirsTreeBuilderCallback;
    _sortedService: TSyncDirsSortService;
    _compareOption: TSyncDirsCompareOption;
    _baseDirL: String;
    _baseDirR: String;
    _fileSourceL: IFileSource;
    _fileSourceR: IFileSource;
    _leftFirst: Boolean;
    _rightFirst: Boolean;
    _lastError: String;
  public
    constructor Create(
      const callback: ISyncDirsTreeBuilderCallback;
      const sortService: TSyncDirsSortService;
      const compareOption: TSyncDirsCompareOption );
    function build( const FFullTree: TTwoLevelTree ): Boolean;

    property baseDirL: String write _baseDirL;
    property baseDirR: String write _baseDirR;
    property fileSourceL: IFileSource write _fileSourceL;
    property fileSourceR: IFileSource write _fileSourceR;
    property lastError: String read _lastError;
  end;

  { ISyncDirsSynchronizerCallback }

  ISyncDirsSynchronizerCallback = interface
    function synchronizerCheckRunning: Boolean;
  end;

  { TSyncDirsSynchronizer }

  TSyncDirsSynchronizer = class
  private
    _callback: ISyncDirsSynchronizerCallback;
    _fileProcessor: ISyncDirsFileProcessorWithUI;
    _filteredList: TFlatDirFileList;
    _leftFS: IFileSource;
    _rightFS: IFileSource;
    _leftBasePath: String;
    _rightBasePath: String;
  public
    constructor Create(
      const callback: ISyncDirsSynchronizerCallback;
      const fileProcessor: ISyncDirsFileProcessorWithUI;
      const filteredList: TFlatDirFileList );
    function count: TSyncDirsSyncCount;
    procedure sync( const syncFlags: TSyncDirsSyncFlags );

    property leftFS: IFileSource write _leftFS;
    property rightFS: IFileSource write _rightFS;
    property leftBasePath: String write _leftBasePath;
    property rightBasePath: String write _rightBasePath;
  end;

  { ISyncDirsCheckContentThreadCallback }

  ISyncDirsCheckContentThreadCallback = interface
    procedure onCheckContentThreadStart;
    procedure onCheckContentThreadFinish;
    procedure onCheckContentThreadReapplyFilter;
    procedure onCheckContentThreadCountUpdated( const equalInc: Integer; const notEqInc: Integer );
  end;

  { TSyncDirsCheckContentThread }

  TSyncDirsCheckContentThread = class( TThread )
  private
    _fullTree: TTwoLevelTree;
    _callback: ISyncDirsCheckContentThreadCallback;
    _done: Boolean;
    _mutex: TCriticalSection;
    _statistics: TFileSourceCopyOperationStatistics;
  protected
    procedure Execute; override;
    procedure UpdateStatistics(var NewStatistics: TFileSourceCopyOperationStatistics);
  public
    constructor Create(const fullTree: TTwoLevelTree; const callback: ISyncDirsCheckContentThreadCallback);
    destructor Destroy; override;
    function RetrieveStatistics: TFileSourceCopyOperationStatistics;
    property Done: Boolean read _done;
  end;

implementation

uses
  FileUtil, uFileProcs, uOSUtils, uFileSystemFileSource, uAdministrator,
  uWfxPluginFileSource, uShowMsg, uLng
  {$IFDEF UNIX}
  , uGioFileSource, uGio, uGio2, uGLib2, uGObject2, uGioFileSourceUtil
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  , uShellFileSource
  {$ENDIF};

{ TSyncDirsUtil }

class function TSyncDirsUtil.consultCopyOperation( var params: TFileSourceConsultParams ): Boolean;
begin
  Result:= False;
  params.operationType:= fsoCopy;
  FileSourceManager.consultOperation(params);
  if params.consultResult <> fscrSuccess then
    Exit;
  if params.operationTemp then
    Exit;
  Result:= True;
end;

class function TSyncDirsUtil.consultAndConfirmCopyOperation( var params: TFileSourceConsultParams ): Boolean;
begin
  Result:= False;
  if consultCopyOperation(params) then
    FileSourceManager.confirmOperation(params);
  if params.consultResult <> fscrSuccess then
    Exit;
  if params.operationTemp then
    Exit;
  Result:= True;
end;

class function TSyncDirsUtil.supportsSyncDirs(
  const sourceFS: IFileSource;
  const targetFS: IFileSource): Boolean;
var
  params: TFileSourceConsultParams;
begin
  Result:= False;
  if sourceFS.IsClass(TWfxPluginFileSource) or targetFS.IsClass(TWfxPluginFileSource) then
    Exit;
  {$IFDEF MSWINDOWS}
  if sourceFS.IsClass(TShellFileSource) or targetFS.IsClass(TShellFileSource) then
    Exit;
  {$ENDIF}
  if not (fsoList in sourceFS.GetOperationsTypes) or
     not (fsoList in targetFS.GetOperationsTypes) then
    Exit;
  params:= Default(TFileSourceConsultParams);
  params.sourceFS:= sourceFS;
  params.targetFS:= targetFS;
  Result:= consultCopyOperation(params) and Assigned(params.resultFS);
  if not Result then
    Exit;
  params:= Default(TFileSourceConsultParams);
  params.sourceFS:= targetFS;
  params.targetFS:= sourceFS;
  Result:= consultCopyOperation(params) and Assigned(params.resultFS);
end;

class function TSyncDirsUtil.listDirectory(const fs: IFileSource;
  const path: String; out files: TFiles): Boolean;
var
  operation: TFileSourceOperation;
  listOperation: TFileSourceListOperation;
  listPath: String;
begin
  files:= nil;
  Result:= False;
  if fs.IsClass(TWfxPluginFileSource) then
    Exit;
  {$IFDEF MSWINDOWS}
  if fs.IsClass(TShellFileSource) then
    Exit;
  {$ENDIF}
  {$IFDEF UNIX}
  if fspDirectAccess in fs.Properties then
    if fpAccess(PChar(fs.GetRealPath(path)), R_OK or X_OK) <> 0 then
      Exit;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if fspDirectAccess in fs.Properties then
    if not mbFileAccess(fs.GetRealPath(path), fmOpenRead) then
      Exit;
  {$ENDIF}
  listPath:= path;
  {$IFDEF UNIX}
  if fs.IsClass(TGioFileSource) and StrBegins(listPath, fs.CurrentAddress) then
    Delete(listPath, 1, Length(fs.CurrentAddress));
  {$ENDIF}
  operation:= fs.CreateListOperation(listPath);
  if not Assigned(operation) then
    Exit;
  try
    if not (operation is TFileSourceListOperation) then
      Exit;
    listOperation:= TFileSourceListOperation(operation);
    listOperation.Execute;
    if listOperation.Result <> fsorFinished then
      Exit;
    files:= listOperation.ReleaseFiles;
    Result:= Assigned(files);
  finally
    operation.Free;
  end;
end;

class function TSyncDirsUtil.isLiveDirectoryEmpty(const fs: IFileSource;
  const path: String; out isEmpty: Boolean): Boolean;
var
  files: TFiles;
  i: Integer;
begin
  isEmpty:= False;
  Result:= listDirectory(fs, path, files);
  if not Result then
    Exit;
  try
    isEmpty:= True;
    for i:= 0 to files.Count-1 do
      if (files[i].Name <> '.') and (files[i].Name <> '..') then
      begin
        isEmpty:= False;
        Break;
      end;
  finally
    files.Free;
  end;
end;

class function TSyncDirsUtil.deleteEmptyDirectory(const fs: IFileSource;
  const path: String): Boolean;
var
  empty: Boolean;
  {$IFDEF UNIX}
  fileHandle: PGFile;
  error: PGError;
  uri: String;
  {$ENDIF}
begin
  Result:= False;
  if not isLiveDirectoryEmpty(fs, path, empty) then
    Exit;
  if not empty then
    Exit(True);
  if fs.IsClass(TFileSystemFileSource) then
    Exit(RemoveDirectoryUAC(fs.GetRealPath(path)));
  {$IFDEF UNIX}
  if fs.IsClass(TGioFileSource) then
  begin
    uri:= path;
    if not StrBegins(uri, fs.CurrentAddress) then
      uri:= fs.CurrentAddress + uri;
    fileHandle:= GioNewFile(uri);
    if not Assigned(fileHandle) then
      Exit(False);
    error:= nil;
    try
      Result:= g_file_delete(fileHandle, nil, @error);
      if Assigned(error) then
        ShowError(error);
    finally
      g_object_unref(PGObject(fileHandle));
    end;
    Exit;
  end;
  {$ENDIF}
  msgWarning(rsMsgErrNotSupported);
end;

class function TSyncDirsUtil.createDirectory(const fs: IFileSource;
  const path: String; const operationHandle: TSyncDirsOperationHandle): Boolean;
var
  dirPath,
  parentPath, tempDir, tempPath: String;
  files: TFiles;
  params: TFileSourceConsultParams;
  operation: TFileSourceOperation;
  exists: TFileSourceExistsResult;
begin
  if path = EmptyStr then
    dirPath:= fs.GetRootDir
  else
    dirPath:= path;
  Result:= fs.CreateDirectory(dirPath);
  if Result then
    Exit;
  exists:= fs.FileSystemEntryExists(dirPath, [TFileSourceExistsOption.needDir]);
  if exists = TFileSourceExistsResult.exists then
    Exit(True);

  if fs.IsPathAtRoot(dirPath) then
    Exit(False);
  parentPath:= ExcludeBackPathDelimiter(GetParentDir(dirPath));
  if (parentPath <> EmptyStr) and (parentPath <> dirPath) and
     not createDirectory(fs, parentPath, operationHandle) then
    Exit(False);

  if not (fsoCopyIn in fs.GetOperationsTypes) then
    Exit(False);
  tempDir:= GetTempName(GetTempFolderDeletableAtTheEnd, EmptyStr);
  files:= nil;
  try
    tempPath:= IncludeTrailingPathDelimiter(tempDir) + GetLastDir(dirPath);
    if not mbForceDirectory(tempPath) then
      Exit(False);
    files:= TFiles.Create(tempDir);
    files.Add(TFileSystemFileSource.CreateFileFromFile(tempPath));
    params:= Default(TFileSourceConsultParams);
    params.sourceFS:= TFileSystemFileSource.GetFileSource;
    params.targetFS:= fs;
    params.files:= files;
    params.targetPath:= parentPath;
    if not consultAndConfirmCopyOperation(params) or
       (params.resultOperationType <> fsoCopyIn) or
       not Assigned(params.resultFS) then
      Exit(False);
    try
      operation:= params.resultFS.CreateCopyInOperation(
        params.sourceFS, params.files, params.resultTargetPath);
    finally
      files:= params.files;
    end;
    if not Assigned(operation) then
      Exit(False);
    operation.AbortOnSkip:= True;
    try
      operationHandle(operation, TFileSourceOperationState.fsosStarting);
      try
        operation.Execute;
        Result:= operation.Result = fsorFinished;
      finally
        operationHandle(operation, TFileSourceOperationState.fsosStopped);
      end;
    finally
      operation.Free;
    end;
  finally
    files.Free;
    DeleteDirectory(tempDir, False);
  end;
end;

class function TSyncDirsUtil.selectionToStringList(
  const filteredList: TFlatDirFileList;
  const indexes: TIntegerList;
  const option: TSyncDirsCompareOption ): TStringList;

  procedure PrintRow(sl: TStringList; R: Integer);
  var
    s: string;
    SyncRec: TFileSyncRec;
  begin
    SyncRec := filteredList.fileSyncRec(R);
    if SyncRec.isDir then
    begin
      s := filteredList.path(R);
      if cfEmptyDirs in option.flags then begin
        if SyncRec.state <> srsDoNothing then
          s := s + #9#9#9 + SYNC_REC_STATE_SYMBOL[SyncRec.action];
      end;
    end
    else
    begin
      if Assigned(SyncRec.leftFile) then
      begin
        s := filteredList.path(R) + #9 +
             IntToStrTS(SyncRec.leftFile.Size) + #9 +
             FormatDateTime(gDateTimeFormatSync, SyncRec.leftFile.ModificationTime);
      end
      else
      begin
        s := #9#9;
      end;
      s := s + #9 + SYNC_REC_STATE_SYMBOL[SyncRec.action] + #9;
      if Assigned(SyncRec.rightFile) then
      begin
        s := s +
             FormatDateTime(gDateTimeFormatSync, SyncRec.rightFile.ModificationTime) + #9 +
             IntToStrTS(SyncRec.rightFile.Size) + #9 +
             filteredList.path(R);
      end;
    end;
    sl.Add(s);
  end;

var
  sl: TStringList;
  i: Integer;
begin
  sl:= TStringList.Create;
  for i in indexes do
    PrintRow( sl, i );
  Result:= sl;
end;

class function TSyncDirsUtil.copyFiles(
  const sourceFS: IFileSource;
  const targetFS: IFileSource;
  var files: TFiles;
  const targetPath: String;
  const operationHandle: TSyncDirsOperationHandle ): Boolean;
var
  params: TFileSourceConsultParams;
  fsOperation: TFileSourceOperation;
begin
  Result:= False;
  if (files = nil) or (files.Count = 0) then
    Exit;
  files.Path:= files[0].Path;

  params:= Default(TFileSourceConsultParams);
  params.sourceFS:= sourceFS;
  params.targetFS:= targetFS;
  params.files:= files;
  params.targetPath:= targetPath;
  Result:= TSyncDirsUtil.consultAndConfirmCopyOperation(params);
  if not Result or not Assigned(params.resultFS) then
  begin
    Result:= False;
    Exit;
  end;

  if not TSyncDirsUtil.createDirectory(targetFS,
       ExcludeBackPathDelimiter(targetPath), operationHandle) then
  begin
    Result:= False;
    Exit;
  end;

  // Determine fsOperation type
  fsOperation:= nil;
  case params.resultOperationType of
    fsoCopy:
      begin
        // Copy within the same file source.
        fsOperation := params.resultFS.CreateCopyOperation(
                         params.files,
                         params.resultTargetPath ) as TFileSourceCopyOperation;
      end;
    fsoCopyOut:
      begin
        // CopyOut to filesystem.
        fsOperation := params.resultFS.CreateCopyOutOperation(
                         targetFS,
                         params.files,
                         params.resultTargetPath) as TFileSourceCopyOperation;
      end;
    fsoCopyIn:
      begin
        // CopyIn from filesystem.
        fsOperation := params.resultFS.CreateCopyInOperation(
                         sourceFS,
                         params.files,
                         params.resultTargetPath) as TFileSourceCopyOperation;
      end;
  end;
  files:= params.files;
  Result:= Assigned(fsOperation);
  if NOT Result then
    Exit;
  fsOperation.AbortOnSkip:= True;

  try
    operationHandle( fsOperation, TFileSourceOperationState.fsosStarting );
    try
      fsOperation.Execute;
      Result := fsOperation.Result = fsorFinished;
    finally
      operationHandle( fsOperation, TFileSourceOperationState.fsosStopped );
    end;
  finally
    FreeAndNil(fsOperation);
  end;
end;

class function TSyncDirsUtil.deleteFiles(
  const fs: IFileSource;
  var files: TFiles;
  const operationHandle: TSyncDirsOperationHandle ): Boolean;
var
  fsOperation: TFileSourceOperation;
begin
  Result:= True;
  if files.Count = 0 then
    Exit;

  files.Path:= files[0].Path;
  fsOperation:= fs.CreateDeleteOperation(files);
  Result:= Assigned( fsOperation );
  if NOT Result then
    Exit;
  try
    operationHandle( fsOperation, TFileSourceOperationState.fsosStarting );
    try
      fsOperation.Execute;
      Result:= fsOperation.Result = fsorFinished;
    finally
      operationHandle( fsOperation, TFileSourceOperationState.fsosStopped );
    end;
  finally
    FreeAndNil(fsOperation);
  end;
end;

{ TSyncDirsSortService }

procedure TSyncDirsSortService.sortTree( const tree: TTwoLevelTree );
var
  i: Integer;
begin
  if _sortIndex < 0 then
    Exit;
  for i:= 0 to tree.Count-1 do
    self.sortDirItem( tree.dirItem(i) );
end;

procedure TSyncDirsSortService.sortDirItem( const dirItem: TTwoLevelTreeDirItem );

  function CompareFn(sl: TStringList; i, j: Integer): Integer;
  var
    r1, r2: TFileSyncRec;
  begin
    if _sortIndex in [1..5] then
    begin
      r1:= dirItem.fileSyncRec(i);
      r2:= dirItem.fileSyncRec(j);
    end;
    case _sortIndex of
    0:
      Result := mbCompareStr(sl[i], sl[j]);
    1:
      if (Assigned(r1.leftFile) < Assigned(r2.leftFile))
      or Assigned(r2.leftFile) and (r1.leftFile.Size < r2.leftFile.Size) then
        Result := -1
      else
      if (Assigned(r1.leftFile) > Assigned(r2.leftFile))
      or Assigned(r1.leftFile) and (r1.leftFile.Size > r2.leftFile.Size) then
        Result := 1
      else
        Result := 0;
    2:
      if (Assigned(r1.leftFile) < Assigned(r2.leftFile))
      or Assigned(r2.leftFile)
      and (r1.leftFile.ModificationTime < r2.leftFile.ModificationTime) then
        Result := -1
      else
      if (Assigned(r1.leftFile) > Assigned(r2.leftFile))
      or Assigned(r1.leftFile)
      and (r1.leftFile.ModificationTime > r2.leftFile.ModificationTime) then
        Result := 1
      else
        Result := 0;
    4:
      if (Assigned(r1.rightFile) < Assigned(r2.rightFile))
      or Assigned(r2.rightFile)
      and (r1.rightFile.ModificationTime < r2.rightFile.ModificationTime) then
        Result := -1
      else
      if (Assigned(r1.rightFile) > Assigned(r2.rightFile))
      or Assigned(r1.rightFile)
      and (r1.rightFile.ModificationTime > r2.rightFile.ModificationTime) then
        Result := 1
      else
        Result := 0;
    5:
      if (Assigned(r1.rightFile) < Assigned(r2.rightFile))
      or Assigned(r2.rightFile) and (r1.rightFile.Size < r2.rightFile.Size) then
        Result := -1
      else
      if (Assigned(r1.rightFile) > Assigned(r2.rightFile))
      or Assigned(r1.rightFile) and (r1.rightFile.Size > r2.rightFile.Size) then
        Result := 1
      else
        Result := 0;
    6:
      Result := mbCompareStr(sl[i], sl[j]);
    end;
    if _sortDesc then
      Result := -Result;
  end;

  procedure QuickSort(L, R: Integer; sl: TStringList);
  var
    Pivot, vL, vR: Integer;
  begin
    if R - L <= 1 then begin // a little bit of time saver
      if L < R then
        if CompareFn(sl, L, R) > 0 then
          sl.Exchange(L, R);
      Exit;
    end;

    vL := L;
    vR := R;

    Pivot := L + Random(R - L); // they say random is best

    while vL < vR do begin
      while (vL < Pivot) and (CompareFn(sl, vL, Pivot) <= 0) do
        Inc(vL);

      while (vR > Pivot) and (CompareFn(sl, vR, Pivot) > 0) do
        Dec(vR);

      sl.Exchange(vL, vR);

      if Pivot = vL then // swap pivot if we just hit it from one side
        Pivot := vR
      else if Pivot = vR then
        Pivot := vL;
    end;

    if Pivot - 1 >= L then
      QuickSort(L, Pivot - 1, sl);
    if Pivot + 1 <= R then
      QuickSort(Pivot + 1, R, sl);
  end;

begin
  QuickSort( 0, dirItem.fileCount-1, dirItem.files );
end;

{ TSyncDirsDeleteService }

constructor TSyncDirsDeleteService.Create(
  const fileProcessor: ISyncDirsFileProcessorWithUI;
  const filteredList: TFlatDirFileList );
begin
  _fileProcessor:= fileProcessor;
  _filteredList:= filteredList;
end;

procedure TSyncDirsDeleteService.delete(
  const indexes: TIntegerList;
  const deleteLeft: Boolean;
  const deleteRight: Boolean );
var
  leftFiles: TFiles = nil;
  rightFiles: TFiles = nil;
  leftDirs: TFiles = nil;
  rightDirs: TFiles = nil;
  i: Integer;

  function deleteDirs(const fs: IFileSource; const dirs: TFiles): Boolean;
  var
    f: TFile;
    j: Integer;
  begin
    Result:= True;
    for j:= dirs.Count-1 downto 0 do
    begin
      f:= dirs[j];
      if not TSyncDirsUtil.deleteEmptyDirectory(fs, f.FullPath) then
        Exit(False);
    end;
  end;
begin
  try
    if deleteLeft then
    begin
      leftFiles:= TFiles.Create(EmptyStr);
      leftDirs:= TFiles.Create(EmptyStr);
    end;
    if deleteRight then
    begin
      rightFiles:= TFiles.Create(EmptyStr);
      rightDirs:= TFiles.Create(EmptyStr);
    end;

    for i:= 0 to indexes.Count-1 do
    begin
      if _filteredList.fileSyncRec(indexes[i]).isDir then
      begin
        if Assigned(leftDirs) and Assigned(_filteredList.fileSyncRec(indexes[i]).leftFile) then
          leftDirs.Add(_filteredList.fileSyncRec(indexes[i]).leftFile.Clone);
        if Assigned(rightDirs) and Assigned(_filteredList.fileSyncRec(indexes[i]).rightFile) then
          rightDirs.Add(_filteredList.fileSyncRec(indexes[i]).rightFile.Clone);
      end
      else
      begin
        if Assigned(leftFiles) and Assigned(_filteredList.fileSyncRec(indexes[i]).leftFile) then
          leftFiles.Add(_filteredList.fileSyncRec(indexes[i]).leftFile.Clone);
        if Assigned(rightFiles) and Assigned(_filteredList.fileSyncRec(indexes[i]).rightFile) then
          rightFiles.Add(_filteredList.fileSyncRec(indexes[i]).rightFile.Clone);
      end;
    end;

    if deleteLeft and (leftFiles.Count > 0) and
       not _fileProcessor.fileProcessorWithUIDeleteFiles(_leftFS, leftFiles) then
      Exit;
    if deleteRight and (rightFiles.Count > 0) and
       not _fileProcessor.fileProcessorWithUIDeleteFiles(_rightFS, rightFiles) then
      Exit;
    if deleteLeft and not deleteDirs(_leftFS, leftDirs) then
      Exit;
    if deleteRight then
      deleteDirs(_rightFS, rightDirs);
  finally
    leftFiles.Free;
    rightFiles.Free;
    leftDirs.Free;
    rightDirs.Free;
  end;
end;

{ TSyncDirsTreeBuilder }

constructor TSyncDirsTreeBuilder.Create(
  const callback: ISyncDirsTreeBuilderCallback;
  const sortService: TSyncDirsSortService;
  const compareOption: TSyncDirsCompareOption );
begin
  _callback:= callback;
  _sortedService:= sortService;
  _compareOption:= compareOption;
  _leftFirst:= True;
  _rightFirst:= True;
end;

function TSyncDirsTreeBuilder.build(const FFullTree: TTwoLevelTree): Boolean;
  procedure ScanDir(
    dir: string;
    const leftParentDirs: TStringList;
    const rightParentDirs: TStringList);

    procedure ProcessOneSide(dirItem: TTwoLevelTreeDirItem; dirs: TStringList; var ASide: Boolean; sideLeft: Boolean);
    var
      fs: TFiles;
      i, j: Integer;
      f: TFile;
      r: TFileSyncRec;
      fn: String;
      dirFullPath: String;
      dirSyncRec: TDirSyncRec;
      currentFileSource: IFileSource;
    begin
      dirSyncRec := dirItem.dirSyncRec;
      if sideLeft then begin
        currentFileSource := _fileSourceL;
        dirFullPath := _baseDirL + dir;
        if (dir <> '') and not Assigned(dirSyncRec.leftFile) then
          Exit;
      end else begin
        currentFileSource := _fileSourceR;
        dirFullPath := _baseDirR + dir;
        if (dir <> '') and not Assigned(dirSyncRec.rightFile) then
          Exit;
      end;
      if not TSyncDirsUtil.listDirectory(currentFileSource, dirFullPath, fs) then
        raise Exception.Create('Directory listing returned no result: ' + dirFullPath);
      try
        for i := 0 to fs.Count - 1 do
        begin
          f := fs.Items[i];
          if f.Name = EmptyStr then
            f.Name := currentFileSource.GetDisplayFileName(f);
          fn := NormalizeFileName(f.Name);
          if (f.Name = '.') or (f.Name = '..') then
            continue;
          if (f.Name = EmptyStr) or (Pos('/', f.Name) > 0) or
             (Pos('\', f.Name) > 0) then
            raise Exception.Create('Unsafe file-source entry name: ' + f.Name);
          if f.IsDirectory and not f.IsLink then begin
            dirSyncRec.incDirCount(sideLeft);
            if _callback.treeBuilderMaskFilt(f) and
               (not ((cfOnlySelected in _compareOption.flags) and ASide) or
                _callback.treeBuilderSelectedFilt(f.Name)) then
            begin
              dirs.AddObject(fn, f.Clone);
            end;
          end else begin
            dirSyncRec.incFileCount(sideLeft);
            if not _callback.treeBuilderMaskFilt(f) or
               ((cfOnlySelected in _compareOption.flags) and ASide and
                not _callback.treeBuilderSelectedFilt(f.Name)) then
              continue;
            j := dirItem.indexOfFile(fn);
            if j < 0 then begin
              if dirs.IndexOf(fn) >= 0 then
                raise Exception.Create('File/directory name collision: ' + fn);
              r := TFileSyncRec.Create(_compareOption, dir);
              dirItem.addFile(fn, r);
            end else
              r := dirItem.fileSyncRec(j);
            if sideLeft then
            begin
              if Assigned(r.leftFile) then
                raise Exception.Create('Duplicate left entry: ' + fn);
              r.leftFile := f.Clone;
            end else begin
              if Assigned(r.rightFile) then
                raise Exception.Create('Duplicate right entry: ' + fn);
              r.rightFile := f.Clone;
            end;
            r.updateState;
          end;
        end;
      finally
        fs.Free;
      end;
      ASide:= False;
    end;

    procedure setDirSyncRecFile(dirSyncRec: TDirSyncRec);
    var
      i: Integer;
      currentDirPart: String;
    begin
      currentDirPart:= GetLastDir(dir);
      i:= leftParentDirs.IndexOf(currentDirPart);
      if i >= 0 then begin
        dirSyncRec.leftFile:= TFile(leftParentDirs.Objects[i]);    // owns file
        leftParentDirs.Objects[i]:= nil;
      end;
      i:= rightParentDirs.IndexOf(currentDirPart);
      if i >= 0 then begin
        dirSyncRec.rightFile:= TFile(rightParentDirs.Objects[i]);   // owns file
        rightParentDirs.Objects[i]:= nil;
      end;
    end;

  var
    i, j, tot: Integer;
    dirItem: TTwoLevelTreeDirItem;
    dirsLeft, dirsRight: TStringListEx;
    d: string;
    dirSyncRec: TDirSyncRec;
  begin
    i := FFullTree.indexOfDir(dir);
    if i < 0 then begin
      dirSyncRec := TDirSyncRec.Create(_compareOption, dir);
      dirItem := TTwoLevelTreeDirItem.Create(dirSyncRec);
      FFullTree.addDir(dir, dirItem);
    end else begin
      dirItem := FFullTree.dirItem(i);
      dirSyncRec := dirItem.dirSyncRec;
    end;

    if dir <> '' then begin
      setDirSyncRecFile(dirSyncRec);
      dir := AppendPathDelim(dir);
    end;

    dirsLeft := TStringListEx.Create;
    dirsLeft.OwnsObjects:= True;
    dirsLeft.CaseSensitive := FileNameCaseSensitive;
    dirsLeft.Sorted := True;
    dirsRight := TStringListEx.Create;
    dirsRight.OwnsObjects:= True;
    dirsRight.CaseSensitive := FileNameCaseSensitive;
    dirsRight.Sorted := True;
    try
      if NOT _callback.treeBuilderCheckRunning(True) then
        Exit;
      ProcessOneSide(dirItem, dirsLeft, _leftFirst, True);
      ProcessOneSide(dirItem, dirsRight, _rightFirst, False);
      for i:= 0 to dirsLeft.Count-1 do
        if dirItem.indexOfFile(dirsLeft[i]) >= 0 then
          raise Exception.Create('File/directory name collision: ' + dirsLeft[i]);
      for i:= 0 to dirsRight.Count-1 do
        if dirItem.indexOfFile(dirsRight[i]) >= 0 then
          raise Exception.Create('File/directory name collision: ' + dirsRight[i]);
      dirSyncRec.updateState;
      _sortedService.sortDirItem(dirItem);
      if not (cfSubdirs in _compareOption.flags) then Exit;
      tot := dirsLeft.Count + dirsRight.Count;
      for i := 0 to dirsLeft.Count - 1 do
      begin
        if dir = '' then
          _callback.onTreeBuilderUpdateProgress( i * 100 div tot );
        d := dirsLeft[i];
        ScanDir(dir + d, dirsLeft, dirsRight);
        if  NOT _callback.treeBuilderCheckRunning(False) then
          Exit;
        j := dirsRight.IndexOf(d);
        if j >= 0 then
        begin
          dirsRight.Delete(j);
          Dec(tot);
        end
      end;
      for i := 0 to dirsRight.Count - 1 do
      begin
        if dir = '' then
          _callback.onTreeBuilderUpdateProgress( (dirsLeft.Count + i) * 100 div tot );
        d := dirsRight[i];
        ScanDir(dir + d, dirsLeft, dirsRight);
        if  NOT _callback.treeBuilderCheckRunning(False) then
          Exit;
      end;
    finally
      dirsLeft.Free;
      dirsRight.Free;
    end;
  end;

begin
  Result:= False;
  FFullTree.Clear;
  _lastError:= EmptyStr;
  try
    if _fileSourceL.Equals(_fileSourceR) and
       SameText(_fileSourceL.GetCurrentAddress, _fileSourceR.GetCurrentAddress) and
       ((IncludeTrailingPathDelimiter(_baseDirL) = IncludeTrailingPathDelimiter(_baseDirR)) or
        PathIsInPath(_baseDirL, _baseDirR) or PathIsInPath(_baseDirR, _baseDirL)) then
      raise Exception.Create('Comparison roots overlap');
    if (_fileSourceL.FileSystemEntryExists(_baseDirL,
        [TFileSourceExistsOption.needDir]) = TFileSourceExistsResult.notExist) or
       (_fileSourceR.FileSystemEntryExists(_baseDirR,
        [TFileSourceExistsOption.needDir]) = TFileSourceExistsResult.notExist) then
      raise Exception.Create('A comparison root does not exist or is not a directory');
    ScanDir('', nil, nil);
    if not _callback.treeBuilderCheckRunning(False) then
      raise Exception.Create('Directory comparison cancelled');
    Result:= True;
  except
    on E: Exception do
    begin
      _lastError:= E.Message;
      FFullTree.Clear;
    end;
  end;
end;

{ TSyncDirsSynchronizer }

constructor TSyncDirsSynchronizer.Create(
  const callback: ISyncDirsSynchronizerCallback;
  const fileProcessor: ISyncDirsFileProcessorWithUI;
  const filteredList: TFlatDirFileList );
begin
  _callback:= callback;
  _fileProcessor:= fileProcessor;
  _filteredList:= filteredList;
end;

function TSyncDirsSynchronizer.count: TSyncDirsSyncCount;
var
  i: Integer;
  rec: TFileSyncRec;
begin
  Result:= Default( TSyncDirsSyncCount );
  for i:= 0 to _filteredList.Count-1 do begin
    rec := _filteredList.fileSyncRec( i );
    case rec.action of
      srsCopyToLeft:
        begin
          Inc(Result.copyToLeftCount);
          if not rec.isDir then
            Inc(Result.copyToLeftSize, rec.rightFile.Size);
        end;
      srsCopyToRight:
        begin
          Inc(Result.copyToRightCount);
          if not rec.isDir then
            Inc(Result.copyToRightSize, rec.leftFile.Size);
        end;
      srsDeleteLeft:
        begin
          Inc(Result.deleteLeftCount);
        end;
      srsDeleteRight:
        begin
          Inc(Result.deleteRightCount);
        end;
      srsDeleteBoth:
        begin
          Inc(Result.deleteLeftCount);
          Inc(Result.deleteRightCount);
        end;
    end;
  end;
end;

procedure TSyncDirsSynchronizer.sync(const syncFlags: TSyncDirsSyncFlags);
var
  index: Integer;
  rec: TFileSyncRec;

  function createDir(const fs: IFileSource; const path: String): Boolean;
  var
    dirPath, parentPath, tempDir, tempPath: String;
    files: TFiles;
  begin
    if path = EmptyStr then
      dirPath:= fs.GetRootDir
    else
      dirPath:= path;
    Result:= fs.CreateDirectory(dirPath);
    if Result then
      Exit;
    if fs.FileSystemEntryExists(dirPath, [TFileSourceExistsOption.needDir]) =
       TFileSourceExistsResult.exists then
      Exit(True);
    if fs.IsPathAtRoot(dirPath) then
      Exit(False);
    parentPath:= ExcludeBackPathDelimiter(GetParentDir(dirPath));
    if (parentPath <> EmptyStr) and (parentPath <> dirPath) and
       not createDir(fs, parentPath) then
      Exit(False);
    if not (fsoCopyIn in fs.GetOperationsTypes) then
      Exit(False);
    tempDir:= GetTempName(GetTempFolderDeletableAtTheEnd, EmptyStr);
    files:= nil;
    try
    tempPath:= IncludeTrailingPathDelimiter(tempDir) + GetLastDir(dirPath);
      if not mbForceDirectory(tempPath) then
        Exit(False);
      files:= TFiles.Create(tempDir);
      files.Add(TFileSystemFileSource.CreateFileFromFile(tempPath));
      Result:= _fileProcessor.fileProcessorWithUICopyFiles(
        TFileSystemFileSource.GetFileSource, fs, files, parentPath);
    finally
      files.Free;
      DeleteDirectory(tempDir, False);
    end;
  end;

  function isEmptyLive(const fs: IFileSource; const path: String;
    out success: Boolean): Boolean;
  begin
    Result:= TSyncDirsUtil.isLiveDirectoryEmpty(fs, path, success);
  end;

  function deleteDir(const fs: IFileSource; const fileRec: TFile;
    const path: String): Boolean;
  begin
    Result:= TSyncDirsUtil.deleteEmptyDirectory(fs, path);
  end;

  function copyFile(const toLeft: Boolean; const fileRec: TFileSyncRec): Boolean;
  var
    files: TFiles;
  begin
    files:= TFiles.Create(EmptyStr);
    try
      if toLeft then
      begin
        files.Add(fileRec.rightFile.Clone);
        Result:= _fileProcessor.fileProcessorWithUICopyFiles(
          _rightFS, _leftFS, files, _leftBasePath + fileRec.relPath);
      end
      else
      begin
        files.Add(fileRec.leftFile.Clone);
        Result:= _fileProcessor.fileProcessorWithUICopyFiles(
          _leftFS, _rightFS, files, _rightBasePath + fileRec.relPath);
      end;
    finally
      files.Free;
    end;
  end;

begin
  if not _callback.synchronizerCheckRunning then
    Exit;
  { Create target directories parent-first. }
  for index:= 0 to _filteredList.Count-1 do
  begin
    rec:= _filteredList.fileSyncRec(index);
    if not rec.isDir then
      continue;
    if not _callback.synchronizerCheckRunning then
      Exit;
    case rec.action of
      srsCopyToLeft:
        if (sfCopyToLeft in syncFlags) and
           not createDir(_leftFS, _leftBasePath + rec.relPath) then Exit;
      srsCopyToRight:
        if (sfCopyToRight in syncFlags) and
           not createDir(_rightFS, _rightBasePath + rec.relPath) then Exit;
    end;
  end;
  { Copy every file before allowing any deletion. }
  for index:= 0 to _filteredList.Count-1 do
  begin
    rec:= _filteredList.fileSyncRec(index);
    if rec.isDir then
      continue;
    if not _callback.synchronizerCheckRunning then
      Exit;
    case rec.action of
      srsCopyToLeft:
        if (sfCopyToLeft in syncFlags) and not copyFile(True, rec) then Exit;
      srsCopyToRight:
        if (sfCopyToRight in syncFlags) and not copyFile(False, rec) then Exit;
    end;
  end;
  { Delete files only after all copies succeeded. }
  for index:= 0 to _filteredList.Count-1 do
  begin
    rec:= _filteredList.fileSyncRec(index);
    if rec.isDir then
      continue;
    if not _callback.synchronizerCheckRunning then
      Exit;
    case rec.action of
      srsDeleteLeft:
        if (sfDeleteLeft in syncFlags) and
           not _fileProcessor.fileProcessorWithUIDeleteFile(_leftFS, rec.leftFile) then Exit;
      srsDeleteRight:
        if (sfDeleteRight in syncFlags) and
           not _fileProcessor.fileProcessorWithUIDeleteFile(_rightFS, rec.rightFile) then Exit;
      srsDeleteBoth:
        begin
          if (sfDeleteLeft in syncFlags) and
             not _fileProcessor.fileProcessorWithUIDeleteFile(_leftFS, rec.leftFile) then Exit;
          if (sfDeleteRight in syncFlags) and
             not _fileProcessor.fileProcessorWithUIDeleteFile(_rightFS, rec.rightFile) then Exit;
        end;
    end;
  end;
  { Delete directories child-first, and only when a fresh listing is empty. }
  for index:= _filteredList.Count-1 downto 0 do
  begin
    rec:= _filteredList.fileSyncRec(index);
    if not rec.isDir then
      continue;
    if not _callback.synchronizerCheckRunning then
      Exit;
    case rec.action of
      srsDeleteLeft:
        if (sfDeleteLeft in syncFlags) and
           not deleteDir(_leftFS, rec.leftFile, _leftBasePath + rec.relPath) then Exit;
      srsDeleteRight:
        if (sfDeleteRight in syncFlags) and
           not deleteDir(_rightFS, rec.rightFile, _rightBasePath + rec.relPath) then Exit;
      srsDeleteBoth:
        begin
          if (sfDeleteLeft in syncFlags) and
             not deleteDir(_leftFS, rec.leftFile, _leftBasePath + rec.relPath) then Exit;
          if (sfDeleteRight in syncFlags) and
             not deleteDir(_rightFS, rec.rightFile, _rightBasePath + rec.relPath) then Exit;
        end;
    end;
  end;
end;

{ TSyncDirsCheckContentThread }

procedure TSyncDirsCheckContentThread.Execute;
const
  BUF_LEN = 1024 * 1024;
var
  Buffer1, Buffer2: PByte;
  Statistics: TFileSourceCopyOperationStatistics;

  function CompareFiles(const FileName1, FileName2: String; Size: Int64): Boolean;
  var
    DoneBytes, Count: Int64;
    File1, File2: TFileStreamEx;
  begin
    File1 := TFileStreamEx.Create(FileName1, fmOpenRead or fmShareDenyWrite);
    try
      File2 := TFileStreamEx.Create(FileName2, fmOpenRead or fmShareDenyWrite);
      try
        DoneBytes := 0;

        repeat
          if Size - DoneBytes <= BUF_LEN then
            Count := Size - DoneBytes
          else begin
            Count := BUF_LEN;
          end;

          File1.ReadBuffer(Buffer1^, Count);
          File2.ReadBuffer(Buffer2^, Count);

          if (Count <> BUF_LEN) then
            Result := CompareByte(Buffer1^, Buffer2^, Count) = 0
          else begin
            Result := CompareDWord(Buffer1^, Buffer2^, Count div SizeOf(Dword)) = 0;
          end;

          Statistics.DoneBytes += Count;
          DoneBytes := DoneBytes + Count;

          UpdateStatistics(Statistics);

        until Terminated or not Result or (DoneBytes >= Size);
      finally
        File2.Free;
      end;
    finally
      File1.Free;
    end;
  end;

var
  isEqual: Boolean;
  dirIndex, fileIndex: Integer;
  rec: TFileSyncRec;
begin
  Synchronize(@_callback.onCheckContentThreadStart);
  Buffer1:= GetMem(BUF_LEN);
  Buffer2:= GetMem(BUF_LEN);
  try
    if (Buffer1 = nil) or (Buffer2 = nil) then
      raise EOutOfMemory.Create(SOutOfMemory);

    with _callback do
    begin
      Statistics.DoneBytes:= 0;
      Statistics.TotalBytes:= 0;
      for dirIndex := 0 to _fullTree.Count - 1 do
      begin
        for fileIndex := 0 to _fullTree.dirItem(dirIndex).fileCount - 1 do
        begin
          if Terminated then Exit;
          rec := _fullTree.fileSyncRec(dirIndex, fileIndex);
          if NOT rec.isDir and (rec.state = srsUnknown) then
          begin
            Statistics.TotalBytes+= rec.leftFile.Size;
          end;
        end;
      end;
      UpdateStatistics(Statistics);
    end;

    with _callback do
    for dirIndex := 0 to _fullTree.Count - 1 do
    begin
      for fileIndex := 0 to _fullTree.dirItem(dirIndex).fileCount - 1 do
      begin
        if Terminated then Exit;
        rec := _fullTree.fileSyncRec(dirIndex, fileIndex);
        if NOT rec.isDir and (rec.state = srsUnknown) then
        begin
          try
            isEqual:= CompareFiles(rec.leftFile.FullPath, rec.rightFile.FullPath, rec.leftFile.Size);
            if Terminated then Exit;
            if isEqual then
            begin
              _callback.onCheckContentThreadCountUpdated( 1, -1 );
              rec.state := srsEqual
            end
            else begin
              if cfAsymmetric in rec.option.flags then begin
                rec.state := srsCopyToRight;
              end else begin
                rec.state := srsNotEq;
              end;
            end;
            if rec.action = srsUnknown then
            begin
              rec.action := rec.state;
            end;
          except
            on E: Exception do
              DCDebug('[SyncDirs::CmpContentThread] ' + E.Message);
          end;
        end;
      end;
    end;
    _done := True;
    Synchronize(@_callback.onCheckContentThreadReapplyFilter);
  finally
    Synchronize(@_callback.onCheckContentThreadFinish);
    if Assigned(Buffer1) then FreeMem(Buffer1);
    if Assigned(Buffer2) then FreeMem(Buffer2);
  end;
end;

function TSyncDirsCheckContentThread.RetrieveStatistics: TFileSourceCopyOperationStatistics;
begin
  _mutex.Acquire;
  try
    Result := _statistics;
  finally
    _mutex.Release;
  end;
end;

procedure TSyncDirsCheckContentThread.UpdateStatistics(var NewStatistics: TFileSourceCopyOperationStatistics);
begin
  _mutex.Acquire;
  try
    _statistics := NewStatistics;
  finally
    _mutex.Release;
  end;
end;

constructor TSyncDirsCheckContentThread.Create(
  const fullTree: TTwoLevelTree;
  const callback: ISyncDirsCheckContentThreadCallback );
begin
  _fullTree:= fullTree;
  _callback:= callback;
  _mutex:= TCriticalSection.Create;
  inherited Create(False);
end;

destructor TSyncDirsCheckContentThread.Destroy;
begin
  inherited Destroy;
  _mutex.Free;
end;

end.
