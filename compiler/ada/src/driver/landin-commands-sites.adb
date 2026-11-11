with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.SHA256;
with Interfaces;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Text;
with Landin.Json;
with Landin.Source.Sets;

package body Landin.Commands.Sites is
   package US renames Ada.Strings.Unbounded;
   package Cat renames Landin.Diagnostics.Catalogue;
   package J renames Landin.Json;
   use type Interfaces.Unsigned_64;
   use type US.Unbounded_String;
   use type J.Integer_Value;
   use type Landin.Platform.Read_Status;

   LF : constant Character := Character'Val (10);

   --  A file that ends before what its own headers promise.
   Truncated : exception;

   type Artifact_Kind is (Assembly, ELF, Mach_O_Executable, Mach_O_Symbols);

   type Identity is record
      Kind     : Artifact_Kind := Assembly;
      --  The 64 hexadecimal digits the build was given, or "".
      Build_Id : US.Unbounded_String;
      --  A Mach-O's LC_UUID in hexadecimal, or "".
      UUID     : US.Unbounded_String;
   end record;

   Digits_16 : constant String := "0123456789abcdef";

   function Hex (Bytes : String) return String;
   function Hex (Bytes : String) return String is
      Result : String (1 .. 2 * Bytes'Length);
      Next : Positive := 1;
   begin
      for Byte of Bytes loop
         Result (Next) := Digits_16 (Character'Pos (Byte) / 16 + 1);
         Result (Next + 1) := Digits_16 (Character'Pos (Byte) mod 16 + 1);
         Next := Next + 2;
      end loop;
      return Result;
   end Hex;

   function Is_Digest (Text : String) return Boolean is
     (Text'Length = 64
      and then (for all C of Text => C in '0' .. '9' | 'a' .. 'f'));

   function Trimmed (Value : J.Integer_Value) return String is
     (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

   --  COUNT little-endian bytes of DATA at the zero-based OFFSET.
   function Word
     (Data : String; Offset : Interfaces.Unsigned_64; Count : Positive)
      return Interfaces.Unsigned_64;
   function Word
     (Data : String; Offset : Interfaces.Unsigned_64; Count : Positive)
      return Interfaces.Unsigned_64
   is
      Value : Interfaces.Unsigned_64 := 0;
   begin
      if Offset > Interfaces.Unsigned_64 (Data'Length)
        or else Interfaces.Unsigned_64 (Data'Length) - Offset
          < Interfaces.Unsigned_64 (Count)
      then
         raise Truncated;
      end if;
      for Index in reverse 1 .. Count loop
         Value := Value * 256 + Character'Pos
           (Data (Data'First + Natural (Offset) + Index - 1));
      end loop;
      return Value;
   end Word;

   --  COUNT bytes of DATA at the zero-based OFFSET.
   function Slice
     (Data : String; Offset, Count : Interfaces.Unsigned_64) return String;
   function Slice
     (Data : String; Offset, Count : Interfaces.Unsigned_64) return String is
   begin
      if Offset > Interfaces.Unsigned_64 (Data'Length)
        or else Interfaces.Unsigned_64 (Data'Length) - Offset < Count
      then
         raise Truncated;
      end if;
      return Data (Data'First + Natural (Offset)
                   .. Data'First + Natural (Offset + Count) - 1);
   end Slice;

   --  The bytes of TEXT before its first NUL.
   function Until_Nul (Text : String) return String;
   function Until_Nul (Text : String) return String is
   begin
      for Index in Text'Range loop
         if Text (Index) = Character'Val (0) then
            return Text (Text'First .. Index - 1);
         end if;
      end loop;
      return Text;
   end Until_Nul;

   --  A little-endian ELF's `.landin_id`, which firmware carries, or its
   --  GNU build ID, which a hosted link is given.
   function ELF_Identity (Data : String) return Identity;
   function ELF_Identity (Data : String) return Identity is
      Wide : constant Boolean := Word (Data, 4, 1) = 2;
      Result : Identity := (Kind => ELF, others => <>);
      Headers : constant Interfaces.Unsigned_64 :=
        (if Wide then Word (Data, 16#28#, 8) else Word (Data, 16#20#, 4));
      Size : constant Interfaces.Unsigned_64 :=
        Word (Data, (if Wide then 16#3A# else 16#2E#), 2);
      Count : constant Interfaces.Unsigned_64 :=
        Word (Data, (if Wide then 16#3C# else 16#30#), 2);
      Names : constant Interfaces.Unsigned_64 :=
        Word (Data, (if Wide then 16#3E# else 16#32#), 2);

      function Offset_Of (Section : Interfaces.Unsigned_64)
         return Interfaces.Unsigned_64 is
        (if Wide then Word (Data, Headers + Section * Size + 16#18#, 8)
         else Word (Data, Headers + Section * Size + 16#10#, 4));
      function Size_Of (Section : Interfaces.Unsigned_64)
         return Interfaces.Unsigned_64 is
        (if Wide then Word (Data, Headers + Section * Size + 16#20#, 8)
         else Word (Data, Headers + Section * Size + 16#14#, 4));
   begin
      if Word (Data, 5, 1) /= 1 or else Size < (if Wide then 64 else 40)
        or else Names >= Count
      then
         raise Truncated;
      end if;
      declare
         Table : constant String :=
           Slice (Data, Offset_Of (Names), Size_Of (Names));
         Note : US.Unbounded_String;
      begin
         for Section in 0 .. Count - 1 loop
            declare
               Name_At : constant Interfaces.Unsigned_64 :=
                 Word (Data, Headers + Section * Size, 4);
               Name : constant String :=
                 (if Name_At >= Interfaces.Unsigned_64 (Table'Length)
                  then ""
                  else Until_Nul
                    (Table (Table'First + Natural (Name_At) .. Table'Last)));
            begin
               if Name = ".landin_id" then
                  Result.Build_Id := US.To_Unbounded_String
                    (Slice (Data, Offset_Of (Section), Size_Of (Section)));
               elsif Name = ".note.gnu.build-id" then
                  declare
                     Body_Of : constant String :=
                       Slice (Data, Offset_Of (Section), Size_Of (Section));
                     Name_Size : constant Interfaces.Unsigned_64 :=
                       Word (Body_Of, 0, 4);
                     Held : constant Interfaces.Unsigned_64 :=
                       Word (Body_Of, 4, 4);
                  begin
                     if Word (Body_Of, 8, 4) = 3 then
                        Note := US.To_Unbounded_String
                          (Hex (Slice
                             (Body_Of, 12 + (Name_Size + 3) / 4 * 4, Held)));
                     end if;
                  end;
               end if;
            end;
         end loop;
         if US.Length (Result.Build_Id) = 0 then
            Result.Build_Id := Note;
         end if;
      end;
      return Result;
   end ELF_Identity;

   --  A thin arm64 Mach-O's UUID and, of an executable, the digest in
   --  `__TEXT,__landin_id`.
   function Mach_O_Identity (Data : String) return Identity;
   function Mach_O_Identity (Data : String) return Identity is
      Kind : constant Interfaces.Unsigned_64 := Word (Data, 12, 4);
      Count : constant Interfaces.Unsigned_64 := Word (Data, 16, 4);
      Extent : constant Interfaces.Unsigned_64 := Word (Data, 20, 4);
      Result : Identity;
      Cursor : Interfaces.Unsigned_64 := 32;
   begin
      if Word (Data, 4, 4) /= 16#0100000C# or else Kind not in 2 | 10
        or else Count > Extent / 8
      then
         raise Truncated;
      end if;
      Result.Kind :=
        (if Kind = 2 then Mach_O_Executable else Mach_O_Symbols);
      for Unused in 1 .. Count loop
         declare
            Command : constant Interfaces.Unsigned_64 :=
              Word (Data, Cursor, 4);
            Length : constant Interfaces.Unsigned_64 :=
              Word (Data, Cursor + 4, 4);
         begin
            if Length < 8 or else Length mod 8 /= 0
              or else Cursor + Length > 32 + Extent
            then
               raise Truncated;
            end if;
            if Command = 16#1B# and then Length = 24 then
               Result.UUID := US.To_Unbounded_String
                 (Hex (Slice (Data, Cursor + 8, 16)));
            elsif Command = 16#19# and then Length >= 72 then
               for Section in 1 .. Word (Data, Cursor + 64, 4) loop
                  declare
                     At_Byte : constant Interfaces.Unsigned_64 :=
                       Cursor + 72 + 80 * (Section - 1);
                  begin
                     if At_Byte + 80 > Cursor + Length then
                        raise Truncated;
                     end if;
                     if Kind = 2
                       and then Until_Nul (Slice (Data, At_Byte, 16))
                         = "__landin_id"
                       and then Until_Nul (Slice (Data, At_Byte + 16, 16))
                         = "__TEXT"
                     then
                        Result.Build_Id := US.To_Unbounded_String
                          (Slice (Data, Word (Data, At_Byte + 48, 4),
                                  Word (Data, At_Byte + 40, 8)));
                     end if;
                  end;
               end loop;
            end if;
            Cursor := Cursor + Length;
         end;
      end loop;
      return Result;
   end Mach_O_Identity;

   function Digest (Data : String) return String;
   function Digest (Data : String) return String is
      Hash : GNAT.SHA256.Context := GNAT.SHA256.Initial_Context;
      First : Positive := Data'First;
   begin
      while First <= Data'Last loop
         declare
            Last : constant Positive :=
              (if Data'Last - First < 65_535 then Data'Last
               else First + 65_535);
         begin
            GNAT.SHA256.Update (Hash, Data (First .. Last));
            First := Last + 1;
         end;
      end loop;
      return GNAT.SHA256.Digest (Hash);
   end Digest;

   ELF_Magic : constant String := Character'Val (16#7F#) & "ELF";
   Mach_O_Magic : constant String :=
     Character'Val (16#CF#) & Character'Val (16#FA#)
     & Character'Val (16#ED#) & Character'Val (16#FE#);

   function Starts (Data, Magic : String) return Boolean is
     (Data'Length >= Magic'Length
      and then Data (Data'First .. Data'First + Magic'Length - 1) = Magic);

   Reasons : constant array (0 .. 4) of access constant String :=
     [new String'("out_of_range"), new String'("overflow"),
      new String'("bad_conversion"), new String'("unreachable"),
      new String'("stack_exhausted")];

   procedure Resolve
     (Artifact, Map_Path, Dsym_Path : String;
      Operands : Landin.Platform.Path_List;
      Host     : Landin.Platform.Filesystem'Class;
      Result   : in out Landin.Driver.Outcome)
   is
      Table_Path : constant String :=
        (if Map_Path = "" then Artifact & ".sources.json" else Map_Path);
      Sources : Landin.Source.Sets.Source_Set;
      Refused : Boolean := False;

      procedure Report (Code : Cat.Code_Name; Message : String);
      procedure Report (Code : Cat.Code_Name; Message : String) is
      begin
         Refused := True;
         Result.Status := Landin.Driver.Status_Reported;
         Result.Found.Append
           (Landin.Diagnostics.Make
              (Code => Cat.Code (Code), Level => Landin.Diagnostics.Error,
               Source => Landin.Source.No_Source,
               Where => Landin.Source.Empty_Span, Message => Message));
         Result.Report := US.To_Unbounded_String
           (Landin.Diagnostics.Text.Render (Result.Found, Sources));
      end Report;

      --  PATH's bytes, or a report naming WHAT it is.
      function Read (Path, What : String) return String;
      function Read (Path, What : String) return String is
         Content : US.Unbounded_String;
         Status : Landin.Platform.Read_Status;
      begin
         Host.Read_File (Path, Content, Status);
         if Status /= Landin.Platform.Read_Ok then
            Report (Cat.Unreadable_Source, "cannot read " & What & " "
                    & Path
                    & (if Status /= Landin.Platform.Not_Found then ""
                       elsif Path = Table_Path and then Map_Path = ""
                       then ": it does not exist; refine compile"
                         & " --panic-map writes it beside its output, and"
                         & " --map=FILE names one elsewhere"
                       else ": it does not exist"));
            return "";
         end if;
         return US.To_String (Content);
      end Read;

      --  DATA's identity, or a report that PATH is cut short.
      function Identify (Path, Data : String) return Identity;
      function Identify (Path, Data : String) return Identity is
      begin
         if Starts (Data, ELF_Magic) then
            return ELF_Identity (Data);
         elsif Starts (Data, Mach_O_Magic) then
            return Mach_O_Identity (Data);
         else
            return (Kind => Assembly, others => <>);
         end if;
      exception
         when Truncated =>
            Report (Cat.Site_Build_Mismatch, Path & " is not a complete"
                    & " little-endian ELF or thin arm64 Mach-O file, so"
                    & " it names no build");
            return (Kind => Assembly, others => <>);
      end Identify;

      Document : J.Document;

      procedure Bad_Table (Why : String);
      procedure Bad_Table (Why : String) is
      begin
         Report (Cat.Site_Table_Invalid, Table_Path & " is not a source"
                 & " table refine wrote: " & Why);
      end Bad_Table;

      function Text_Member (Name : String) return String;
      function Text_Member (Name : String) return String is
         Item : constant J.Value :=
           J.Member (Document, J.Root (Document), Name);
      begin
         return (if J.Is_Kind (Document, Item, J.String_Value)
                 then J.Text (Document, Item) else "");
      end Text_Member;

      --  A natural number written in decimal, or after 0x in
      --  hexadecimal; Ok says whether TEXT was one below 2 ** 53.
      procedure Number
        (Text : String; Value : out J.Integer_Value; Ok : out Boolean);
      procedure Number
        (Text : String; Value : out J.Integer_Value; Ok : out Boolean)
      is
         Sixteen : constant Boolean :=
           Text'Length > 2
           and then Text (Text'First .. Text'First + 1) in "0x" | "0X";
         Base : constant J.Integer_Value := (if Sixteen then 16 else 10);
         First : constant Positive :=
           (if Sixteen then Text'First + 2 else Text'First);
      begin
         Value := 0;
         Ok := First <= Text'Last;
         for Index in First .. Text'Last loop
            declare
               C : constant Character := Text (Index);
               Digit : constant Integer :=
                 (if C in '0' .. '9'
                  then Character'Pos (C) - Character'Pos ('0')
                  elsif Sixteen and then C in 'a' .. 'f'
                  then Character'Pos (C) - Character'Pos ('a') + 10
                  elsif Sixteen and then C in 'A' .. 'F'
                  then Character'Pos (C) - Character'Pos ('A') + 10
                  else -1);
            begin
               if Digit < 0 or else Value > J.Largest_Integer / 16 - 1 then
                  Ok := False;
                  return;
               end if;
               Value := Value * Base + J.Integer_Value (Digit);
            end;
         end loop;
      end Number;

      --  The integer member NAME of the file entry ITEM, or -1.
      function Field (Item : J.Value; Name : String)
         return J.Integer_Value;
      function Field (Item : J.Value; Name : String)
         return J.Integer_Value
      is
         Found : constant J.Value := J.Member (Document, Item, Name);
      begin
         return (if J.Is_Present (Found)
                   and then J.Is_Integer (Document, Found)
                 then J.Integer_Of (Document, Found) else -1);
      end Field;

      --  The path bytes of the file entry ITEM, or "" with a report.
      function Path_Of (Item : J.Value) return String;
      function Path_Of (Item : J.Value) return String is
         Found : constant J.Value := J.Member (Document, Item, "path_hex");
      begin
         if not J.Is_Kind (Document, Found, J.String_Value) then
            Bad_Table ("a file has no path_hex");
            return "";
         end if;
         declare
            Written : constant String := J.Text (Document, Found);
            Bytes : String (1 .. Written'Length / 2);

            function Nibble (C : Character) return Natural is
              (if C in '0' .. '9'
               then Character'Pos (C) - Character'Pos ('0')
               else Character'Pos (C) - Character'Pos ('a') + 10);
         begin
            if Written'Length mod 2 /= 0 or else Written'Length = 0
              or else (for some C of Written =>
                         C not in '0' .. '9' | 'a' .. 'f')
            then
               Bad_Table ("a file's path_hex is not hexadecimal");
               return "";
            end if;
            for Index in Bytes'Range loop
               Bytes (Index) := Character'Val
                 (16 * Nibble (Written (Written'First + 2 * (Index - 1)))
                  + Nibble (Written (Written'First + 2 * Index - 1)));
            end loop;
            return Bytes;
         end;
      end Path_Of;

      Files : J.Value;
   begin
      if Natural (Operands.Length) not in 1 | 3 then
         Result.Status := Landin.Driver.Status_Misuse;
         Result.Report := US.To_Unbounded_String
           ("refine: site resolves one site number, or a file number, a"
            & " line and a column: refine site PROGRAM SITE" & LF);
         return;
      end if;
      declare
         Program : constant String := Read (Artifact, "the build");
         Table : constant String :=
           (if Refused then "" else Read (Table_Path, "the source table"));
         Built : Identity;
      begin
         if Refused then
            return;
         end if;
         J.Parse (Document, Table);
         if not J.Ok (Document) then
            Bad_Table (J.Fault (Document));
            return;
         elsif not J.Is_Kind (Document, J.Root (Document), J.Object_Value)
           or else not Is_Digest (Text_Member ("build_id"))
           or else not Is_Digest (Text_Member ("assembly_sha256"))
           or else not J.Is_Kind
             (Document, J.Member (Document, J.Root (Document), "files"),
              J.Array_Value)
         then
            Bad_Table ("it needs build_id, assembly_sha256 and files");
            return;
         end if;
         Files := J.Member (Document, J.Root (Document), "files");
         Built := Identify (Artifact, Program);
         if Refused then
            return;
         end if;
         --  D192, D1292: the table answers only for the build it was
         --  written with.
         case Built.Kind is
            when Assembly =>
               if Digest (Program) /= Text_Member ("assembly_sha256") then
                  Report (Cat.Site_Build_Mismatch, Artifact & " is not the"
                          & " build " & Table_Path & " was written with:"
                          & " it is neither an ELF or Mach-O file nor the"
                          & " assembly whose SHA-256 the table records");
                  return;
               end if;
            when Mach_O_Symbols =>
               Report (Cat.Site_Build_Mismatch, Artifact & " is a dSYM's"
                       & " DWARF file; name the executable, and this file"
                       & " with --dsym");
               return;
            when ELF | Mach_O_Executable =>
               if US.To_String (Built.Build_Id) /= Text_Member ("build_id")
               then
                  Report (Cat.Site_Build_Mismatch, Artifact
                          & (if US.Length (Built.Build_Id) = 0
                             then " carries no build identity"
                             elsif Is_Digest (US.To_String (Built.Build_Id))
                             then " is build "
                               & US.To_String (Built.Build_Id)
                             else " carries a build identity refine did"
                               & " not write")
                          & ", and " & Table_Path & " was written with build "
                          & Text_Member ("build_id"));
                  return;
               end if;
         end case;
         if Dsym_Path /= "" then
            declare
               Symbols : constant String := Read (Dsym_Path, "the dSYM");
               Debug : Identity;
            begin
               if Refused then
                  return;
               end if;
               Debug := Identify (Dsym_Path, Symbols);
               if Refused then
                  return;
               elsif Built.Kind /= Mach_O_Executable
                 or else Debug.Kind /= Mach_O_Symbols
                 or else US.Length (Built.UUID) = 0
                 or else Debug.UUID /= Built.UUID
               then
                  Report (Cat.Site_Build_Mismatch, Dsym_Path & " is not the"
                          & " dSYM of " & Artifact & ": --dsym names the"
                          & " DWARF file whose UUID a Mach-O executable"
                          & " shares");
                  return;
               end if;
            end;
         end if;
      end;
      declare
         File, Line, Column, Site : J.Integer_Value := 0;
         Ok : Boolean := True;
         Reason : Natural := 0;
         Found : J.Value := J.No_Value;
         Matches : Natural := 0;
      begin
         if Natural (Operands.Length) = 1 then
            Number (Operands.First_Element, Site, Ok);
            if not Ok or else Site >= 2 ** 32 then
               Report (Cat.Site_Unresolved, "`" & Operands.First_Element
                       & "` is not a site: a panic handler's site is a"
                       & " u32");
               return;
            elsif Site = 0 then
               Report (Cat.Site_Unresolved, "site 0 is the compiler's own"
                       & " guard, which no source operation has");
               return;
            end if;
            for Index in 1 .. J.Length (Document, Files) loop
               declare
                  Item : constant J.Value :=
                    J.Element (Document, Files, Index);
                  Base : constant J.Integer_Value :=
                    Field (Item, "panic_base");
                  Length : constant J.Integer_Value :=
                    Field (Item, "byte_length");
               begin
                  if Base >= 0 and then Length >= 0 and then Site >= Base
                    and then Site - Base < 5 * (Length + 1)
                  then
                     Found := Item;
                     Matches := Matches + 1;
                  end if;
               end;
            end loop;
            if Matches /= 1 then
               Report (Cat.Site_Unresolved, "site " & Trimmed (Site)
                       & " is in no file of " & Table_Path
                       & (if (for some Index in
                                1 .. J.Length (Document, Files) =>
                                Field (J.Element (Document, Files, Index),
                                       "panic_base") >= 0)
                          then ""
                          else ", which records no sites: compile with"
                            & " --panic-map"));
               return;
            end if;
            declare
               Offset : constant J.Integer_Value :=
                 (Site - Field (Found, "panic_base")) / 5;
               Starts_At : constant J.Value :=
                 J.Member (Document, Found, "line_offsets");
               Previous, Start : J.Integer_Value := -1;
            begin
               Reason := Natural ((Site - Field (Found, "panic_base")) mod 5);
               File := Field (Found, "file_id");
               if not J.Is_Kind (Document, Starts_At, J.Array_Value)
                 or else J.Length (Document, Starts_At) = 0
               then
                  Bad_Table ("a file with sites has no line_offsets");
                  return;
               end if;
               for Index in 1 .. J.Length (Document, Starts_At) loop
                  declare
                     Item : constant J.Value :=
                       J.Element (Document, Starts_At, Index);
                     Here : constant J.Integer_Value :=
                       (if J.Is_Integer (Document, Item)
                        then J.Integer_Of (Document, Item) else -1);
                  begin
                     if Here <= Previous
                       or else (Index = 1 and then Here /= 0)
                     then
                        Bad_Table ("a file's line_offsets do not ascend"
                                   & " from zero");
                        return;
                     end if;
                     Previous := Here;
                     if Here <= Offset then
                        Line := J.Integer_Value (Index);
                        Start := Here;
                     end if;
                  end;
               end loop;
               Column := Offset - Start + 1;
            end;
         else
            Number (Operands.Element (1), File, Ok);
            if Ok then
               Number (Operands.Element (2), Line, Ok);
            end if;
            if Ok then
               Number (Operands.Element (3), Column, Ok);
            end if;
            if not Ok or else File = 0 or else Line = 0 or else Column = 0
            then
               Report (Cat.Site_Unresolved, "a caller's coordinates are"
                       & " three positive numbers: its file, line and"
                       & " column");
               return;
            end if;
            for Index in 1 .. J.Length (Document, Files) loop
               if Field (J.Element (Document, Files, Index), "file_id")
                 = File
               then
                  Found := J.Element (Document, Files, Index);
                  Matches := Matches + 1;
               end if;
            end loop;
            if Matches /= 1 then
               Report (Cat.Site_Unresolved, "file " & Trimmed (File)
                       & " is not one file of " & Table_Path);
               return;
            end if;
         end if;
         declare
            Path : constant String := Path_Of (Found);
         begin
            if Refused then
               return;
            end if;
            --  The path is filesystem bytes, written as they are.
            Result.Output := US.To_Unbounded_String
              (Path & ":" & Trimmed (Line) & ":" & Trimmed (Column)
               & (if Natural (Operands.Length) = 1
                  then " (" & Reasons (Reason).all & ")" else "") & LF);
         end;
      end;
   end Resolve;

end Landin.Commands.Sites;
