program syncdirs_dialog_regression;

{$mode objfpc}{$H+}
{$codepage utf8}
{$R ../src/doublecmd.res}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  Interfaces, Forms, Classes, SysUtils, Controls, ExtCtrls, Grids, Clipbrd,
  LCLType, FileUtil, uGlobs, uGlobsPaths, uPixMapManager, uSpecialDir,
  uFileSource, uFileSystemFileSource, uFileView, uFileViewNotebook,
  uColumnsFileView, uTreeFileView, uDisplayFile, uFilePanelSelect,
  uSearchTemplate, uFindFiles, fSyncDirsDlg, fSyncDirsPerformDlg;

type
  TTestTreeView = class(TTreeFileView)
  public
    procedure Expand(const APath: String);
    function Contains(const APath: String): Boolean;
  end;

  TConfirmSync = class
  public
    Confirmed: Boolean;
    procedure Tick(Sender: TObject);
  end;

var
  Scratch, LeftRoot, RightRoot: String;
  Host: TForm;
  LeftBook, RightBook: TFileViewNotebook;
  LeftView: TColumnsFileView;
  RightView: TTestTreeView;
  FS: IFileSource;

procedure Check(Value: Boolean; const MessageText: String);
begin
  if not Value then
    raise Exception.Create(MessageText);
end;

procedure WriteFixture(const Path, Contents: String);
var
  Stream: TFileStream;
begin
  Check(ForceDirectories(ExtractFileDir(Path)), 'create fixture parent');
  Stream := TFileStream.Create(Path, fmCreate);
  try
    if Contents <> '' then Stream.WriteBuffer(Contents[1], Length(Contents));
  finally
    Stream.Free;
  end;
end;

procedure TTestTreeView.Expand(const APath: String);
var
  Key: Word;
begin
  SetActiveFile(APath);
  Key := VK_RIGHT;
  DoHandleKeyDown(Key, []);
  Check(Key = 0, 'Tree expansion key was not handled');
end;

function TTestTreeView.Contains(const APath: String): Boolean;
var
  I: Integer;
begin
  for I := 0 to DisplayFiles.Count - 1 do
    if DisplayFiles[I].FSFile.FullPath = APath then Exit(True);
  Result := False;
end;

procedure TConfirmSync.Tick(Sender: TObject);
var
  I: Integer;
  Dialog: TfrmSyncDirsPerformDlg;
begin
  for I := 0 to Screen.CustomFormCount - 1 do
    if Screen.CustomForms[I] is TfrmSyncDirsPerformDlg then
    begin
      Dialog := TfrmSyncDirsPerformDlg(Screen.CustomForms[I]);
      if not Dialog.Visible then Continue;
      Check(Dialog.chkLeftToRight.Checked, 'preview does not enable copying');
      Check(Dialog.chkDeleteRight.Checked, 'preview does not enable right deletion');
      Check(not Dialog.chkDeleteLeft.Checked, 'preview enables left deletion');
      Dialog.chkConfirmOverwrites.Checked := False;
      Confirmed := True;
      TTimer(Sender).Enabled := False;
      Dialog.ModalResult := mrOk;
      Exit;
    end;
end;

function NewDialog: TfrmSyncDirsDlg;
begin
  Result := TfrmSyncDirsDlg.Create(nil, LeftView, RightView);
  Result.chkOnlySelected.Checked := False;
  Result.chkByContent.Checked := False;
  Result.chkIgnoreDate.Checked := True;
  Result.chkSubDirs.Checked := True;
  Result.chkAsymmetric.Checked := False;
  Result.chkEmptyDir.Checked := True;
  Result.sbCopyLeft.Down := True;
  Result.sbCopyRight.Down := True;
  Result.sbEqual.Down := True;
  Result.sbNotEqual.Down := True;
  Result.sbUnknown.Down := True;
  Result.sbDuplicates.Down := True;
  Result.sbSingles.Down := True;
  Result.Show;
  Application.ProcessMessages;
end;

function SelectionText(Dialog: TfrmSyncDirsDlg; AllRows: Boolean): String;
var
  Selection: TGridRect;
begin
  if AllRows and (Dialog.MainDrawGrid.RowCount > 0) then
  begin
    Selection.Left := 0;
    Selection.Right := 0;
    Selection.Top := 0;
    Selection.Bottom := Dialog.MainDrawGrid.RowCount - 1;
    Dialog.MainDrawGrid.Selection := Selection;
  end;
  Dialog.CopyToClipboard;
  Result := Clipboard.AsText;
end;

procedure TestFiltersAndControls;
var
  Dialog: TfrmSyncDirsDlg;
  Template: TSearchTemplate;
  Options: TSearchTemplateRec;
  Text, PreviousTitle: String;
  Key: Word;
  CloseAction: TCloseAction;
begin
  WriteFixture(LeftRoot + 'a.txt', 'a');
  WriteFixture(LeftRoot + 'z.txt', 'longer');
  WriteFixture(LeftRoot + 'excluded.bin', 'must not be selected');
  Dialog := NewDialog;
  try
    Dialog.cbExtFilter.Text := '*.none';
    Dialog.btnCompare.Click;
    Check(Dialog.MainDrawGrid.RowCount = 0, 'empty filter yields rows');
    Dialog.pmGridMenuPopup(nil);
    Check(not Dialog.btnSynchronize.Enabled, 'empty comparison is actionable');

    Dialog.cbExtFilter.Text := '*.txt';
    Dialog.btnCompare.Click;
    Text := SelectionText(Dialog, True);
    Check((Pos('a.txt', Text) > 0) and (Pos('z.txt', Text) > 0) and
      (Pos('excluded.bin', Text) = 0), 'file mask was ignored');
    Check(Pos('a.txt', Text) < Pos('z.txt', Text), 'initial name sort is not ascending');
    PreviousTitle := Dialog.HeaderDG.Columns[0].Title.Caption;
    Dialog.HeaderDGHeaderClick(Dialog.HeaderDG, True, 0);
    Text := SelectionText(Dialog, True);
    Check(Pos('z.txt', Text) < Pos('a.txt', Text), 'descending name sort failed');
    Check(Dialog.HeaderDG.Columns[0].Title.Caption <> PreviousTitle,
      'sorting indicator did not change');
    Check(goFixedColSizing in Dialog.HeaderDG.Options, 'fixed-column resize disabled');
    Dialog.HeaderDG.Columns[0].Width := 180;
    Dialog.HeaderDGHeaderSizing(Dialog.HeaderDG, True, 0, 180);
    Check(Dialog.HeaderDG.Columns[0].Width = 180, 'column width did not change');

    Dialog.MainDrawGrid.ClearSelections;
    Dialog.MainDrawGrid.Row := 0;
    Dialog.cm_SelectClear([]);
    Check(Pos('->', SelectionText(Dialog, False)) = 0, 'clear action not previewed');
    Dialog.cm_SelectCopyLeftToRight([]);
    Check(Pos('->', SelectionText(Dialog, False)) > 0, 'copy action not previewed');
    Key := VK_SPACE;
    Dialog.MainDrawGridKeyDown(Dialog.MainDrawGrid, Key, []);
    Check(Pos('->', SelectionText(Dialog, False)) = 0, 'space did not toggle action');

    Template := TSearchTemplate.Create;
    Template.TemplateName := 'sync-regression';
    Options := Default(TSearchTemplateRec);
    Options.FilesMasks := '*.txt';
    Options.ExcludeFiles := 'z.txt';
    Options.SearchDepth := -1;
    Template.SearchRecord := Options;
    gSearchTemplateList.Add(Template);
    try
      Dialog.cbExtFilter.Text := '>sync-regression';
      Dialog.btnCompare.Click;
      Text := SelectionText(Dialog, True);
      Check((Pos('a.txt', Text) > 0) and (Pos('z.txt', Text) = 0) and
        (Pos('excluded.bin', Text) = 0), 'search-template exclusion was ignored');
    finally
      Dialog.cbExtFilter.Text := '*';
      gSearchTemplateList.DeleteTemplate(gSearchTemplateList.IndexOf(Template));
    end;
    Dialog.chkEmptyDir.Checked := True;
    CloseAction := caNone;
    Dialog.FormClose(Dialog, CloseAction);
    Check(gSyncDirsEmptyDirs, 'empty-directory checkbox not saved');
  finally
    Dialog.Free;
  end;
  Check(DeleteFile(LeftRoot + 'a.txt') and DeleteFile(LeftRoot + 'z.txt') and
    DeleteFile(LeftRoot + 'excluded.bin'), 'remove filter fixtures');
  WriteLn('PASS: dialog mask/template, sort, resizing, actions and checkbox');
end;

procedure TestSynchronizationAndExpandedRefresh;
var
  Dialog: TfrmSyncDirsDlg;
  Timer: TTimer;
  Confirmation: TConfirmSync;
  Deadline: QWord;
begin
  WriteFixture(LeftRoot + 'branch/new.txt', 'copied');
  WriteFixture(RightRoot + 'branch/obsolete.txt', 'deleted');
  Check(ForceDirectories(LeftRoot + 'branch/new-empty/deep'), 'new empty subtree');
  Check(ForceDirectories(RightRoot + 'branch/old-empty/deep'), 'old empty subtree');
  RightView.Reload(True);
  RightView.Expand(RightRoot + 'branch');
  Check(RightView.Contains(RightRoot + 'branch/obsolete.txt'), 'Tree did not expand fixture');
  Dialog := NewDialog;
  Confirmation := TConfirmSync.Create;
  Timer := TTimer.Create(nil);
  try
    Dialog.cbExtFilter.Text := '*';
    Dialog.chkAsymmetric.Checked := True;
    Dialog.btnCompare.Click;
    Check(Dialog.btnSynchronize.Enabled, 'synchronization is not enabled');
    Timer.Enabled := False;
    Timer.Interval := 10;
    Timer.OnTimer := @Confirmation.Tick;
    Timer.Enabled := True;
    Dialog.btnSynchronize.Click;
    Check(Confirmation.Confirmed, 'confirmation dialog was not exercised');
    Check(FileExists(RightRoot + 'branch/new.txt'), 'dialog did not copy the file');
    Check(not FileExists(RightRoot + 'branch/obsolete.txt'), 'dialog did not delete the file');
    Check(DirectoryExists(RightRoot + 'branch/new-empty/deep'), 'empty subtree not copied');
    Check(not DirectoryExists(RightRoot + 'branch/old-empty'), 'empty subtree not deleted');
    Deadline := GetTickCount64 + 3000;
    repeat
      Application.ProcessMessages;
      CheckSynchronize(1);
    until (RightView.Contains(RightRoot + 'branch/new.txt') and
      not RightView.Contains(RightRoot + 'branch/obsolete.txt') and
      not RightView.Contains(RightRoot + 'branch/old-empty')) or
      (GetTickCount64 >= Deadline);
    Check(RightView.Contains(RightRoot + 'branch/new.txt'),
      'expanded Tree row was not refreshed automatically');
    Check(not RightView.Contains(RightRoot + 'branch/obsolete.txt') and
      not RightView.Contains(RightRoot + 'branch/old-empty'), 'stale expanded Tree rows');
    Check(Dialog.TopPanel.Enabled, 'dialog controls not restored after synchronization');
  finally
    Timer.Free;
    Confirmation.Free;
    Dialog.Free;
  end;
  WriteLn('PASS: real dialog synchronization, confirmation and expanded Tree refresh');
end;

begin
  WriteLn('START: synchronization dialog regression');
  if (ParamCount <> 1) or (Copy(ParamStr(1), 1, 13) <> '--config-dir=') or
     (Length(ParamStr(1)) <= 13) then
    raise Exception.Create('Usage: syncdirs_dialog_regression --config-dir=<scratch-directory>');
  Scratch := IncludeTrailingPathDelimiter(ExpandFileName(Copy(ParamStr(1), 14, MaxInt)));
  Check(DirectoryExists(Scratch), 'scratch directory must already exist');
  LeftRoot := Scratch + 'left/';
  RightRoot := Scratch + 'right/';
  Check(not DirectoryExists(LeftRoot) and not DirectoryExists(RightRoot),
    'scratch contains reserved fixture directories');
  Check(ForceDirectories(LeftRoot) and ForceDirectories(RightRoot), 'fixture roots');
  Application.Initialize;
  Application.CaptureExceptions := False;
  gpCfgDir := Scratch;
  gpCmdLineCfgDir := Scratch;
  gpGlobalCfgDir := Scratch;
  gpCacheDir := Scratch + 'cache';
  gpThumbCacheDir := Scratch + 'thumbnails';
  LoadWindowsSpecialDir;
  Check(InitGlobs, 'isolated configuration');
  LoadPixMapManager;
  gListFilesInThread := False;
  gWatchDirs := [];
  gUseTrash := False;
  FS := TFileSystemFileSource.GetFileSource;
  Host := TForm.CreateNew(nil);
  try
    LeftBook := TFileViewNotebook.Create(Host, fpLeft);
    RightBook := TFileViewNotebook.Create(Host, fpRight);
    LeftBook.Parent := Host;
    RightBook.Parent := Host;
    LeftView := TColumnsFileView.Create(LeftBook.AddPage, FS, LeftRoot);
    RightView := TTestTreeView.Create(RightBook.AddPage, FS, RightRoot);
    Host.Show;
    TestFiltersAndControls;
    TestSynchronizationAndExpandedRefresh;
  finally
    Host.Free;
    FS := nil;
  end;
  Check(DeleteDirectory(LeftRoot, True) and DeleteDirectory(RightRoot, True),
    'remove successful dialog fixtures');
  WriteLn('PASS: synchronization dialog regression');
end.
