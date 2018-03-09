unit exExporterTest;

interface

uses
  Windows, Forms, Classes, SysUtils, IOUtils, JSON, RegularExpressions, xmldom, XMLIntf, XMLDoc, TestFrameWork,
  TestExtensions, GUITesting, GuiTestRunner, exExporter, exZeosDriver, exSerializer, exDefinition, ZConnection,
  ZSqlProcessor, ZScriptParser, uPSRuntime, uPSCompiler;

type
  { TexExporterTest }

  TexExporterTest = class(TTestCase)
  private
    FFixtureDir: String;
    FDriver: TexZeosDriver;
    FConnection: TZConnection;
    procedure PrepareDatabase;
    function CreateExporter(AFileName: String): TexExporter;
    procedure ScriptEngineExecImport(Sender: TObject; se: TPSExec; x: TPSRuntimeClassImporter);
    procedure ScriptEngineCompImport(Sender: TObject; x: TPSPascalCompiler);
  public
    procedure AfterConstruction; override;
    destructor Destroy; override;
  published
    procedure TestStore;
    procedure TestColumnSize;
    procedure TestColumnDelimiter;
    procedure TestJson;
    procedure TestXml;
    procedure TestSQLInsert;
    procedure TestSerializationError;
  end;

implementation

uses
  uPSC_dateutils, uPSR_dateutils, uPSR_DB, uPSC_DB, exScript;


function RemoveMask(AText: string): String;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AText) do
  begin
    if (IsCharAlphaNumeric(AText[I])) then
      Result := Result + AText[I];
  end;

end;

procedure RegisterExtraLibrary_C(S: TPSPascalCompiler);
begin
  S.AddDelphiFunction('function FormatFloat(Const Format : String; Value : Extended) : String;');
  S.AddDelphiFunction('function RemoveMask(AText: string): String;');
  S.AddDelphiFunction('function QuotedStr(const S: string): string;');
end;

procedure RegisterExtraLibrary_R(S: TPSExec);
begin
  S.RegisterDelphiFunction(@FormatFloat, 'FORMATFLOAT', cdRegister);
  S.RegisterDelphiFunction(@RemoveMask, 'REMOVEMASK', cdRegister);
  S.RegisterDelphiFunction(@QuotedStr, 'QUOTEDSTR', cdRegister);
end;

procedure TexExporterTest.AfterConstruction;
begin
  inherited;
  FFixtureDir := TPath.Combine(ExtractFilePath(Application.ExeName), '..\..\tests\fixtures');

  if (not DirectoryExists(FFixtureDir)) then
    CreateDir(FFixtureDir);

  FConnection := TZConnection.Create(nil);
  FConnection.Protocol := 'sqlite-3';
  FConnection.Database := TPath.Combine(ExtractFilePath(Application.ExeName), 'export-test.db');

  FDriver := TexZeosDriver.Create(nil);
  FDriver.Connection := FConnection;

  PrepareDatabase;
end;

destructor TexExporterTest.Destroy;
begin
  FConnection.Free;
  FDriver.Free;
  inherited Destroy;
end;

procedure TexExporterTest.PrepareDatabase;
var
  ASQLProcessor: TZSQLProcessor;
begin
  if (FileExists(FConnection.Database)) then
     DeleteFile(FConnection.Database);

  FConnection.Connected := True;
  ASQLProcessor := TZSQLProcessor.Create(nil);
  try
    ASQLProcessor.DelimiterType := dtDelimiter;
    ASQLProcessor.Connection := FConnection;
    ASQLProcessor.LoadFromFile(TPath.Combine(FFixtureDir, 'database.sql'));
    ASQLProcessor.Execute;
  finally
    ASQLProcessor.Free;
    FConnection.Connected := False;
  end;
end;

function TexExporterTest.CreateExporter(AFileName: String): TexExporter;
begin
  Result := TexExporter.Create(nil);
  Result.LoadFromFile(TPath.Combine(FFixtureDir,  AFileName));
  Result.Driver := FDriver;
  Result.OnScriptCompImport := ScriptEngineCompImport;
  Result.OnScriptExecImport := ScriptEngineExecImport;
end;

procedure TexExporterTest.ScriptEngineCompImport(Sender: TObject; x: TPSPascalCompiler);
begin
  RegisterDatetimeLibrary_C(x);
  RegisterExtraLibrary_C(x);
end;

procedure TexExporterTest.ScriptEngineExecImport(Sender: TObject; se: TPSExec; x: TPSRuntimeClassImporter);
begin
  RegisterDateTimeLibrary_R(se);
  RegisterExtraLibrary_R(se);
end;

procedure TexExporterTest.TestStore;
var
  AExporter: TexExporter;
  ASession: TexSession;
  AFileName: String;
begin

  AExporter := TexExporter.Create(nil);
  try
    AExporter.SerializerClass := TexXmlSerializer;

    with (AExporter.Providers.Add) do
    begin
      Name := 'people-provider';
      SQL.Text := 'select * from people';
    end;

    with (AExporter.Dictionaries.Add) do
    begin
      Name := 'money';
      Expression := 'Result := FormatFloat(''#,0.00'', Value);';
    end;

    with (AExporter.Parameters.Add) do
    begin
      Name := 'param1';
      Value := 1;
    end;

    ASession := AExporter.Sessions.Add;
    with(ASession) do
    begin
      Name := 'people';
      Provider := 'people-provider';
    end;

    with (ASession.Columns.Add) do
    begin
      Name := 'firstName';
      Size := 10;
    end;

    with (ASession.Columns.Add) do
    begin
      Name := 'lastName';
      Size := 10;
    end;

    AFileName := TPath.Combine(FFixtureDir, 'storage.def');

    AExporter.SaveToFile(AFileName);
    CheckTrue(FileExists(AFileName));

    AExporter := TexExporter.Create(nil);
    AExporter.LoadFromFile(AFileName);

    CheckTrue(AExporter.Serializer <> nil);
    CheckEquals(1, AExporter.Providers.Count);
    CheckEquals(1, AExporter.Dictionaries.Count);
    CheckEquals(1, AExporter.Parameters.Count);
    CheckEquals(1, AExporter.Sessions.Count);
    CheckEquals(2, AExporter.Sessions[0].Columns.Count);
  finally
    AExporter.Free;
  end;
end;

procedure TexExporterTest.TestColumnSize;
var
  AExporter: TexExporter;
  AResult: TexResutMap;
  AData: TStrings;
  ALine: String;
begin
  AExporter := CreateExporter('column-size.def');
  try
     AResult := AExporter.Execute;
     CheckEquals(2, AResult.Count);
     CheckTrue(AResult.ContainsKey('people.txt'));

     AData := AResult['people.txt'];
     CheckEquals(3, AData.Count);

     ALine := AData[0];
     CheckEquals(58, Length(ALine));
     CheckEquals('010', Copy(ALine, 1, 3));
     CheckEquals('Christophe', Copy(ALine, 4, 10));
     CheckEquals('Root ', Copy(ALine, 14, 5));
     CheckEquals('20/04/1983', Copy(ALine, 19, 10));
     CheckEquals('00153000', Copy(ALine, 29, 8));
     CheckEquals('Yes', Copy(ALine, 37, 3));
     CheckEquals('Christopher - Root', Copy(ALine, 40, 18));
     CheckEquals('1', Copy(ALine, 58, 1));

     CheckTrue(AResult.ContainsKey('products.txt'));
     AData := AResult['products.txt'];
     CheckEquals(2, AData.Count);

     ALine := AData[0];
     CheckEquals('0000000001', Copy(ALine, 1, 10));
     CheckEquals('Data export extension    ', Copy(ALine, 11, 25));
  finally
    AExporter.Free;
  end;
end;

procedure TexExporterTest.TestColumnDelimiter;
var
  AExporter: TexExporter;
  AResult: TexResutMap;
  AData: TStrings;
  AParts: TArray<String>;
begin
  AExporter := CreateExporter('column-delimiter.def');
  try
    AResult := AExporter.Execute;

    CheckEquals(1, AResult.Count);
    CheckTrue(AResult.ContainsKey('orders.txt'));

    AData := AResult['orders.txt'];
    CheckEquals(5, AData.Count);

    AParts := TRegEx.Split(AData[0], '\|');
    CheckEquals(7, Length(AParts)); // the event adds aditional "|"

    CheckEquals('010', AParts[1]);
    CheckEquals('001', AParts[2]);
    CheckEquals('2015-11-10', AParts[3]);
    CheckEquals('Administrator', AParts[4]);
    CheckEquals('The first order - 1530,00', AParts[5]);

    AParts := TRegEx.Split(AData[1], '\|');
    CheckEquals(7, Length(AParts));

    CheckEquals('020', AParts[1]);
    CheckEquals('1', AParts[2]);
    CheckEquals('2', AParts[3]);
    CheckEquals('10', AParts[4]);
    CheckEquals('20', AParts[5]);
  finally
    AExporter.Free;
  end;
end;

procedure TexExporterTest.TestJson;
var
  ASerializer: TexJsonSerializer;
  AExporter: TexExporter;
  AResult: TexResutMap;
  AJson: TJSONValue;
  ADetails,
  AData: TJSONArray;
  ARow: TJSONObject;
begin
  AExporter := CreateExporter('hierarchical.def');
  try
    AExporter.SerializerClass := TexJsonSerializer;
    ASerializer := TexJsonSerializer(AExporter.Serializer);

    ASerializer.HideRootKeys := True;
    AResult := AExporter.Execute;

    CheckEquals(1, AResult.Count);
    CheckTrue(AResult.ContainsKey('invoices'));

    AJson := TJSONObject.ParseJSONValue(AResult.Items['invoices'].Text);
    CheckTrue(AJson is TJSONArray);

    AData := TJSONArray(AJson);
    CheckEquals(2, AData.Count);

    ASerializer.HideRootKeys := False;
    AResult := AExporter.Execute;

    AJson := TJSONObject.ParseJSONValue(AResult['invoices'].Text);
    CheckTrue(AJson is TJSONObject);

    AData := TJSONArray(TJSONObject(AJson).Values['invoices']);
    ARow := TJSONObject(AData.Items[0]);

    CheckEquals('1', ARow.Values['id'].Value);
    CheckEquals('100', ARow.Values['type'].Value);
    CheckEquals('001', ARow.Values['number'].Value);
    CheckEquals('2015-11-10', ARow.Values['created_at'].Value);
    CheckEquals('The first order', ARow.Values['description'].Value);

    ADetails := TJSONArray(ARow.Values['details']);
    CheckEquals(2, ADetails.Count);

    ARow := TJSONObject(ADetails.Items[0]);
    CheckEquals('2', ARow.Values['id'].Value);
    CheckEquals('200', ARow.Values['type'].Value);
    CheckEquals('1', ARow.Values['product_id'].Value);
    CheckEquals('2', ARow.Values['quantity'].Value);
    CheckEquals('10', ARow.Values['price'].Value);
    CheckEquals('20', ARow.Values['value'].Value);

    ARow := TJSONObject(ADetails.Items[1]);
    CheckEquals('3', ARow.Values['id'].Value);
    CheckEquals('200', ARow.Values['type'].Value);
    CheckEquals('2', ARow.Values['product_id'].Value);
    CheckEquals('5', ARow.Values['quantity'].Value);
    CheckEquals('20', ARow.Values['price'].Value);
    CheckEquals('100', ARow.Values['value'].Value);
  finally
    AExporter.Free;
  end
end;

procedure TexExporterTest.TestXml;
var
  ASerializer: TexXmlSerializer;
  AExporter: TexExporter;
  AResult: TexResutMap;
  AXMLDoc: IXMLDocument;
  ADetails,
  ARoot,
  AItem: IXMLNode;
begin
  AExporter := CreateExporter('hierarchical.def');
  try
    AExporter.SerializerClass := TexXmlSerializer;

    ASerializer := TexXmlSerializer(AExporter);
    ASerializer.Encoding := 'ISO-8859-1';

    AResult := AExporter.Execute;
    CheckEquals(1, AResult.Count);
    CheckTrue(AResult.ContainsKey('invoices'));

    AXMLDoc := LoadXMLData(AResult['invoices'].Text);
    ARoot := AXMLDoc.DocumentElement;

    //CheckEquals('UTF-8', AXMLDoc.Encoding);
    CheckEquals('1.0', AXMLDoc.Version);
    CheckEquals('invoices', ARoot.NodeName);

    CheckEquals(2, ARoot.ChildNodes.Count);
    AItem := ARoot.ChildNodes[0];

    CheckEquals('1', AItem.ChildNodes.FindNode('id').Text);
    CheckEquals('100', AItem.ChildNodes.FindNode('type').Text);
    CheckEquals('001', AItem.ChildNodes.FindNode('number').Text);
    CheckEquals('2015-11-10', AItem.ChildNodes.FindNode('created_at').Text);
    CheckEquals('The first order', AItem.ChildNodes.FindNode('description').Text);

    ADetails := AItem.ChildNodes.FindNode('details');
    CheckEquals(2, ADetails.ChildNodes.Count);

    AItem := ADetails.ChildNodes[0];
    CheckEquals('2', AItem.ChildNodes.FindNode('id').Text);
    CheckEquals('200', AItem.ChildNodes.FindNode('type').Text);
    CheckEquals('1', AItem.ChildNodes.FindNode('product_id').Text);
    CheckEquals('2', AItem.ChildNodes.FindNode('quantity').Text);
    CheckEquals('10', AItem.ChildNodes.FindNode('price').Text);
    CheckEquals('20', AItem.ChildNodes.FindNode('value').Text);

    AItem := ADetails.ChildNodes[1];
    CheckEquals('3', AItem.ChildNodes.FindNode('id').Text);
    CheckEquals('200', AItem.ChildNodes.FindNode('type').Text);
    CheckEquals('2', AItem.ChildNodes.FindNode('product_id').Text);
    CheckEquals('5', AItem.ChildNodes.FindNode('quantity').Text);
    CheckEquals('20', AItem.ChildNodes.FindNode('price').Text);
    CheckEquals('100', AItem.ChildNodes.FindNode('value').Text);
  finally
    AExporter.Free;
  end
end;

procedure TexExporterTest.TestSQLInsert;
var
  AExporter: TexExporter;
  AResult: TexResutMap;
  AData: TStrings;
  ALine,
  AExpected: String;
begin
  AExporter := CreateExporter('sql-insert.def');
  try
    AResult := AExporter.Execute;
    CheckEquals(1, AResult.Count);
    CheckTrue(AResult.ContainsKey('invoices.sql'));

    AData := AResult['invoices.sql'];

    AExpected := Format('insert into invoices_table (number,created_at,description) values (%s,%s,%s);',[
      '001', QuotedStr('2015-11-10'), QuotedStr('The first order')
    ]);

    ALine := AData[0];
    CheckEquals(AExpected, ALine);

    ALine := AData[1];
    CheckEquals('insert into details_table (product_id,quantity,price,value) values (1,2,10,20);', ALine);
  finally
    AExporter.Free;
  end;
end;

procedure TexExporterTest.TestSerializationError;
var
  AExporter: TexExporter;
begin
  AExporter := CreateExporter('error.def');
  try
    try
      AExporter.Execute;
    except
      on E: ESerializeException do
      begin
        CheckEquals('TexColumnSerializer error', E.Message);
        CheckTrue(E.OriginalException <> nil);
        CheckEquals('EScriptException', E.OriginalException.ClassName);

        CheckEquals(
          '[{"id":"1"},'+
          '{"firstName":"Administrator"},'+
          '{"lastName":"Root"},'+
          '{"birthDate":"20/04/1983"},'+
          '{"salary":"1530"},'+
          '{"active":"1"}]', E.Data);
      end;
    end;
  finally
    AExporter.Free;
  end;
end;

initialization
  RegisterTest('exporter', TexExporterTest.Suite);

end.

