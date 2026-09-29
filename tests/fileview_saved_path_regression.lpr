program fileview_saved_path_regression;

{$mode objfpc}{$H+}
{$R ../src/doublecmd.res}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  Interfaces, Forms, Classes, SysUtils, DCXmlConfig, uGlobs, uFileView,
  uFileViewNotebook, uColumnsFileView, uTreeFileView, uGlobsPaths,
  uPixMapManager, uFile, uFilePanelSelect;

type
  TFileViewClassTest = class of TFileView;

procedure Check(Value: Boolean; const MessageText: String);
begin
  if not Value then
    raise Exception.Create(MessageText);
end;

procedure TestView(AViewClass: TFileViewClassTest; const Scratch: String;
  Delayed: Boolean);
var
  Form: TForm;
  Notebook: TFileViewNotebook;
  Page: TFileViewPage;
  View: TFileView;
  Config, SavedConfig: TXmlConfig;
  ViewNode, HistoryNode, EntryNode, FileSourceNode, PathsNode, PathNode: TXmlNode;
  ExistingPath, MissingPath, ConfigPath: String;
  ViewType: String;
  Flags: TFileViewFlags;
  Files: TFiles;
  I: Integer;
  Found: Boolean;
begin
  ExistingPath := IncludeTrailingPathDelimiter(Scratch) + 'existing' + PathDelim;
  MissingPath := ExistingPath + 'missing' + PathDelim + 'deeper' + PathDelim;
  ConfigPath := IncludeTrailingPathDelimiter(Scratch) + 'saved-path.xml';
  if AViewClass = TTreeFileView then ViewType := 'tree' else ViewType := 'columns';
  Flags := [];
  if Delayed then Flags := [fvfDelayLoadingFiles];

  Config := TXmlConfig.Create;
  Form := TForm.CreateNew(nil);
  Notebook := TFileViewNotebook.Create(Form, fpLeft);
  try
    ViewNode := Config.AddNode(Config.RootNode, 'View');
    Config.SetAttr(ViewNode, 'Type', ViewType);
    HistoryNode := Config.AddNode(ViewNode, 'History');
    EntryNode := Config.AddNode(HistoryNode, 'Entry');
    Config.SetAttr(EntryNode, 'Active', True);
    FileSourceNode := Config.AddNode(EntryNode, 'FileSource');
    Config.SetAttr(FileSourceNode, 'Type', 'FileSystem');
    PathsNode := Config.AddNode(EntryNode, 'Paths');
    PathNode := Config.AddNode(PathsNode, 'Path');
    Config.SetContent(PathNode, MissingPath);
    Config.SetAttr(PathNode, 'Active', True);

    Page := Notebook.AddPage;
    View := AViewClass.Create(Page, Config, ViewNode, Flags);
    Check((Delayed and (View.CurrentPath = MissingPath)) or
      (not Delayed and (View.CurrentPath = ExistingPath)),
      AViewClass.ClassName + ' initial path');

    if Delayed then
    begin
      View.SaveConfiguration(Config, ViewNode, False);
      Config.WriteToFile(ConfigPath);
      SavedConfig := TXmlConfig.Create(ConfigPath, True);
      try
        ViewNode := SavedConfig.FindNode(SavedConfig.RootNode, 'View');
        Check(SavedConfig.GetAttr(ViewNode, 'Type', '') = ViewType,
          AViewClass.ClassName + ' saved view type');
        Page.Free;
        Page := Notebook.AddPage;
        View := AViewClass.Create(Page, SavedConfig, ViewNode, Flags);
        Check(View.CurrentPath = MissingPath,
          AViewClass.ClassName + ' delayed path round trip');
      finally
        SavedConfig.Free;
      end;

      if AViewClass = TColumnsFileView then
      begin
        Check(ForceDirectories(MissingPath), 'create saved missing path');
        with TFileStream.Create(MissingPath + 'sentinel', fmCreate) do Free;
        View.Flags := View.Flags - [fvfDelayLoadingFiles];
        View.Reload(True);
        Check(View.CurrentPath = MissingPath, AViewClass.ClassName + ' activation path');
        Files := View.CloneFiles;
        try
          Found := False;
          for I := 0 to Files.Count - 1 do
            Found := Found or (Files[I].Name = 'sentinel');
          Check(Found, 'restored path is listed after activation');
        finally
          Files.Free;
        end;
        DeleteFile(MissingPath + 'sentinel');
        RemoveDir(MissingPath);
        RemoveDir(ExtractFileDir(ExcludeTrailingPathDelimiter(MissingPath)));
      end
      else
      begin
        View.Flags := View.Flags - [fvfDelayLoadingFiles];
        View.Reload(True);
        Check(View.CurrentPath = MissingPath, AViewClass.ClassName + ' absent activation path');
        Check(View.GetActiveFileName = '..', 'missing path has parent entry');
        View.ChangePathToParent(True);
        Check(View.CurrentPath = ExistingPath, 'parent navigation uses existing path');
      end;
    end;
  finally
    Form.Free;
    Config.Free;
    DeleteFile(ConfigPath);
  end;
end;

var
  Scratch: String;
begin
  WriteLn('START: saved tab path regression');
  if (ParamCount <> 1) or (Copy(ParamStr(1), 1, 13) <> '--config-dir=') or
     (Length(ParamStr(1)) <= 13) then
    raise Exception.Create('Usage: fileview_saved_path_regression --config-dir=<scratch-directory>');
  Scratch := IncludeTrailingPathDelimiter(ExpandFileName(Copy(ParamStr(1), 14, MaxInt)));
  Check(DirectoryExists(Scratch), 'scratch directory must already exist');
  Check(not DirectoryExists(Scratch + 'existing') and
    not FileExists(Scratch + 'saved-path.xml'), 'scratch contains reserved test paths');
  Check(ForceDirectories(Scratch + 'existing'), 'create existing path');
  Application.Initialize;
  Application.CaptureExceptions := False;
  gpCfgDir := Scratch;
  gpCmdLineCfgDir := Scratch;
  gpGlobalCfgDir := Scratch;
  gpCacheDir := Scratch + 'cache';
  gpThumbCacheDir := Scratch + 'thumbnails';
  Check(InitGlobs, 'initialize isolated test configuration');
  LoadPixMapManager;
  gListFilesInThread := False;
  gWatchDirs := [];
  try
    TestView(TColumnsFileView, Scratch, True);
    TestView(TColumnsFileView, Scratch, False);
    TestView(TTreeFileView, Scratch, True);
    TestView(TTreeFileView, Scratch, False);
  finally
    RemoveDir(Scratch + 'existing');
  end;
  WriteLn('PASS: saved tab path regression');
end.
