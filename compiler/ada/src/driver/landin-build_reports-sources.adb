with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.SHA256;
with Landin.Backend;
with Landin.Byte_Encoding;
with Landin.Json;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;

package body Landin.Build_Reports.Sources is
   package US renames Ada.Strings.Unbounded;
   LF : constant Character := Character'Val (10);

   function Hex (Text : String) return String
     renames Landin.Byte_Encoding.Hex;

   function Trimmed (Text : String) return String
     is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   --  Why a specialization left an instance's evidence calls
   --  indirect, in words a reader acts on rather than an item number.
   function Why (Reason : Decision_Reason) return String
     is (case Reason is
            when Disabled =>
              "--specialize=off makes no evidence call direct",
            when Address_Exposed =>
              "this instance's address is taken, by a function value, an"
              & " evidence table or an export, so a caller the compiler"
              & " cannot see may hand it another table",
            when Unknown_Evidence =>
              "a caller hands this instance a table the compiler cannot"
              & " prove is the one it was made for",
            when Cost_Threshold =>
              "--specialize=auto judged the direct calls not worth the"
              & " growth at this --optimize; --specialize=all makes them"
              & " direct",
            when Unsupported_Proof =>
              "the proof that this table is constant is one the compiler"
              & " does not make",
            when No_Static_Dispatch | Single_Instance | Forced
               | Profitable =>
              "the table this call reads is not one the instance was made"
              & " with, so it is known only at run time");

   function JSON
     (Of_Report : Report;
      Context : in out Landin.Stages.Compilation;
      Options : Landin.Optimization.Options;
      Firmware : String := "";
      Digests : access Landin.Source_Digests.Cache := null;
      Link : String := "") return String
   is
      Unit : Landin.IR.Unit renames Landin.Stages.Code (Context).all;
      Meanings : Landin.Resolution.Table renames
        Landin.Stages.Meanings (Context).all;
      Names : Landin.Source.Names.Table renames
        Landin.Stages.Identities (Context).all;
      Result : US.Unbounded_String;

      --  An item's name as its symbol spells it (D417's qualified form),
      --  so an instance reads as its routine; "" for one that has none.
      function Name_Of (Id : Landin.IR.Item_Id) return String;

      function Name_Of (Id : Landin.IR.Item_Id) return String is
         use type Landin.IR.Declaration_Id;
         Declared : constant Landin.IR.Declaration_Id :=
           Landin.Backend.Symbol_Declaration (Unit, Id);
      begin
         if Declared = Landin.IR.No_Declaration then
            return "";
         end if;
         return Landin.Backend.Qualified_Symbol
           (Meanings, Declared,
            Landin.Source.Names.Spelling
              (Names, Landin.Resolution.Name_Of (Meanings, Declared)));
      end Name_Of;

      procedure Append_Indirect
        (Id    : Landin.IR.Item_Id;
         Value : Landin.IR.Value_Id;
         First : in out Boolean);

      procedure Append_Indirect
        (Id    : Landin.IR.Item_Id;
         Value : Landin.IR.Value_Id;
         First : in out Boolean)
      is
         use type Landin.IR.Item_Id;
         use type Landin.Source.Source_Id;
         use type Landin.Optimization.Specialization_Mode;
         Site : constant Landin.Provenance.Origin :=
           Landin.IR.Origin_Of (Unit, Id, Value);
         Table : constant Landin.IR.Evidence_Id :=
           Landin.IR.Evidence_Of (Unit, Id, Value);
         Erased : constant Boolean :=
           Landin.IR.Evidence_Is_Erased (Unit, Table);
         Provider : constant Landin.IR.Item_Id :=
           Landin.IR.Evidence_Entry_Target
             (Unit, Table, Landin.IR.Evidence_Entry_Of (Unit, Id, Value));
         Decided : Boolean := False;
         Reason : Decision_Reason := No_Static_Dispatch;
         Where : Landin.Source.Position;
      begin
         for Index in 1 .. Specialization_Count (Of_Report) loop
            if Nth_Specialization (Of_Report, Index).Item = Id then
               Decided := True;
               Reason := Nth_Specialization (Of_Report, Index).Reason;
               exit;
            end if;
         end loop;
         if not First then
            US.Append (Result, ",");
         end if;
         First := False;
         US.Append (Result, LF & "{""routine"":"
           & Landin.Json.Quoted (Name_Of (Id))
           & ",""source"":" & Landin.Source.Source_Id'Image (Site.Source));
         if Site.Source /= Landin.Source.No_Source then
            Where := Landin.Source.Position_Of
              (Landin.Stages.Source (Context, Site.Source),
               Site.Where.First);
            US.Append (Result, ",""line"":"
              & Trimmed (Landin.Source.Line_Number'Image (Where.Line))
              & ",""column"":"
              & Trimmed (Landin.Source.Column_Number'Image (Where.Column)));
         end if;
         if not Erased and then Provider /= Landin.IR.No_Item then
            US.Append (Result, ",""provider"":"
              & Landin.Json.Quoted (Name_Of (Provider)));
         end if;
         US.Append (Result, ",""why"":" & Landin.Json.Quoted
           (if Erased
            then "it calls through `any`, whose value carries its own"
                 & " table, chosen at run time"
            elsif Decided then Why (Reason)
            elsif Options.Specialize = Landin.Optimization.Off
            then Why (Disabled)
            else "this routine is no generic instance, and the table it"
                 & " reads is a value here, not one specialization can"
                 & " replace")
           & "}");
      end Append_Indirect;
   begin
      US.Append (Result, "{""schema"":1,""build"":"
        & Landin.Build_Reports.JSON
          (Of_Report, Landin.Stages.Target (Context),
           Landin.Stages.Level (Context), Options)
        & (if Firmware = "" then "" else ",""firmware"":" & Firmware)
        & (if Link = "" then "" else ",""link"":""" & Link & """")
        & ",""sources"":[" & LF);
      for Index in 1 .. Landin.Stages.Source_Count (Context) loop
         declare
            Id : constant Landin.Source.Source_Id :=
              Landin.Stages.Nth_Source (Context, Index);
            Snapshot : Landin.Source.Snapshot renames
              Landin.Stages.Source (Context, Id);
         begin
            if Index > 1 then
               US.Append (Result, "," & LF);
            end if;
            --  Preserve arbitrary filesystem bytes as the caller map does.
            US.Append (Result, "{""source"":"
              & Landin.Source.Source_Id'Image (Id)
              & ",""path_hex"":""" & Hex (Landin.Source.Name (Snapshot))
              & """,""sha256"":"""
              & (if Digests = null
                 then GNAT.SHA256.Digest (Landin.Source.Text (Snapshot))
                 else Landin.Source_Digests.Digest (Digests.all, Snapshot))
              & """}");
         end;
      end loop;
      US.Append (Result, "],""items"":[" & LF);
      for Index in 1 .. Landin.IR.Item_Count (Unit) loop
         declare
            Id : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            Site : constant Landin.Provenance.Origin :=
              Landin.IR.Origin_Of (Unit, Id);
         begin
            if Index > 1 then
               US.Append (Result, "," & LF);
            end if;
            US.Append (Result, "{""item"":" & Positive'Image (Index)
              & ",""declaration"":" & Landin.IR.Declaration_Id'Image
                (Landin.IR.Declares (Unit, Id))
              & ",""name"":" & Landin.Json.Quoted (Name_Of (Id))
              & ",""source"":" & Landin.Source.Source_Id'Image (Site.Source)
              & ",""first"":" & Landin.Source.Byte_Offset'Image
                (Site.Where.First)
              & ",""last"":" & Landin.Source.Byte_Offset'Image
                (Site.Where.Last) & "}");
         end;
      end loop;
      --  Every evidence call the final program still makes through a
      --  table: the routine it is in, where, which provider the table
      --  holds when that is known, and why it stayed indirect.
      US.Append (Result, "],""left_indirect"":[");
      declare
         use type Landin.IR.Item_Kind;
         use type Landin.IR.Opcode;
         First : Boolean := True;
      begin
         for Index in 1 .. Landin.IR.Item_Count (Unit) loop
            declare
               Id : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            begin
               if Landin.IR.Kind_Of (Unit, Id) = Landin.IR.Routine then
                  for V in 1 .. Landin.IR.Value_Count (Unit, Id) loop
                     declare
                        Value : constant Landin.IR.Value_Id :=
                          Landin.IR.Value_Id (V);
                     begin
                        if Landin.IR.Op_Of (Unit, Id, Value)
                          = Landin.IR.Evidence_Function
                        then
                           Append_Indirect (Id, Value, First);
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
      end;
      US.Append (Result, "]}" & LF);
      return US.To_String (Result);
   end JSON;
end Landin.Build_Reports.Sources;
