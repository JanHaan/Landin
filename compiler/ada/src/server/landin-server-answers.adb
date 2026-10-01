with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;

package body Landin.Server.Answers is

   package Diag renames Landin.Diagnostics;
   package J renames Landin.Json;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Diag.Applicability;
   use type J.Integer_Value;
   use type Diag.Severity;
   use type Landin.Source.Source_Id;

   function Capabilities (Unit : Positions.Encoding) return String is
      Written : J.Builder;
   begin
      J.Begin_Object (Written);
      J.Name (Written, "capabilities");
      J.Begin_Object (Written);
      J.Name (Written, "positionEncoding");
      J.Write_String
        (Written, (case Unit is when Positions.UTF_8 => "utf-8",
                                when Positions.UTF_16 => "utf-16"));
      J.Name (Written, "textDocumentSync");
      J.Begin_Object (Written);
      J.Name (Written, "openClose");
      J.Write_Boolean (Written, True);
      J.Name (Written, "change");
      J.Write_Integer (Written, 1);
      J.End_Object (Written);
      J.Name (Written, "definitionProvider");
      J.Write_Boolean (Written, True);
      J.Name (Written, "hoverProvider");
      J.Write_Boolean (Written, True);
      J.Name (Written, "documentFormattingProvider");
      J.Write_Boolean (Written, True);
      J.Name (Written, "codeActionProvider");
      J.Begin_Object (Written);
      J.Name (Written, "codeActionKinds");
      J.Begin_Array (Written);
      J.Write_String (Written, "quickfix");
      J.End_Array (Written);
      J.End_Object (Written);
      J.End_Object (Written);
      J.Name (Written, "serverInfo");
      J.Begin_Object (Written);
      J.Name (Written, "name");
      J.Write_String (Written, "refine");
      J.End_Object (Written);
      J.End_Object (Written);
      return J.Result (Written);
   end Capabilities;

   function Version_Of
     (Store : Landin.Server.Documents.Store; Path : String)
      return Long_Long_Integer
   is
   begin
      for Held of Store.Open loop
         if Unbounded.To_String (Held.Path) = Path then
            return Held.Version;
         end if;
      end loop;
      return -1;
   end Version_Of;

   --  A range over Text, as the editor counts it.
   procedure Write_Range
     (Written : in out J.Builder;
      Text    : String;
      Where   : Landin.Source.Span;
      Unit    : Positions.Encoding);

   procedure Write_Range
     (Written : in out J.Builder;
      Text    : String;
      Where   : Landin.Source.Span;
      Unit    : Positions.Encoding)
   is
      procedure Write_Position (Offset : Landin.Source.Byte_Offset);

      procedure Write_Position (Offset : Landin.Source.Byte_Offset) is
         At_Position : constant Positions.Position :=
           Positions.Position_Of (Text, Offset, Unit);
      begin
         J.Begin_Object (Written);
         J.Name (Written, "line");
         J.Write_Integer (Written, Long_Long_Integer (At_Position.Line));
         J.Name (Written, "character");
         J.Write_Integer (Written, Long_Long_Integer (At_Position.Character));
         J.End_Object (Written);
      end Write_Position;
   begin
      J.Begin_Object (Written);
      J.Name (Written, "start");
      Write_Position (Where.First);
      J.Name (Written, "end");
      Write_Position (Where.Last);
      J.End_Object (Written);
   end Write_Range;

   --  The text of Source, through the set the compilation keeps.
   function Text_Of
     (Sources : not null access constant Landin.Source.Sets.Source_Set;
      Source  : Landin.Source.Source_Id) return String
     is (Landin.Source.Text (Sources.Get (Source).Element.all));

   function Name_Of
     (Sources : not null access constant Landin.Source.Sets.Source_Set;
      Source  : Landin.Source.Source_Id) return String
     is (Landin.Source.Name (Sources.Get (Source).Element.all));

   --  Every edit of One, grouped by document, as a WorkspaceEdit.
   procedure Write_Edit
     (Written : in out J.Builder;
      One     : Diag.Fix;
      Sources : not null access constant Landin.Source.Sets.Source_Set;
      Store   : Landin.Server.Documents.Store;
      Unit    : Positions.Encoding);

   procedure Write_Edit
     (Written : in out J.Builder;
      One     : Diag.Fix;
      Sources : not null access constant Landin.Source.Sets.Source_Set;
      Store   : Landin.Server.Documents.Store;
      Unit    : Positions.Encoding)
   is
      package Source_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Landin.Source.Source_Id);
      Documents : Source_Maps.Map;
   begin
      for Index in 1 .. Diag.Edit_Count (One) loop
         declare
            Source : constant Landin.Source.Source_Id :=
              Diag.Source_Of (Diag.Nth_Edit (One, Index));
         begin
            Documents.Include
              (Landin.Server.Documents.URI_For
                 (Store, Name_Of (Sources, Source)), Source);
         end;
      end loop;
      J.Begin_Object (Written);
      J.Name (Written, "changes");
      J.Begin_Object (Written);
      for Position in Documents.Iterate loop
         J.Name (Written, Source_Maps.Key (Position));
         J.Begin_Array (Written);
         for Index in 1 .. Diag.Edit_Count (One) loop
            declare
               Change : constant Diag.Edit := Diag.Nth_Edit (One, Index);
            begin
               if Diag.Source_Of (Change) = Source_Maps.Element (Position)
               then
                  J.Begin_Object (Written);
                  J.Name (Written, "range");
                  Write_Range
                    (Written,
                     Text_Of (Sources, Diag.Source_Of (Change)),
                     Diag.Span_Of (Change), Unit);
                  J.Name (Written, "newText");
                  J.Write_String (Written, Diag.Replacement (Change));
                  J.End_Object (Written);
               end if;
            end;
         end loop;
         J.End_Array (Written);
      end loop;
      J.End_Object (Written);
      J.End_Object (Written);
   end Write_Edit;

   --  One Diagnostic, its range and related information in Sources.
   procedure Write_Diagnostic
     (Written : in out J.Builder;
      Item    : Diag.Diagnostic;
      Sources : not null access constant Landin.Source.Sets.Source_Set;
      Store   : Landin.Server.Documents.Store;
      Unit    : Positions.Encoding;
      Explain : String);

   procedure Write_Diagnostic
     (Written : in out J.Builder;
      Item    : Diag.Diagnostic;
      Sources : not null access constant Landin.Source.Sets.Source_Set;
      Store   : Landin.Server.Documents.Store;
      Unit    : Positions.Encoding;
      Explain : String)
   is
      Primary : constant Diag.Label := Diag.Primary (Item);
      Message : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String (Diag.Message (Primary));
   begin
      for Index in 1 .. Diag.Note_Count (Item) loop
         Unbounded.Append
           (Message, ASCII.LF & "note: " & Diag.Nth_Note (Item, Index));
      end loop;
      J.Begin_Object (Written);
      J.Name (Written, "range");
      Write_Range
        (Written, Text_Of (Sources, Diag.Source_Of (Primary)),
         Diag.Span_Of (Primary), Unit);
      J.Name (Written, "severity");
      J.Write_Integer
        (Written,
         (case Diag.Level (Item) is
            when Diag.Error => 1, when Diag.Warning => 2,
            when Diag.Note => 3));
      J.Name (Written, "code");
      J.Write_String (Written, Diag.Code (Item));
      J.Name (Written, "codeDescription");
      J.Begin_Object (Written);
      J.Name (Written, "href");
      J.Write_String
        (Written, Explain & Ada.Characters.Handling.To_Lower
                              (Diag.Code (Item)));
      J.End_Object (Written);
      J.Name (Written, "source");
      J.Write_String (Written, "refine");
      J.Name (Written, "message");
      J.Write_String (Written, Unbounded.To_String (Message));
      if Diag.Label_Count (Item) > 0 then
         J.Name (Written, "relatedInformation");
         J.Begin_Array (Written);
         for Index in 1 .. Diag.Label_Count (Item) loop
            declare
               Extra : constant Diag.Label := Diag.Nth_Label (Item, Index);
               Source : constant Landin.Source.Source_Id :=
                 Diag.Source_Of (Extra);
            begin
               if Source /= Landin.Source.No_Source then
                  J.Begin_Object (Written);
                  J.Name (Written, "location");
                  J.Begin_Object (Written);
                  J.Name (Written, "uri");
                  J.Write_String
                    (Written, Landin.Server.Documents.URI_For
                       (Store, Name_Of (Sources, Source)));
                  J.Name (Written, "range");
                  Write_Range
                    (Written, Text_Of (Sources, Source),
                     Diag.Span_Of (Extra), Unit);
                  J.End_Object (Written);
                  J.Name (Written, "message");
                  J.Write_String (Written, Diag.Message (Extra));
                  J.End_Object (Written);
               end if;
            end;
         end loop;
         J.End_Array (Written);
      end if;
      J.End_Object (Written);
   end Write_Diagnostic;

   function Diagnostics
     (URI     : String;
      Version : Long_Long_Integer;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Source  : Landin.Source.Source_Id;
      Sources : not null access constant Landin.Source.Sets.Source_Set;
      Store   : Landin.Server.Documents.Store;
      Unit    : Positions.Encoding) return String
   is
      Written : J.Builder;
   begin
      J.Begin_Object (Written);
      J.Name (Written, "jsonrpc");
      J.Write_String (Written, "2.0");
      J.Name (Written, "method");
      J.Write_String (Written, "textDocument/publishDiagnostics");
      J.Name (Written, "params");
      J.Begin_Object (Written);
      J.Name (Written, "uri");
      J.Write_String (Written, URI);
      if Version >= 0 then
         J.Name (Written, "version");
         J.Write_Integer (Written, Version);
      end if;
      J.Name (Written, "diagnostics");
      J.Begin_Array (Written);
      for Index in 1 .. Found.Count loop
         declare
            Item : constant Diag.Diagnostic := Found.Get (Index);
         begin
            if Diag.Source_Of (Diag.Primary (Item)) = Source then
               Write_Diagnostic
                 (Written, Item, Sources, Store, Unit, Explanations);
            end if;
         end;
      end loop;
      J.End_Array (Written);
      J.End_Object (Written);
      J.End_Object (Written);
      return J.Result (Written);
   end Diagnostics;

   function Cleared (URI : String) return String
     is ("{""jsonrpc"":""2.0"",""method"":""textDocument/publishDiagnostics"","
         & """params"":{""uri"":" & J.Quoted (URI) & ",""diagnostics"":[]}}");

   function Formatting
     (Laid : Landin.Formatting.Result;
      Text : String;
      Unit : Positions.Encoding) return String
   is
      use type Landin.Formatting.Verdict;
      Written : J.Builder;
   begin
      if Laid.Outcome = Landin.Formatting.Refused then
         return "null";
      end if;
      J.Begin_Array (Written);
      for Change of Laid.Edits loop
         J.Begin_Object (Written);
         J.Name (Written, "range");
         Write_Range (Written, Text, Diag.Span_Of (Change), Unit);
         J.Name (Written, "newText");
         J.Write_String (Written, Diag.Replacement (Change));
         J.End_Object (Written);
      end loop;
      J.End_Array (Written);
      return J.Result (Written);
   end Formatting;

   --  The byte offset params.position names in Text, or -1 when it names
   --  none.
   function Offset_Asked
     (Message : J.Document; Params : J.Value; Text : String;
      Name    : String; Unit : Positions.Encoding) return Integer;

   function Offset_Asked
     (Message : J.Document; Params : J.Value; Text : String;
      Name    : String; Unit : Positions.Encoding) return Integer
   is
      Where : constant J.Value := J.Member (Message, Params, Name);
      Line  : constant J.Value := J.Member (Message, Where, "line");
      Char  : constant J.Value := J.Member (Message, Where, "character");
   begin
      if not J.Is_Integer (Message, Line)
        or else not J.Is_Integer (Message, Char)
        or else J.Integer_Of (Message, Line) < 0
        or else J.Integer_Of (Message, Char) < 0
        or else J.Integer_Of (Message, Line) > J.Integer_Value (Natural'Last)
        or else J.Integer_Of (Message, Char) > J.Integer_Value (Natural'Last)
      then
         return -1;
      end if;
      return Integer
        (Positions.Offset_Of
           (Text,
            (Line      => Natural (J.Integer_Of (Message, Line)),
             Character => Natural (J.Integer_Of (Message, Char))),
            Unit));
   end Offset_Asked;

   --  The compilation's identity for the document at URI, or No_Source.
   function Source_For
     (Context : Landin.Stages.Compilation;
      Store   : Landin.Server.Documents.Store;
      URI     : String) return Landin.Source.Source_Id;

   function Source_For
     (Context : Landin.Stages.Compilation;
      Store   : Landin.Server.Documents.Store;
      URI     : String) return Landin.Source.Source_Id
   is
      Path : constant String :=
        Landin.Server.Documents.Held_Path (Store, URI);
   begin
      for Index in 1 .. Landin.Stages.Source_Count (Context) loop
         declare
            Id : constant Landin.Source.Source_Id :=
              Landin.Stages.Nth_Source (Context, Index);
         begin
            if Landin.Source.Name
                 (Landin.Stages.Source (Context, Id).Element.all) = Path
            then
               return Id;
            end if;
         end;
      end loop;
      return Landin.Source.No_Source;
   end Source_For;

   function Code_Actions
     (Message : J.Document;
      Params  : J.Value;
      URI     : String;
      Context : Landin.Stages.Compilation;
      Answer  : Landin.Server.Analysis.Result;
      Store   : Landin.Server.Documents.Store;
      Unit    : Positions.Encoding) return String;

   function Code_Actions
     (Message : J.Document;
      Params  : J.Value;
      URI     : String;
      Context : Landin.Stages.Compilation;
      Answer  : Landin.Server.Analysis.Result;
      Store   : Landin.Server.Documents.Store;
      Unit    : Positions.Encoding) return String
   is
      Source  : constant Landin.Source.Source_Id :=
        Source_For (Context, Store, URI);
      Sources : constant not null access constant
        Landin.Source.Sets.Source_Set := Landin.Stages.Sources (Context);
      Asked   : constant J.Value := J.Member (Message, Params, "range");
      Written : J.Builder;
   begin
      if Source = Landin.Source.No_Source then
         return "[]";
      end if;
      declare
         Text  : constant String := Text_Of (Sources, Source);
         First : constant Integer :=
           Offset_Asked (Message, Asked, Text, "start", Unit);
         Last  : constant Integer :=
           Offset_Asked (Message, Asked, Text, "end", Unit);
      begin
         if First < 0 or else Last < First then
            return "[]";
         end if;
         J.Begin_Array (Written);
         for Index in 1 .. Answer.Found.Count loop
            declare
               Item  : constant Diag.Diagnostic := Answer.Found.Get (Index);
               Where : constant Landin.Source.Span :=
                 Diag.Span_Of (Diag.Primary (Item));
            begin
               if Diag.Source_Of (Diag.Primary (Item)) = Source
                 and then Natural (Where.First) <= Last
                 and then First <= Natural (Where.Last)
               then
                  for Position in 1 .. Diag.Fix_Count (Item) loop
                     declare
                        One : constant Diag.Fix :=
                          Diag.Nth_Fix (Item, Position);
                     begin
                        J.Begin_Object (Written);
                        J.Name (Written, "title");
                        J.Write_String (Written, Diag.Message (One));
                        J.Name (Written, "kind");
                        J.Write_String (Written, "quickfix");
                        J.Name (Written, "diagnostics");
                        J.Begin_Array (Written);
                        Write_Diagnostic
                          (Written, Item, Sources, Store, Unit,
                           Explanations);
                        J.End_Array (Written);
                        J.Name (Written, "isPreferred");
                        J.Write_Boolean
                          (Written, Diag.Level (One) = Diag.Exact);
                        J.Name (Written, "edit");
                        Write_Edit (Written, One, Sources, Store, Unit);
                        J.End_Object (Written);
                     end;
                  end loop;
               end if;
            end;
         end loop;
         J.End_Array (Written);
         return J.Result (Written);
      end;
   end Code_Actions;

   function Query
     (Method  : String;
      Message : Landin.Json.Document;
      Params  : Landin.Json.Value;
      URI     : String;
      Context : in out Landin.Stages.Compilation;
      Answer  : Landin.Server.Analysis.Result;
      Store   : Landin.Server.Documents.Store;
      Unit    : Positions.Encoding) return String
   is
   begin
      if Method = "textDocument/codeAction" then
         return Code_Actions
           (Message, Params, URI, Context, Answer, Store, Unit);
      end if;
      return "null";
   end Query;

end Landin.Server.Answers;
