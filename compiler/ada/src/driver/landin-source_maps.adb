with GNAT.SHA256;

with Landin.Byte_Encoding;
with Landin.IR;
with Landin.Source;

package body Landin.Source_Maps is
   package US renames Ada.Strings.Unbounded;
   LF : constant Character := Character'Val (10);

   function Hex (Value : String) return String
     renames Landin.Byte_Encoding.Hex;

   function Create
     (Context : in out Landin.Stages.Compilation;
      Assembly : String;
      All_Sources : Boolean := False) return Artifact
   is
      Files : US.Unbounded_String;
      Unit : Landin.IR.Unit renames Landin.Stages.Code (Context).all;
      Result : Artifact;
   begin
      for Index in 1 .. (if All_Sources
                         then Landin.Stages.Source_Count (Context)
                         else Landin.IR.Caller_Source_Count (Unit))
      loop
         declare
            Id : constant Landin.Source.Source_Id :=
              (if All_Sources then Landin.Stages.Nth_Source (Context, Index)
               else Landin.IR.Caller_Source (Unit, Index));
            Snap : constant Landin.Source.Snapshot :=
              Landin.Stages.Source (Context, Id);
         begin
            if Index > 1 then
               US.Append (Files, "," & LF);
            end if;
            --  Hex preserves every path byte, including non-UTF-8 names,
            --  quotes and newlines. The lookup tool decodes filesystem bytes.
            US.Append (Files, "    {""file_id"":"
              & Landin.Source.Source_Id'Image (Id)
              & ",""path_hex"":""" & Hex (Landin.Source.Name (Snap))
              & """,""source_sha256"":"""
              & GNAT.SHA256.Digest (Landin.Source.Text (Snap)) & """}");
         end;
      end loop;
      Result.Build_Id := GNAT.SHA256.Digest
        ("Landin caller files" & LF & US.To_String (Files) & LF & Assembly);
      --  Even a path-only or comment-only source change must distinguish
      --  the assembly artifacts. This comment allocates no runtime bytes.
      Result.Assembly := US.To_Unbounded_String
        (Assembly & "# Landin caller files " & Result.Build_Id & LF);
      Result.JSON := US.To_Unbounded_String
        ("{" & LF & "  ""build_id"":""" & Result.Build_Id & """," & LF
         & "  ""assembly_sha256"":"""
         & GNAT.SHA256.Digest (US.To_String (Result.Assembly))
         & """," & LF & "  ""files"": [" & LF & US.To_String (Files)
         & LF & "  ]" & LF & "}" & LF);
      return Result;
   end Create;
end Landin.Source_Maps;
