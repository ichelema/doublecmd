unit uTreeFileView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Controls,
  DCXmlConfig,
  uDisplayFile, uFileView, uColumnsFileView;

type

  { TTreeFileView }

  { Columns view with expandable directories.
    Phase 1: expander triangles and click hit-test; children not listed yet. }
  TTreeFileView = class(TColumnsFileView)
  private
    FExpandedPaths: TStringList;
    function ExpanderWidth: Integer;
    function IsExpandable(AFile: TDisplayFile): Boolean;
    function IsExpanded(AFile: TDisplayFile): Boolean;
    procedure ToggleExpanded(AFile: TDisplayFile);
  protected
    procedure CreateDefault(AOwner: TWinControl); override;
    procedure DecorateIconCell(ACanvas: TCanvas; AFile: TDisplayFile; var CellRect: TRect); override;
    procedure MainControlMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure AfterChangePath; override;
  public
    destructor Destroy; override;
    function Clone(NewParent: TWinControl): TColumnsFileView; override;
    procedure CloneTo(FileView: TFileView); override;
    procedure SaveConfiguration(AConfig: TXmlConfig; ANode: TXmlNode; ASaveHistory: Boolean); override;
  end;

implementation

uses
  Math, uGlobs;

{ TTreeFileView }

procedure TTreeFileView.CreateDefault(AOwner: TWinControl);
begin
  inherited CreateDefault(AOwner);
  FExpandedPaths := TStringList.Create;
  FExpandedPaths.CaseSensitive := FileNameCaseSensitive;
end;

destructor TTreeFileView.Destroy;
begin
  inherited Destroy;
  FreeAndNil(FExpandedPaths);
end;

function TTreeFileView.ExpanderWidth: Integer;
begin
  Result := Max(gIconsSize, 12);
end;

function TTreeFileView.IsExpandable(AFile: TDisplayFile): Boolean;
begin
  Result := (AFile.FSFile.IsDirectory or AFile.FSFile.IsLinkToDirectory) and
            (AFile.FSFile.Name <> '..');
end;

function TTreeFileView.IsExpanded(AFile: TDisplayFile): Boolean;
begin
  Result := Assigned(FExpandedPaths) and
            (FExpandedPaths.IndexOf(AFile.FSFile.FullPath) >= 0);
end;

procedure TTreeFileView.ToggleExpanded(AFile: TDisplayFile);
var
  Index: Integer;
begin
  if not Assigned(FExpandedPaths) then Exit;
  Index := FExpandedPaths.IndexOf(AFile.FSFile.FullPath);
  if Index >= 0 then
    FExpandedPaths.Delete(Index)
  else
    FExpandedPaths.Add(AFile.FSFile.FullPath);
  dgPanel.Invalidate;
end;

procedure TTreeFileView.DecorateIconCell(ACanvas: TCanvas; AFile: TDisplayFile; var CellRect: TRect);
var
  cx, cy, h: Integer;
  P: array[0..2] of TPoint;
begin
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
  Idx: Integer;
  R: TRect;
begin
  if Button = mbLeft then
  begin
    dgPanel.MouseToCell(X, Y, ACol, ARow);
    Idx := dgPanel.CellToIndex(ACol, ARow);
    if IsFileIndexInRange(Idx) then
    begin
      R := dgPanel.CellRect(0, ARow);
      if (X >= R.Left) and (X < R.Left + ExpanderWidth) and IsExpandable(FFiles[Idx]) then
      begin
        if not (ssDouble in Shift) then
          ToggleExpanded(FFiles[Idx]);
        Exit; // click handled: no selection/drag from the expander strip
      end;
    end;
  end;
  inherited MainControlMouseDown(Sender, Button, Shift, X, Y);
end;

procedure TTreeFileView.AfterChangePath;
begin
  inherited AfterChangePath;
  if Assigned(FExpandedPaths) then
    FExpandedPaths.Clear;
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
