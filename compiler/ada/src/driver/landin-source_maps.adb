with GNAT.SHA256;

with Landin.Byte_Encoding;
with Landin.IR;
with Landin.Source;
with Landin.Backend.Toolchain;

package body Landin.Source_Maps is
   package US renames Ada.Strings.Unbounded;
   use type Landin.Source.Line_Number;
   LF : constant Character := Character'Val (10);

   function Hex (Value : String) return String
     renames Landin.Byte_Encoding.Hex;

   procedure Update_Assembly
     (Hash : in out GNAT.SHA256.Context;
      Assembly : US.Unbounded_String);

   procedure Update_Assembly
     (Hash : in out GNAT.SHA256.Context;
      Assembly : US.Unbounded_String)
   is
      Length : constant Natural := US.Length (Assembly);
      First : Positive := 1;
   begin
      while First <= Length loop
         declare
            Last : constant Positive :=
              (if Length - First < 65_535 then Length else First + 65_535);
         begin
            GNAT.SHA256.Update (Hash, US.Slice (Assembly, First, Last));
            exit when Last = Length;
            First := Last + 1;
         end;
      end loop;
   end Update_Assembly;

   function Create
     (Context : in out Landin.Stages.Compilation;
      Assembly : in out US.Unbounded_String;
      All_Sources : Boolean := False;
      Panic : access constant Landin.Panics.Plan := null;
      Digests : access Landin.Source_Digests.Cache := null) return Artifact
   is
      Files : US.Unbounded_String;
      Unit : Landin.IR.Unit renames Landin.Stages.Code (Context).all;
      Result : Artifact;
      Build_Hash : GNAT.SHA256.Context := GNAT.SHA256.Initial_Context;
      Assembly_Hash : GNAT.SHA256.Context := GNAT.SHA256.Initial_Context;
   begin
      for Index in 1 .. (if All_Sources or Panic /= null
                         then Landin.Stages.Source_Count (Context)
                         else Landin.IR.Caller_Source_Count (Unit))
      loop
         declare
            Id : constant Landin.Source.Source_Id :=
              (if All_Sources or Panic /= null
               then Landin.Stages.Nth_Source (Context, Index)
               else Landin.IR.Caller_Source (Unit, Index));
            Snap : Landin.Source.Snapshot renames
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
              & (if Digests = null
                 then GNAT.SHA256.Digest (Landin.Source.Text (Snap))
                 else Landin.Source_Digests.Digest (Digests.all, Snap))
              & """");
            if Panic /= null then
               US.Append (Files, ",""panic_base"":"
                 & Landin.Panics.Site_Number'Image
                   (Landin.Panics.Base (Panic.all, Id))
                 & ",""byte_length"":"
                 & Landin.Source.Byte_Offset'Image
                   (Landin.Source.Length (Snap))
                 & ",""line_offsets"":[");
               for Line in 1 .. Landin.Source.Line_Count (Snap) loop
                  if Line > 1 then
                     US.Append (Files, ",");
                  end if;
                  US.Append (Files, Landin.Source.Byte_Offset'Image
                    (Landin.Source.Line_Span (Snap, Line).First));
               end loop;
               US.Append (Files, "]");
            end if;
            US.Append (Files, "}");
         end;
      end loop;
      GNAT.SHA256.Update (Build_Hash, "Landin caller files" & LF);
      GNAT.SHA256.Update (Build_Hash, US.To_String (Files));
      GNAT.SHA256.Update (Build_Hash, String'(1 => LF));
      Update_Assembly (Build_Hash, Assembly);
      Result.Build_Id := GNAT.SHA256.Digest (Build_Hash);
      --  Even a path-only or comment-only source change must distinguish
      --  the assembly artifacts. This comment allocates no runtime bytes.
      US.Append (Assembly, "# Landin caller files " & Result.Build_Id & LF);
      US.Append (Assembly, Landin.Backend.Toolchain.Identity_Section
        (Result.Build_Id, Landin.Stages.Target (Context)));
      Update_Assembly (Assembly_Hash, Assembly);
      Result.JSON := US.To_Unbounded_String
        ("{" & LF & "  ""build_id"":""" & Result.Build_Id & """," & LF
         & "  ""assembly_sha256"":"""
         & GNAT.SHA256.Digest (Assembly_Hash)
         & """," & LF & "  ""files"": [" & LF & US.To_String (Files)
         & LF & "  ]" & LF & "}" & LF);
      return Result;
   end Create;
end Landin.Source_Maps;
