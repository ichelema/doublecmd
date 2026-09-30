program ui_theme_regression;

{$mode objfpc}{$H+}
{$codepage utf8}
{$R ../src/doublecmd.res}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  Interfaces,
  {$IFDEF LCLQT6}uQtWSControls, uQtWSMenus,
    {$IFNDEF LCL_VER_499}uQtWSButtons,{$ENDIF}
  {$ENDIF}
  Forms, Classes, SysUtils, Controls, Graphics, Types, StdCtrls,
  Buttons, ExtCtrls, uGlobs, uGlobsPaths, uPixMapManager, uSpecialDir, fMain, fOptions,
  fOptionsFrame, fOptionsDirectoryHotlist;

type
  TThemeMain = class(TfrmMain)
  protected
    procedure DoCreate; override;
  end;

var
  Failures: Integer = 0;
  Scratch: String;

procedure TThemeMain.DoCreate;
begin
  // Keep the real form resource, but skip application-wide FormCreate setup.
  OnDestroy := nil;
  OnShow := nil;
  OnResize := nil;
end;

procedure Check(Value: Boolean; const MessageText: String);
begin
  if not Value then
    raise Exception.Create(MessageText);
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
end;

procedure TestHotlistButtonLayout;
var
  Host: TForm;
  Editor: TfrmOptionsDirectoryHotlist;
  Buttons: array of TBitBtn;
  I, J, Columns, SecondColumn, SizeIndex: Integer;
  R1, R2, Overlap: TRect;
  FontSizes: array[0..1] of Integer = (10, 18);
begin
  Host := TForm.CreateNew(nil);
  try
    Host.SetBounds(0, 0, 800, 700);
    Editor := TfrmOptionsDirectoryHotlist.Create(Host);
    Editor.Parent := Host;
    Editor.Align := alClient;
    Editor.Init(Host, nil, []);
    Host.HandleNeeded;
    Host.Show;
    Application.ProcessMessages;

    SetLength(Buttons, 0);
    for I := 0 to Editor.pnlButtons.ControlCount - 1 do
      if Editor.pnlButtons.Controls[I] is TBitBtn then
      begin
        SetLength(Buttons, Length(Buttons) + 1);
        Buttons[High(Buttons)] := TBitBtn(Editor.pnlButtons.Controls[I]);
      end;
    Check(Length(Buttons) = 8, 'hotlist button panel does not contain its eight action buttons');

    for SizeIndex := 0 to High(FontSizes) do
    begin
      Editor.Font.Size := FontSizes[SizeIndex];
      Application.ProcessMessages;
      for I := 0 to High(Buttons) do
      begin
        Host.Canvas.Font.Assign(Buttons[I].Font);
        Check(Host.Canvas.TextHeight(Buttons[I].Caption) <= Buttons[I].Height,
          'hotlist action button clips its caption at font size ' + IntToStr(FontSizes[SizeIndex]));
        for J := 0 to I - 1 do
        begin
          R1 := Bounds(Buttons[I].Left, Buttons[I].Top, Buttons[I].Width, Buttons[I].Height);
          R2 := Bounds(Buttons[J].Left, Buttons[J].Top, Buttons[J].Width, Buttons[J].Height);
          Check(not IntersectRect(Overlap, R1, R2),
            'hotlist action buttons overlap at font size ' + IntToStr(FontSizes[SizeIndex]));
        end;
      end;
      Columns := 1;
      SecondColumn := Buttons[0].Left;
      for I := 1 to High(Buttons) do
        if Buttons[I].Left <> Buttons[0].Left then
        begin
          Columns := 2;
          SecondColumn := Buttons[I].Left;
          Break;
        end;
      for I := 0 to High(Buttons) do
        Check((Buttons[I].Left = Buttons[0].Left) or
          (Buttons[I].Left = SecondColumn),
          'hotlist action buttons form more than two columns');
      Check(Columns = 2, 'hotlist action buttons do not form two columns');
    end;
  finally
    Host.Free;
  end;
end;

procedure TestMainFormAndFreeSpaceRendering;
var
  MainForm: TThemeMain;
  Bitmap: TBitmap;
  PaintBox: TPaintBox;
  PercentIndex, WidthIndex, HeightIndex, ModeIndex: Integer;
  PixelX, PixelY, ChangedPixels: Integer;
  GuardTagIndex, GuardWidthIndex, GuardHeightIndex: Integer;
  Percentages: array[0..3] of Integer = (0, 50, 90, 100);
  Widths: array[0..2] of Integer = (3, 17, 160);
  Heights: array[0..1] of Integer = (8, 15);
  GuardTags: array[0..1] of Integer = (-1, 50);
  GuardWidths: array[0..1] of Integer = (2, 17);
  GuardHeights: array[0..1] of Integer = (2, 8);
  PreviousGradientMode: Boolean;
  EmptyColor: TColor;

  procedure Render;
  begin
    PaintBox.Canvas.Handle := Bitmap.Canvas.Handle;
    try
      MainForm.sboxDrivePaint(PaintBox);
    finally
      PaintBox.Canvas.Handle := 0;
    end;
  end;

begin
  MainForm := TThemeMain.Create(nil);
  try
    MainForm.OnShow := nil;
    MainForm.OnResize := nil;
    Check((MainForm.btnLeftHome.Parent = MainForm.pnlLeftTools) and
      (MainForm.btnLeftUp.Parent = MainForm.pnlLeftTools) and
      (MainForm.btnLeftRoot.Parent = MainForm.pnlLeftTools) and
      (MainForm.btnLeftDirectoryHotlist.Parent = MainForm.pnlLeftTools) and
      (MainForm.btnRightHome.Parent = MainForm.pnlRightTools) and
      (MainForm.btnRightUp.Parent = MainForm.pnlRightTools) and
      (MainForm.btnRightRoot.Parent = MainForm.pnlRightTools) and
      (MainForm.btnRightDirectoryHotlist.Parent = MainForm.pnlRightTools),
      'left navigation buttons are not hosted by the resource panel');
    Check((MainForm.btnLeftHome.Anchors = [akTop, akRight, akBottom]) and
      (MainForm.btnLeftUp.Anchors = [akTop, akRight, akBottom]) and
      (MainForm.btnLeftRoot.Anchors = [akTop, akRight, akBottom]) and
      (MainForm.btnLeftDirectoryHotlist.Anchors = [akTop, akRight, akBottom]) and
      (MainForm.btnRightHome.Anchors = [akTop, akRight, akBottom]) and
      (MainForm.btnRightUp.Anchors = [akTop, akRight, akBottom]) and
      (MainForm.btnRightRoot.Anchors = [akTop, akRight, akBottom]) and
      (MainForm.btnRightDirectoryHotlist.Anchors = [akTop, akRight, akBottom]),
      'navigation buttons are not anchored to the panel edges');
    Check((MainForm.btnLeftHome.AnchorSideRight.Control = MainForm.btnLeftEqualRight) and
      (MainForm.btnLeftUp.AnchorSideRight.Control = MainForm.btnLeftHome) and
      (MainForm.btnLeftRoot.AnchorSideRight.Control = MainForm.btnLeftUp) and
      (MainForm.btnLeftDirectoryHotlist.AnchorSideRight.Control = MainForm.btnLeftRoot) and
      (MainForm.btnRightHome.AnchorSideRight.Control = MainForm.btnRightEqualLeft) and
      (MainForm.btnRightUp.AnchorSideRight.Control = MainForm.btnRightHome) and
      (MainForm.btnRightRoot.AnchorSideRight.Control = MainForm.btnRightUp) and
      (MainForm.btnRightDirectoryHotlist.AnchorSideRight.Control = MainForm.btnRightRoot),
      'navigation buttons are not chained to the right');
    Check((MainForm.lblLeftDriveInfo.AnchorSideRight.Control = MainForm.btnLeftDirectoryHotlist) and
      (MainForm.lblRightDriveInfo.AnchorSideRight.Control = MainForm.btnRightDirectoryHotlist),
      'free-space labels are not right-anchored to the hotlist buttons');

    PaintBox := TPaintBox.Create(MainForm);
    PaintBox.Parent := MainForm;
    Bitmap := TBitmap.Create;
    try
      PreviousGradientMode := gIndUseGradient;
      try
        for ModeIndex := 0 to 1 do
        begin
          gIndUseGradient := ModeIndex = 1;
          EmptyColor := clNone;
          for PercentIndex := 0 to High(Percentages) do
          begin
            PaintBox.Tag := Percentages[PercentIndex];
            for WidthIndex := 0 to High(Widths) do
              for HeightIndex := 0 to High(Heights) do
              begin
                PaintBox.SetBounds(0, 0, Widths[WidthIndex], Heights[HeightIndex]);
                Bitmap.SetSize(Widths[WidthIndex], Heights[HeightIndex]);
                Bitmap.Canvas.Brush.Color := clFuchsia;
                Bitmap.Canvas.FillRect(0, 0, Bitmap.Width, Bitmap.Height);
                Render;
                ChangedPixels := 0;
                // Software pixel smoke check only; it is not native visual inspection.
                for PixelX := 0 to Bitmap.Width - 1 do
                  for PixelY := 0 to Bitmap.Height - 1 do
                    if Bitmap.Canvas.Pixels[PixelX, PixelY] <> clFuchsia then
                      Inc(ChangedPixels);
                Check(ChangedPixels > 0, 'free-space indicator produced no pixels');
                if (PaintBox.Width = 160) and (PaintBox.Height = 15) then
                begin
                  if PaintBox.Tag = 0 then
                    EmptyColor := Bitmap.Canvas.Pixels[80, 7]
                  else if PaintBox.Tag = 100 then
                    Check(Bitmap.Canvas.Pixels[80, 7] <> EmptyColor,
                      'empty and full indicators have the same interior');
                end;
              end;
          end;
          for GuardTagIndex := 0 to High(GuardTags) do
            for GuardWidthIndex := 0 to High(GuardWidths) do
              for GuardHeightIndex := 0 to High(GuardHeights) do
              begin
                if (GuardTags[GuardTagIndex] >= 0) and
                   (GuardWidths[GuardWidthIndex] >= 3) and
                   (GuardHeights[GuardHeightIndex] >= 3) then Continue;
                PaintBox.Tag := GuardTags[GuardTagIndex];
                PaintBox.SetBounds(0, 0, GuardWidths[GuardWidthIndex],
                  GuardHeights[GuardHeightIndex]);
                Bitmap.SetSize(GuardWidths[GuardWidthIndex], GuardHeights[GuardHeightIndex]);
                Bitmap.Canvas.Brush.Color := clFuchsia;
                Bitmap.Canvas.FillRect(0, 0, Bitmap.Width, Bitmap.Height);
                Render;
                for PixelX := 0 to Bitmap.Width - 1 do
                  for PixelY := 0 to Bitmap.Height - 1 do
                    Check(Bitmap.Canvas.Pixels[PixelX, PixelY] = clFuchsia,
                      'free-space guard unexpectedly painted a pixel');
              end;
        end;
      finally
        gIndUseGradient := PreviousGradientMode;
      end;
    finally
      Bitmap.Free;
    end;
  finally
    MainForm.Free;
  end;
end;

procedure TestOptionsDialogLifecycle;
var
  I: Integer;
  Options: TfrmOptions;
begin
  for I := 1 to 3 do
  begin
    ShowOptions('TfrmOptionsLanguage');
    Options := GetOptionsForm;
    Check(Assigned(Options), 'options dialog did not open');
    try
      Check(not Options.ShowHint, 'options dialog enables inherited hints');
      Application.ProcessMessages;
      Check(not Options.ShowHint, 'shown options dialog enables inherited hints');
    finally
      Options.ModalResult := mrCancel;
      Options.Close;
      Application.ProcessMessages;
    end;
    Check(GetOptionsForm = nil, 'options dialog did not close');
  end;
end;

begin
  if (ParamCount <> 1) or (Copy(ParamStr(1), 1, 13) <> '--config-dir=') or
     (Length(ParamStr(1)) <= 13) then
    raise Exception.Create('Usage: ui_theme_regression --config-dir=<scratch-directory>');
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
  gpPixmapPath := ExpandFileName(ExtractFilePath(ParamStr(0)) + '../../../pixmaps') + PathDelim;
  gpLngDir := ExpandFileName(ExtractFilePath(ParamStr(0)) + '../../../language') + PathDelim;
  LoadPixMapManager;
  gListFilesInThread := False;
  gWatchDirs := [];

  WriteLn('START: isolated UI theme regressions (QT_SCALE_FACTOR=',
    GetEnvironmentVariable('QT_SCALE_FACTOR'), ')');
  RunCheck('directory-hotlist button layout', @TestHotlistButtonLayout);
  RunCheck('main form navigation and free-space rendering', @TestMainFormAndFreeSpaceRendering);
  RunCheck('options dialog tooltip lifecycle', @TestOptionsDialogLifecycle);
  if Failures > 0 then Halt(1);
  WriteLn('PASS: isolated UI theme regressions');
end.
