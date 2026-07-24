unit uTreeFileView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Controls,
  DCXmlConfig,
  uDisplayFile, uFile, uFileView, uColumnsFileView;

type

  { TTreeFileView }

  { Columns view with expandable directories.
    Phase 2: expanding lists children indented below their parent. }
  TTreeFileView = class(TColumnsFileView)
  private
    FExpandedPaths: TStringList;
    FWatchedPaths: TStringList;
    procedure AddSubdirWatch(const APath: String);
    procedure RemoveSubdirWatches(const APrefix: String);
    function ExpanderWidth: Integer;
    function FileLevel(AFile: TDisplayFile): Integer;
    function IsExpandable(AFile: TDisplayFile): Boolean;
    function IsExpanded(AFile: TDisplayFile): Boolean;
    procedure ExpandDirectory(AFile: TDisplayFile);
    procedure CollapseDirectory(AFile: TDisplayFile);
    procedure ToggleExpanded(AFile: TDisplayFile);
    procedure ReorderTree(AList: TDisplayFiles);
  protected
    procedure SortAllDisplayFiles; override;
    procedure DisplayFileListChanged; override;
    procedure DoHandleKeyDown(var Key: Word; Shift: TShiftState); override;
    function calcFileHashKey(const FileName, APath: String): String; override;
    procedure CreateDefault(AOwner: TWinControl); override;
    procedure DecorateIconCell(ACanvas: TCanvas; AFile: TDisplayFile; var CellRect: TRect); override;
    procedure MainControlMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure AfterChangePath; override;
    procedure FileSourceFileListLoaded; override;
  public
    destructor Destroy; override;
    function CloneSelectedFiles: TFiles; override;
    procedure ChangePathToChild(const aFile: TFile); override;
    function Clone(NewParent: TWinControl): TColumnsFileView; override;
    procedure CloneTo(FileView: TFileView); override;
    procedure SaveConfiguration(AConfig: TXmlConfig; ANode: TXmlNode; ASaveHistory: Boolean); override;
  end;

implementation

uses
  Math, LCLType, uGlobs, uFileSource, uFileSystemFileSource, uFileSourceListOperation,
  uFileSourceOperationTypes, uFileSourceOperation, uFileSourceProperty,
  uFileViewWorker, uFileSorting, uFileSourceWatcher;

{ TTreeFileView }

procedure TTreeFileView.CreateDefault(AOwner: TWinControl);
begin
  inherited CreateDefault(AOwner);
  FExpandedPaths := TStringList.Create;
  FExpandedPaths.CaseSensitive := FileNameCaseSensitive;
  FWatchedPaths := TStringList.Create;
  FWatchedPaths.CaseSensitive := FileNameCaseSensitive;
end;

destructor TTreeFileView.Destroy;
begin
  if Assigned(FWatchedPaths) then
    RemoveSubdirWatches(EmptyStr);
  inherited Destroy;
  FreeAndNil(FExpandedPaths);
  FreeAndNil(FWatchedPaths);
end;

procedure TTreeFileView.AddSubdirWatch(const APath: String);
var
  WatchFilter: TFSWatchFilter;
begin
  if not FileSource.IsClass(TFileSystemFileSource) then Exit;
  if FWatchedPaths.IndexOf(APath) >= 0 then Exit;

  WatchFilter := [];
  if watch_file_name_change in gWatchDirs then
    Include(WatchFilter, wfFileNameChange);
  if watch_attributes_change in gWatchDirs then
    Include(WatchFilter, wfAttributesChange);
  if WatchFilter = [] then Exit;

  if FileSource.GetWatcher.addWatch(APath, WatchFilter, @WatcherEvent, Self) then
    FWatchedPaths.Add(APath);
end;

procedure TTreeFileView.RemoveSubdirWatches(const APrefix: String);
var
  I: Integer;
begin
  for I := FWatchedPaths.Count - 1 downto 0 do
    if (APrefix = EmptyStr) or
       (Copy(FWatchedPaths[I], 1, Length(APrefix)) = APrefix) then
    begin
      FileSource.GetWatcher.removeWatch(FWatchedPaths[I], @WatcherEvent);
      FWatchedPaths.Delete(I);
    end;
end;

function TTreeFileView.calcFileHashKey(const FileName, APath: String): String;
begin
  // Always path-qualified: the tree shows files with the same name
  // from different directories at the same time.
  Result := ExcludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(APath) + FileName);
end;

function TTreeFileView.ExpanderWidth: Integer;
begin
  Result := Max(gIconsSize, 12);
end;

function TTreeFileView.FileLevel(AFile: TDisplayFile): Integer;
var
  APath: String;
  I: Integer;
begin
  Result := 0;
  APath := AFile.FSFile.Path;  // ends with a path delimiter
  for I := Length(CurrentPath) + 1 to Length(APath) do
    if APath[I] = PathDelim then
      Inc(Result);
end;

function TTreeFileView.IsExpandable(AFile: TDisplayFile): Boolean;
begin
  Result := (AFile.FSFile.IsDirectory or AFile.FSFile.IsLinkToDirectory) and
            (AFile.FSFile.Name <> '..') and
            FileSource.IsClass(TFileSystemFileSource);  // real filesystem only for now
end;

function TTreeFileView.IsExpanded(AFile: TDisplayFile): Boolean;
begin
  Result := Assigned(FExpandedPaths) and
            (FExpandedPaths.IndexOf(AFile.FSFile.FullPath) >= 0);
end;

procedure TTreeFileView.ExpandDirectory(AFile: TDisplayFile);
var
  ChildrenPath: String;
  ListOp: TFileSourceListOperation;
  AFiles: TFiles;
  NewFiles: TDisplayFiles;
  DF: TDisplayFile;
  I, InsAll, InsVis: Integer;
begin
  if IsExpanded(AFile) then Exit;
  if not (fsoList in FileSource.GetOperationsTypes) then Exit;
  ChildrenPath := IncludeTrailingPathDelimiter(AFile.FSFile.FullPath);

  AFiles := nil;
  try
    ListOp := FileSource.CreateListOperation(ChildrenPath) as TFileSourceListOperation;
    if not Assigned(ListOp) then Exit;
    try
      ListOp.Execute;
      if ListOp.Result = fsorFinished then
        AFiles := ListOp.ReleaseFiles;
    finally
      ListOp.Free;
    end;
  except
    // No permission or vanished directory: leave collapsed, no crash
    FreeAndNil(AFiles);
  end;
  if AFiles = nil then Exit;

  NewFiles := TDisplayFiles.Create(False);
  try
    for I := 0 to AFiles.Count - 1 do
    begin
      if (AFiles[I].Name = '..') or (AFiles[I].Name = '.') then Continue;
      if FHashedNames.Find(calcFileHashKey(AFiles[I].Name, AFiles[I].Path)) >= 0 then Continue;
      DF := TDisplayFile.Create(AFiles[I].Clone);
      DF.DisplayName := FileSource.GetDisplayFileName(DF.FSFile);
      NewFiles.Add(DF);
    end;
    TDisplayFileSorter.Sort(NewFiles, SortingForSorter);

    InsAll := FAllDisplayFiles.Find(AFile) + 1;
    if InsAll = 0 then InsAll := FAllDisplayFiles.Count;
    InsVis := FFiles.Find(AFile) + 1;  // 0 = parent filtered out

    for I := 0 to NewFiles.Count - 1 do
    begin
      DF := NewFiles[I];
      FHashedFiles.Add(DF, nil);
      FHashedNames.Add(calcFileHashKey(DF.FSFile.Name, DF.FSFile.Path), DF);
      FAllDisplayFiles.List.Insert(InsAll, DF);
      Inc(InsAll);
      if (InsVis > 0) and
         (not TFileListBuilder.MatchesFilter(FileSource, DF.FSFile, FileFilter, FilterOptions)) then
      begin
        FFiles.List.Insert(InsVis, DF);
        Inc(InsVis);
      end;
    end;
    FExpandedPaths.Add(AFile.FSFile.FullPath);
    AddSubdirWatch(ChildrenPath);
  finally
    NewFiles.Free;  // does not own the display files
    AFiles.Free;    // frees the listed files; we inserted clones
  end;
  Notify([fvnFileSourceFileListUpdated, fvnDisplayFileListChanged]);
end;

procedure TTreeFileView.CollapseDirectory(AFile: TDisplayFile);
var
  Prefix: String;
  I: Integer;
  DF: TDisplayFile;
begin
  Prefix := IncludeTrailingPathDelimiter(AFile.FSFile.FullPath);

  // Stop watching this subtree (the prefix matches the dir itself too)
  RemoveSubdirWatches(Prefix);

  // Forget expansion state of this directory and everything below it
  for I := FExpandedPaths.Count - 1 downto 0 do
    if (FExpandedPaths[I] = AFile.FSFile.FullPath) or
       (Copy(FExpandedPaths[I], 1, Length(Prefix)) = Prefix) then
      FExpandedPaths.Delete(I);

  // Drop every display file living under this directory
  for I := FAllDisplayFiles.Count - 1 downto 0 do
  begin
    DF := FAllDisplayFiles[I];
    if Copy(DF.FSFile.Path, 1, Length(Prefix)) = Prefix then
    begin
      FHashedNames.Remove(calcFileHashKey(DF.FSFile.Name, DF.FSFile.Path));
      FHashedFiles.Remove(DF);
      FFiles.Remove(DF);
      if Assigned(FRecentlyUpdatedFiles) then
        FRecentlyUpdatedFiles.Remove(DF);
      FAllDisplayFiles.Delete(I);  // owner: frees the display file
    end;
  end;
  Notify([fvnFileSourceFileListUpdated, fvnDisplayFileListChanged]);
end;

procedure TTreeFileView.ToggleExpanded(AFile: TDisplayFile);
begin
  if not Assigned(FExpandedPaths) then Exit;
  if IsExpanded(AFile) then
    CollapseDirectory(AFile)
  else
    ExpandDirectory(AFile);
end;

procedure TTreeFileView.ReorderTree(AList: TDisplayFiles);
var
  Groups: TStringList;
  OutList: TFPList;
  I, J, GI: Integer;
  DF: TDisplayFile;
  G: TFPList;

  procedure Emit(const APath: String);
  var
    K, EI: Integer;
    L: TFPList;
    F: TDisplayFile;
  begin
    EI := Groups.IndexOf(APath);
    if EI < 0 then Exit;
    L := TFPList(Groups.Objects[EI]);
    Groups.Delete(EI);  // also guards against symlink cycles
    for K := 0 to L.Count - 1 do
    begin
      F := TDisplayFile(L[K]);
      OutList.Add(F);
      if IsExpandable(F) and (FExpandedPaths.IndexOf(F.FSFile.FullPath) >= 0) then
        Emit(IncludeTrailingPathDelimiter(F.FSFile.FullPath));
    end;
    L.Free;
  end;

begin
  if (FExpandedPaths = nil) or (FExpandedPaths.Count = 0) then Exit;

  Groups := TStringList.Create;
  OutList := TFPList.Create;
  try
    Groups.CaseSensitive := FileNameCaseSensitive;

    // Group files by parent directory, keeping the (sorted) relative order
    for I := 0 to AList.Count - 1 do
    begin
      DF := AList[I];
      GI := Groups.IndexOf(DF.FSFile.Path);
      if GI < 0 then
      begin
        G := TFPList.Create;
        Groups.AddObject(DF.FSFile.Path, TObject(G));
      end
      else
        G := TFPList(Groups.Objects[GI]);
      G.Add(DF);
    end;

    // Depth-first: siblings in sorted order, children right after their parent
    Emit(CurrentPath);

    // Safety net: keep any unreachable leftovers at the end
    for I := 0 to Groups.Count - 1 do
    begin
      G := TFPList(Groups.Objects[I]);
      for J := 0 to G.Count - 1 do
        OutList.Add(G[J]);
      G.Free;
    end;

    AList.List.Clear;
    for I := 0 to OutList.Count - 1 do
      AList.List.Add(OutList[I]);
  finally
    OutList.Free;
    Groups.Free;
  end;
end;

procedure TTreeFileView.SortAllDisplayFiles;
begin
  inherited SortAllDisplayFiles;   // flat sort of the whole list
  ReorderTree(FAllDisplayFiles);   // then children back under their parents
end;

procedure TTreeFileView.DisplayFileListChanged;
begin
  // Files inserted by the watcher (or resorted) land in flat-sort positions:
  // restore depth-first order before the grid is updated. Idempotent.
  if Assigned(FAllDisplayFiles) then
    ReorderTree(FAllDisplayFiles);
  if Assigned(FFiles) then
    ReorderTree(FFiles);
  inherited DisplayFileListChanged;
end;

procedure TTreeFileView.DoHandleKeyDown(var Key: Word; Shift: TShiftState);
var
  AFile: TDisplayFile;
  Idx: PtrInt;
  Level, I: Integer;
begin
  case Key of
    VK_RIGHT:
      if Shift = [] then
      begin
        Idx := GetActiveFileIndex;
        if IsFileIndexInRange(Idx) then
        begin
          AFile := FFiles[Idx];
          if IsExpandable(AFile) then
          begin
            if not IsExpanded(AFile) then
              ExpandDirectory(AFile)
            else if (Idx + 1 < FFiles.Count) and (FileLevel(FFiles[Idx + 1]) > FileLevel(AFile)) then
              SetActiveFile(Idx + 1, True);
          end;
        end;
        Key := 0;
        Exit;
      end;

    VK_LEFT:
      if Shift = [] then
      begin
        Idx := GetActiveFileIndex;
        if IsFileIndexInRange(Idx) then
        begin
          AFile := FFiles[Idx];
          if IsExpandable(AFile) and IsExpanded(AFile) then
            CollapseDirectory(AFile)
          else
          begin
            Level := FileLevel(AFile);
            if Level > 0 then
              for I := Idx - 1 downto 0 do
                if FileLevel(FFiles[I]) < Level then
                begin
                  SetActiveFile(I, True);
                  Break;
                end;
          end;
        end;
        Key := 0;
        Exit;
      end;
  end;
  inherited DoHandleKeyDown(Key, Shift);
end;

procedure TTreeFileView.DecorateIconCell(ACanvas: TCanvas; AFile: TDisplayFile; var CellRect: TRect);
var
  cx, cy, h: Integer;
  P: array[0..2] of TPoint;
begin
  // Indent by nesting level
  Inc(CellRect.Left, ExpanderWidth * FileLevel(AFile));

  if IsExpandable(AFile) then
  begin
    cx := CellRect.Left + ExpanderWidth div 2;
    cy := CellRect.Top + CellRect.Height div 2;
    h := Max(3, ExpanderWidth div 6);
    if IsExpanded(AFile) then
    begin
      // triangle pointing down
      P[0] := Classes.Point(cx - h, cy - h div 2);
      P[1] := Classes.Point(cx + h, cy - h div 2);
      P[2] := Classes.Point(cx, cy + h);
    end
    else
    begin
      // triangle pointing right
      P[0] := Classes.Point(cx - h div 2, cy - h);
      P[1] := Classes.Point(cx - h div 2, cy + h);
      P[2] := Classes.Point(cx + h, cy);
    end;
    // No system theming here on purpose: themed drawing is broken on Qt6/Wayland
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := ACanvas.Font.Color;
    ACanvas.Pen.Style := psSolid;
    ACanvas.Pen.Color := ACanvas.Font.Color;
    ACanvas.Polygon(P);
    ACanvas.Brush.Style := bsClear;
  end;
  // Reserve the expander strip on every row so that names stay aligned
  Inc(CellRect.Left, ExpanderWidth);
end;

procedure TTreeFileView.MainControlMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  ACol, ARow: Integer;
  Idx, StripLeft: Integer;
  R: TRect;
begin
  if Button = mbLeft then
  begin
    dgPanel.MouseToCell(X, Y, ACol, ARow);
    Idx := dgPanel.CellToIndex(ACol, ARow);
    if IsFileIndexInRange(Idx) then
    begin
      R := dgPanel.CellRect(0, ARow);
      StripLeft := R.Left + ExpanderWidth * FileLevel(FFiles[Idx]);
      if (X >= StripLeft) and (X < StripLeft + ExpanderWidth) and IsExpandable(FFiles[Idx]) then
      begin
        if not (ssDouble in Shift) then
          ToggleExpanded(FFiles[Idx]);
        Exit; // click handled: no selection/drag from the expander strip
      end;
    end;
  end;
  inherited MainControlMouseDown(Sender, Button, Shift, X, Y);
end;

function TTreeFileView.CloneSelectedFiles: TFiles;
var
  I, J: Integer;
  Prefix: String;
  Covered: Boolean;
begin
  Result := inherited CloneSelectedFiles;
  // Selecting a directory covers its whole subtree: drop selected
  // descendants, otherwise they would be copied/deleted twice.
  for I := Result.Count - 1 downto 0 do
  begin
    Covered := False;
    for J := 0 to Result.Count - 1 do
    begin
      if (J = I) or (not Result[J].IsDirectory) then Continue;
      Prefix := IncludeTrailingPathDelimiter(Result[J].FullPath);
      if Copy(Result[I].Path, 1, Length(Prefix)) = Prefix then
      begin
        Covered := True;
        Break;
      end;
    end;
    if Covered then
      Result.Delete(I);
  end;
end;

procedure TTreeFileView.ChangePathToChild(const aFile: TFile);
begin
  // An expanded child can live several levels below CurrentPath:
  // enter it via its real path, not CurrentPath + name.
  if Assigned(aFile) and aFile.IsNameValid and
     (aFile.IsDirectory or aFile.IsLinkToDirectory) and
     (aFile.Path <> CurrentPath) and
     (not (fspDontChangePath in FileSource.Properties)) then
    CurrentPath := IncludeTrailingPathDelimiter(aFile.FullPath)
  else
    inherited ChangePathToChild(aFile);
end;

procedure TTreeFileView.AfterChangePath;
begin
  inherited AfterChangePath;
  if Assigned(FWatchedPaths) then
    RemoveSubdirWatches(EmptyStr);
  if Assigned(FExpandedPaths) then
    FExpandedPaths.Clear;
end;

function CompareByDepth(List: TStringList; Index1, Index2: Integer): Integer;
var
  I, D1, D2: Integer;
begin
  D1 := 0;
  D2 := 0;
  for I := 1 to Length(List[Index1]) do
    if List[Index1][I] = PathDelim then Inc(D1);
  for I := 1 to Length(List[Index2]) do
    if List[Index2][I] = PathDelim then Inc(D2);
  Result := D1 - D2;
end;

procedure TTreeFileView.FileSourceFileListLoaded;
var
  Saved: TStringList;
  I, H: Integer;
begin
  inherited FileSourceFileListLoaded;
  // A fresh list from the worker has no expanded children: re-apply the
  // saved expansion state (parents first, vanished directories dropped).
  if (FExpandedPaths = nil) or (FExpandedPaths.Count = 0) then Exit;
  Saved := TStringList.Create;
  try
    Saved.Assign(FExpandedPaths);
    FExpandedPaths.Clear;
    RemoveSubdirWatches(EmptyStr);
    Saved.CustomSort(@CompareByDepth);
    for I := 0 to Saved.Count - 1 do
    begin
      H := FHashedNames.Find(Saved[I]);  // keys are full paths
      if H >= 0 then
        ExpandDirectory(TDisplayFile(FHashedNames.List[H]^.Data));
    end;
  finally
    Saved.Free;
  end;
end;

function TTreeFileView.Clone(NewParent: TWinControl): TColumnsFileView;
begin
  Result := TTreeFileView.Create(NewParent, Self);
end;

procedure TTreeFileView.CloneTo(FileView: TFileView);
begin
  inherited CloneTo(FileView);
  if FileView is TTreeFileView then
    TTreeFileView(FileView).FExpandedPaths.Assign(FExpandedPaths);
end;

procedure TTreeFileView.SaveConfiguration(AConfig: TXmlConfig; ANode: TXmlNode; ASaveHistory: Boolean);
begin
  inherited SaveConfiguration(AConfig, ANode, ASaveHistory);
  AConfig.SetAttr(ANode, 'Type', 'tree');
end;

end.
