unit uTreeFileView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  DCXmlConfig,
  uColumnsFileView;

type

  { TTreeFileView }

  { Columns view with expandable directories (tree-like), phase 0: skeleton }
  TTreeFileView = class(TColumnsFileView)
  public
    procedure SaveConfiguration(AConfig: TXmlConfig; ANode: TXmlNode; ASaveHistory: Boolean); override;
  end;

implementation

{ TTreeFileView }

procedure TTreeFileView.SaveConfiguration(AConfig: TXmlConfig; ANode: TXmlNode; ASaveHistory: Boolean);
begin
  inherited SaveConfiguration(AConfig, ANode, ASaveHistory);
  AConfig.SetAttr(ANode, 'Type', 'tree');
end;

end.
