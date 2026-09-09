with Ada.Strings.Unbounded;
with GNAT.SHA256;
with Landin.Byte_Encoding;
with Landin.Provenance;
with Landin.Source;

package body Landin.Build_Reports.Sources is
   package US renames Ada.Strings.Unbounded;
   LF : constant Character := Character'Val (10);

   function Hex (Text : String) return String
     renames Landin.Byte_Encoding.Hex;

   function JSON
     (Of_Report : Report;
      Context : in out Landin.Stages.Compilation;
      Options : Landin.Optimization.Options) return String
   is
      Unit : Landin.IR.Unit renames Landin.Stages.Code (Context).all;
      Result : US.Unbounded_String;
   begin
      US.Append (Result, "{""schema"":1,""build"":"
        & Landin.Build_Reports.JSON
          (Of_Report, Landin.Stages.Target (Context), Options)
        & ",""sources"":[" & LF);
      for Index in 1 .. Landin.Stages.Source_Count (Context) loop
         declare
            Id : constant Landin.Source.Source_Id :=
              Landin.Stages.Nth_Source (Context, Index);
            Snapshot : constant Landin.Source.Snapshot :=
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
              & GNAT.SHA256.Digest (Landin.Source.Text (Snapshot)) & """}");
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
              & ",""source"":" & Landin.Source.Source_Id'Image (Site.Source)
              & ",""first"":" & Landin.Source.Byte_Offset'Image
                (Site.Where.First)
              & ",""last"":" & Landin.Source.Byte_Offset'Image
                (Site.Where.Last) & "}");
         end;
      end loop;
      US.Append (Result, "]}" & LF);
      return US.To_String (Result);
   end JSON;
end Landin.Build_Reports.Sources;
