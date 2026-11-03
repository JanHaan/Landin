with Ada.Unchecked_Deallocation;
with Landin.Bindings.Clang;
with Landin.Bindings.Generation;
with Landin.Bindings.Policies;
with Landin.Bindings.Texts;

package body Landin.Bindings is

   package C renames Landin.Bindings.Clang;
   package T renames Landin.Bindings.Texts;

   LF : constant Character := ASCII.LF;

   --  Clang's AST nests as deep as the headers' expressions do, and every
   --  level is two of JSON's; this is far past any header and far short of
   --  the reader's stack.
   Ast_Depth : constant := 2_000;

   function Triple (Of_Target : Target) return String is
     (case Of_Target is
         when Linux_X86_64 => "x86_64-pc-linux-gnu",
         when Darwin_Arm64 => "arm64-apple-macos26.0.0",
         when Linux_Arm64 => "aarch64-unknown-linux-gnu");

   function Target_Name (Of_Target : Target) return String is
     (case Of_Target is
         when Linux_X86_64 => "linux-x86-64",
         when Darwin_Arm64 => "darwin-arm64",
         when Linux_Arm64 => "linux-arm64");

   function Fact (Of_Target : Target) return String is
     (case Of_Target is
         when Linux_X86_64 => "c_sysv_lp64",
         when Darwin_Arm64 => "c_darwin_lp64",
         when Linux_Arm64 => "c_aapcs64_lp64");

   function Convention (Of_Target : Target) return String is
     (case Of_Target is
         when Linux_X86_64 => "sysv-amd64",
         when Darwin_Arm64 => "darwin-aapcs64",
         when Linux_Arm64 => "aapcs64");

   function Unsigned_Char (Of_Target : Target) return Boolean is
     (Of_Target = Linux_Arm64);

   function Output_Name (Index : Output_Index) return String is
     (case Index is
         when 1 => "bindings.ldn", when 2 => "adapters.c",
         when 3 => "exports.h", when 4 => "bindings.json");

   function Is_C_Identifier (Text : String) return Boolean is
     (Text'Length > 0
      and then Text (Text'First) in 'A' .. 'Z' | 'a' .. 'z' | '_'
      and then (for all Item of Text =>
                  Item in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_'));

   function Quoted (Text : String) return String renames T.Repr;

   procedure Free is new Ada.Unchecked_Deallocation
     (Session_State, State_Access);

   overriding procedure Finalize (Item : in out Session) is
      Held : State_Access := Item.Data;
   begin
      Free (Held);
   end Finalize;

   procedure Fail
     (Within : Handle; Message : String;
      Kind : Fault_Kind := Declaration_Fault) is
   begin
      Within.Problem := US.To_Unbounded_String (Message);
      Within.Kind := Kind;
      raise Binding_Error;
   end Fail;

   function Ok (Of_Session : Session) return Boolean is
     (not Of_Session.Data.Failed);

   function Fault (Of_Session : Session) return Fault_Kind is
     (if Of_Session.Data.Failed then Of_Session.Data.Kind else No_Fault);

   function Message (Of_Session : Session) return String is
     (US.To_String (Of_Session.Data.Problem));

   --  Run Step unless the session has already failed, and record a fault.
   generic
      with procedure Step (Within : Handle);
   procedure Guarded (Into : in out Session);

   procedure Guarded (Into : in out Session) is
   begin
      if Into.Data.Failed then
         return;
      end if;
      Step (Into.Data);
   exception
      when Binding_Error =>
         Into.Data.Failed := True;
   end Guarded;

   procedure Load_Policy (Into : in out Session; Text : String) is
      procedure Step (Within : Handle);
      procedure Step (Within : Handle) is
      begin
         Policies.Load (Within, Text);
         Within.Stage := Policy_Loaded;
      end Step;
      procedure Run is new Guarded (Step);
   begin
      Run (Into);
   end Load_Policy;

   function Policy_Triple (Of_Session : Session) return String is
     (US.To_String (Of_Session.Data.Target_Triple));

   --  The `#define NAME VALUE` lines of Clang's `-dM` output, as names and
   --  values; a definition with no value is "1".
   procedure Read_Macros
     (Text : String; Names, Values : out String_Vectors.Vector);

   procedure Read_Macros
     (Text : String; Names, Values : out String_Vectors.Vector)
   is
      First : Positive := Text'First;
   begin
      Names.Clear;
      Values.Clear;
      while First <= Text'Last loop
         declare
            Last : Natural := First;
         begin
            while Last <= Text'Last
              and then Text (Last) not in ASCII.LF | ASCII.CR
            loop
               Last := Last + 1;
            end loop;
            declare
               Line : constant String := Text (First .. Last - 1);
               Prefix : constant String := "#define ";
            begin
               if T.Starts_With (Line, Prefix)
                 and then Line'Length > Prefix'Length
                 and then Line (Line'First + Prefix'Length)
                          in 'A' .. 'Z' | 'a' .. 'z' | '_'
               then
                  declare
                     Name_First : constant Positive :=
                       Line'First + Prefix'Length;
                     Name_Last : Natural := Name_First;
                  begin
                     while Name_Last + 1 <= Line'Last
                       and then Line (Name_Last + 1)
                                in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_'
                     loop
                        Name_Last := Name_Last + 1;
                     end loop;
                     if Name_Last = Line'Last then
                        Names.Append (Line (Name_First .. Name_Last));
                        Values.Append ("1");
                     elsif Line (Name_Last + 1) = ' ' then
                        Names.Append (Line (Name_First .. Name_Last));
                        Values.Append
                          ((if Name_Last + 2 > Line'Last then "1"
                            else Line (Name_Last + 2 .. Line'Last)));
                     end if;
                  end;
               end if;
            end;
            First := Last + 1;
            if Last <= Text'Last and then Text (Last) = ASCII.CR
              and then First <= Text'Last and then Text (First) = ASCII.LF
            then
               First := First + 1;
            end if;
         end;
      end loop;
   end Read_Macros;

   procedure Check_Triple
     (Into          : in out Session;
      For_Target    : Target;
      Triple_Output : String)
   is
      procedure Step (Within : Handle);
      procedure Step (Within : Handle) is
         Selected : constant String := T.Strip (Triple_Output);
      begin
         if Selected /= Triple (For_Target) then
            Fail (Within, "Clang selected target " & T.Repr (Selected)
                  & "; required " & T.Repr (Triple (For_Target)),
                  Clang_Fault);
         end if;
      end Step;
      procedure Run is new Guarded (Step);
   begin
      Run (Into);
   end Check_Triple;

   procedure Check_Macros
     (Into       : in out Session;
      For_Target : Target;
      Macros     : String)
   is
      procedure Step (Within : Handle);
      procedure Step (Within : Handle) is
         Names, Values : String_Vectors.Vector;

         function Value_Of (Name : String) return String is
           (if Names.Contains (Name)
            then Values (Names.Reverse_Find_Index (Name)) else "");

         procedure Require (Name, Expected : String);

         procedure Require (Name, Expected : String) is
         begin
            if not Names.Contains (Name) or else Value_Of (Name) /= Expected
            then
               Fail (Within, "unsupported Clang target ABI: " & Name & " is "
                     & (if Names.Contains (Name) then T.Repr (Value_Of (Name))
                        else "None")
                     & ", expected " & T.Repr (Expected), Clang_Fault);
            end if;
         end Require;
      begin
         Read_Macros (Macros, Names, Values);
         Require ("__LP64__", "1");
         Require ("__CHAR_BIT__", "8");
         Require ("__SIZEOF_SHORT__", "2");
         Require ("__SIZEOF_INT__", "4");
         Require ("__SIZEOF_LONG__", "8");
         Require ("__SIZEOF_LONG_LONG__", "8");
         Require ("__SIZEOF_POINTER__", "8");
         Require ("__SIZEOF_SIZE_T__", "8");
         Require ("__SIZEOF_PTRDIFF_T__", "8");
         Require ("__SIZEOF_FLOAT__", "4");
         Require ("__SIZEOF_DOUBLE__", "8");
         Require ("__FLT_RADIX__", "2");
         Require ("__FLT_MANT_DIG__", "24");
         Require ("__DBL_MANT_DIG__", "53");
         case For_Target is
            when Linux_X86_64 =>
               Require ("__x86_64__", "1");
               Require ("__linux__", "1");
               Require ("__ELF__", "1");
            when Darwin_Arm64 =>
               Require ("__aarch64__", "1");
               Require ("__APPLE__", "1");
               Require ("__MACH__", "1");
            when Linux_Arm64 =>
               Require ("__aarch64__", "1");
               Require ("__linux__", "1");
               Require ("__ELF__", "1");
         end case;
         --  Plain char's sign is the ABI's, and a Clang that disagrees with
         --  the row describes some other ABI.
         if Names.Contains ("__CHAR_UNSIGNED__") /= Unsigned_Char (For_Target)
         then
            Fail (Within, "unsupported Clang target ABI: plain char is "
                  & (if Names.Contains ("__CHAR_UNSIGNED__") then "unsigned"
                     else "signed"), Clang_Fault);
         end if;
         if not (Value_Of ("__BYTE_ORDER__") = "__ORDER_LITTLE_ENDIAN__"
                 or else (Names.Contains ("__BYTE_ORDER__")
                          = Names.Contains ("__ORDER_LITTLE_ENDIAN__")
                          and then Value_Of ("__BYTE_ORDER__")
                                   = Value_Of ("__ORDER_LITTLE_ENDIAN__")))
         then
            Fail (Within, "unsupported Clang target ABI: target is not"
                  & " little-endian", Clang_Fault);
         end if;
         Within.Stage := Target_Checked;
      end Step;
      procedure Run is new Guarded (Step);
   begin
      Run (Into);
   end Check_Macros;

   --  A C string literal's characters, as Clang writes a line marker's
   --  file name: backslash escapes, octal among them.
   function Unescape (Literal : String) return String;

   function Unescape (Literal : String) return String is
      Result : US.Unbounded_String;
      Index : Positive := Literal'First + 1;
   begin
      while Index < Literal'Last loop
         if Literal (Index) = '\' and then Index + 1 < Literal'Last then
            declare
               Next : constant Character := Literal (Index + 1);
               Last : Positive := Index + 1;
               Value : Natural := 0;
            begin
               case Next is
                  when 'n' => US.Append (Result, ASCII.LF);
                  when 't' => US.Append (Result, ASCII.HT);
                  when 'r' => US.Append (Result, ASCII.CR);
                  when '0' .. '7' =>
                     while Last < Literal'Last and then Last <= Index + 3
                       and then Literal (Last) in '0' .. '7'
                     loop
                        Value := Value * 8 + Character'Pos (Literal (Last))
                          - Character'Pos ('0');
                        Last := Last + 1;
                     end loop;
                     US.Append (Result, Character'Val (Value mod 256));
                  when others => US.Append (Result, Next);
               end case;
               Index := (if Next in '0' .. '7' then Last else Index + 2);
            end;
         else
            US.Append (Result, Literal (Index));
            Index := Index + 1;
         end if;
      end loop;
      return US.To_String (Result);
   end Unescape;

   --  A path's components, without empty and `.` ones.
   function Components (Path : String) return String_Vectors.Vector;

   function Components (Path : String) return String_Vectors.Vector is
      Result : String_Vectors.Vector;
      First : Positive := Path'First;
   begin
      for Index in Path'First .. Path'Last + 1 loop
         if Index > Path'Last or else Path (Index) = '/' then
            declare
               Part : constant String := Path (First .. Index - 1);
            begin
               if Part /= "" and then Part /= "." then
                  Result.Append (Part);
               end if;
            end;
            First := Index + 1;
         end if;
      end loop;
      return Result;
   end Components;

   function Is_Under (Path, Root : String) return Boolean;

   function Is_Under (Path, Root : String) return Boolean is
      Path_Parts : constant String_Vectors.Vector := Components (Path);
      Root_Parts : constant String_Vectors.Vector := Components (Root);
   begin
      if Natural (Root_Parts.Length) > Natural (Path_Parts.Length) then
         return False;
      end if;
      for Position in 1 .. Natural (Root_Parts.Length) loop
         if Root_Parts (Position) /= Path_Parts (Position) then
            return False;
         end if;
      end loop;
      return True;
   end Is_Under;

   --  `# LINE "FILE"`, Clang's line marker: the quoted file name with its
   --  quotes, or "" when Line is not one.
   function Marker_File (Line : String) return String;

   function Marker_File (Line : String) return String is
      Index : Positive := Line'First + 1;
   begin
      if Line'Length < 2 or else Line (Line'First) /= '#' then
         return "";
      end if;
      if not T.Is_Space (Line (Index)) then
         return "";
      end if;
      while Index <= Line'Last and then T.Is_Space (Line (Index)) loop
         Index := Index + 1;
      end loop;
      if Index > Line'Last or else Line (Index) not in '0' .. '9' then
         return "";
      end if;
      while Index <= Line'Last and then Line (Index) in '0' .. '9' loop
         Index := Index + 1;
      end loop;
      if Index > Line'Last or else not T.Is_Space (Line (Index)) then
         return "";
      end if;
      while Index <= Line'Last and then T.Is_Space (Line (Index)) loop
         Index := Index + 1;
      end loop;
      if Index > Line'Last or else Line (Index) /= '"' then
         return "";
      end if;
      declare
         First : constant Positive := Index;
      begin
         Index := Index + 1;
         while Index <= Line'Last loop
            if Line (Index) = '\' then
               Index := Index + 2;
            elsif Line (Index) = '"' then
               return Line (First .. Index);
            else
               Index := Index + 1;
            end if;
         end loop;
      end;
      return "";
   end Marker_File;

   procedure Strip_Markers
     (Into         : in out Session;
      Preprocessed : String;
      Roots        : Landin.Platform.Path_List;
      Stripped     : out Ada.Strings.Unbounded.Unbounded_String)
   is
      procedure Step (Within : Handle);
      procedure Step (Within : Handle) is
         First : Positive := Preprocessed'First;
      begin
         while First <= Preprocessed'Last loop
            declare
               Last : Natural := First;
               Ending : Natural;
            begin
               while Last <= Preprocessed'Last
                 and then Preprocessed (Last) not in ASCII.LF | ASCII.CR
               loop
                  Last := Last + 1;
               end loop;
               Ending := Last;
               if Ending <= Preprocessed'Last
                 and then Preprocessed (Ending) = ASCII.CR
                 and then Ending + 1 <= Preprocessed'Last
                 and then Preprocessed (Ending + 1) = ASCII.LF
               then
                  Ending := Ending + 1;
               end if;
               declare
                  Line : constant String := Preprocessed (First .. Last - 1);
                  Quoted_File : constant String := Marker_File (Line);
               begin
                  if Quoted_File = "" then
                     US.Append
                       (Stripped,
                        Preprocessed
                          (First .. Natural'Min (Ending, Preprocessed'Last)));
                  else
                     declare
                        Location : constant String := Unescape (Quoted_File);
                     begin
                        if T.Starts_With (Location, "/")
                          and then not (for some Root of Roots =>
                                          Is_Under (Location, Root))
                        then
                           Fail (Within, "unsupported path-sensitive"
                                 & " preprocessing outside explicit roots;"
                                 & " add the transitive header's root with"
                                 & " --include-dir or --system-include-dir",
                                 Clang_Fault);
                        end if;
                     end;
                  end if;
               end;
               First := Ending + 1;
            end;
         end loop;
      end Step;
      procedure Run is new Guarded (Step);
   begin
      Stripped := US.Null_Unbounded_String;
      Run (Into);
   end Strip_Markers;

   procedure Read_Ast
     (Into    : in out Session;
      Ast     : String;
      Headers : Header_Vectors.Vector)
   is
      procedure Step (Within : Handle);
      procedure Step (Within : Handle) is
      begin
         J.Parse (Within.Ast, Ast, Depth_Limit => Ast_Depth);
         if not J.Ok (Within.Ast) then
            Fail (Within, "Clang emitted invalid JSON AST: "
                  & J.Fault (Within.Ast) & " at byte"
                  & Natural'Image (J.Fault_At (Within.Ast)), Clang_Fault);
         end if;
         if not J.Is_Kind (Within.Ast, J.Root (Within.Ast), J.Object_Value)
           or else C.Text (Within, J.Root (Within.Ast), "kind")
                   /= "TranslationUnitDecl"
         then
            Fail (Within, "Clang JSON AST has no translation unit root",
                  Clang_Fault);
         end if;
         Within.Headers := Headers;
         C.Build_Model (Within);
         Generation.Select_Declarations (Within);
         Generation.Collect_Dependencies (Within);
         Within.Probed_Enums := Generation.Probe_Order (Within);
         Within.Probe_Prefix := US.To_Unbounded_String ("landin_enum_probe_");
         while (for some Name of Within.Identifiers =>
                  T.Starts_With (Name, US.To_String (Within.Probe_Prefix)))
         loop
            US.Append (Within.Probe_Prefix, "x_");
         end loop;
         Within.Stage := Ast_Read;
      end Step;
      procedure Run is new Guarded (Step);
   begin
      Run (Into);
   end Read_Ast;

   function Needs_Probe (Of_Session : Session) return Boolean is
     (not Of_Session.Data.Failed
      and then not Of_Session.Data.Probed_Enums.Is_Empty);

   --  The integer types the probe asks about, in the order its answers
   --  number them from one.
   Candidates : constant String_Vectors.Vector :=
     ["char", "signed char",
      "unsigned char", "short",
      "unsigned short", "int",
      "unsigned int", "long",
      "unsigned long", "long long",
      "unsigned long long"];

   procedure Probe_Source
     (Into   : in out Session;
      Text   : String;
      Source : out Ada.Strings.Unbounded.Unbounded_String)
   is
      procedure Step (Within : Handle);
      procedure Step (Within : Handle) is
         Prefix : constant String := US.To_String (Within.Probe_Prefix);
         Queries : String_Vectors.Vector;
         --  Where a tag goes, as offsets into Text, and the tag.
         Offsets : String_Vectors.Vector;
         Tags : String_Vectors.Vector;
      begin
         for Position in 1 .. Natural (Within.Probed_Enums.Length) loop
            declare
               Index : constant Positive :=
                 C.Enum_Index (Within, Within.Probed_Enums (Position));
               Number : constant String :=
                 T.Image (Long_Long_Integer (Position - 1));
               Name : US.Unbounded_String :=
                 US.To_Unbounded_String (C.Enum_C_Name (Within, Index));
               Terms : String_Vectors.Vector;
            begin
               if US.Length (Name) = 0 then
                  declare
                     Location : constant J.Value :=
                       C.Field (Within, Within.Enums (Index).Node, "loc");
                     Offset : constant J.Value :=
                       C.Field (Within, Location, "offset");
                     At_Byte : Natural := 0;
                  begin
                     if J.Is_Integer (Within.Ast, Offset)
                       and then J."<=" (0, J.Integer_Of (Within.Ast, Offset))
                     then
                        At_Byte := Natural (J.Integer_Of (Within.Ast, Offset));
                     end if;
                     if not J.Is_Integer (Within.Ast, Offset)
                       or else Text'Length < At_Byte + 4
                       or else Text (Text'First + At_Byte
                                     .. Text'First + At_Byte + 3) /= "enum"
                     then
                        Fail (Within, "Clang did not provide a usable"
                              & " anonymous enum location", Clang_Fault);
                     end if;
                     Offsets.Append (T.Image (Long_Long_Integer (At_Byte
                       + 4)));
                     Tags.Append (" " & Prefix & "tag_" & Number);
                     Name := US.To_Unbounded_String
                       ("enum " & Prefix & "tag_" & Number);
                  end;
               end if;
               for Code in 1 .. Natural (Candidates.Length) loop
                  Terms.Append
                    (T.Image (Long_Long_Integer (Code))
                     & " * __builtin_types_compatible_p("
                     & US.To_String (Name) & ", " & Candidates (Code)
                     & ")");
               end loop;
               Queries.Append
                 ("enum { " & Prefix & "type_" & Number & " = "
                  & T.Join (Terms, " + ") & " };");
            end;
         end loop;
         --  Insert the tags from the last offset back, so each offset is
         --  still the one Clang gave.
         declare
            Edited : US.Unbounded_String := US.To_Unbounded_String (Text);
            Done : array (1 .. Natural (Offsets.Length)) of Boolean :=
              [others => False];
         begin
            for Unused_Round in 1 .. Natural (Offsets.Length) loop
               declare
                  Best : Natural := 0;
               begin
                  for Position in Done'Range loop
                     if not Done (Position)
                       and then (Best = 0
                                 or else Natural'Value (Offsets (Position))
                                         > Natural'Value (Offsets (Best)))
                     then
                        Best := Position;
                     end if;
                  end loop;
                  Done (Best) := True;
                  US.Insert (Edited, Natural'Value (Offsets (Best)) + 1,
                             Tags (Best));
               end;
            end loop;
            Source := Edited;
            US.Append (Source, LF & T.Join (Queries, [1 => LF]) & LF);
         end;
      end Step;
      procedure Run is new Guarded (Step);
   begin
      Source := US.Null_Unbounded_String;
      Run (Into);
   end Probe_Source;

   function Probe_Filter (Of_Session : Session) return String is
     ("-ast-dump-filter=" & US.To_String (Of_Session.Data.Probe_Prefix)
      & "type_");

   procedure Read_Probe (Into : in out Session; Output : String) is
      procedure Step (Within : Handle);
      procedure Step (Within : Handle) is
         Prefix : constant String := US.To_String (Within.Probe_Prefix);
         Codes : Text_Maps.Map;
         Position : Natural := Output'First;
      begin
         --  Clang emits one JSON object per matching declaration, not an
         --  array.
         while Position <= Output'Last loop
            while Position <= Output'Last
              and then T.Is_Space (Output (Position))
            loop
               Position := Position + 1;
            end loop;
            exit when Position > Output'Last;
            declare
               First : constant Positive := Position;
               Depth : Natural := 0;
               In_String : Boolean := False;
               Doc : J.Document;
            begin
               loop
                  if Position > Output'Last then
                     Fail (Within, "Clang emitted invalid enum probe AST: an"
                           & " object is not closed", Clang_Fault);
                  end if;
                  declare
                     Item : constant Character := Output (Position);
                  begin
                     if In_String then
                        if Item = '\' then
                           Position := Position + 1;
                        elsif Item = '"' then
                           In_String := False;
                        end if;
                     elsif Item = '"' then
                        In_String := True;
                     elsif Item in '{' | '[' then
                        Depth := Depth + 1;
                     elsif Item in '}' | ']' then
                        if Depth = 0 then
                           Fail (Within, "Clang emitted invalid enum probe"
                                 & " AST", Clang_Fault);
                        end if;
                        Depth := Depth - 1;
                     end if;
                  end;
                  Position := Position + 1;
                  exit when Depth = 0 and then not In_String;
               end loop;
               J.Parse (Doc, Output (First .. Position - 1),
                        Depth_Limit => Ast_Depth);
               if not J.Ok (Doc) then
                  Fail (Within, "Clang emitted invalid enum probe AST: "
                        & J.Fault (Doc), Clang_Fault);
               end if;
               declare
                  Root : constant J.Value := J.Root (Doc);
                  Kind : constant J.Value := J.Member (Doc, Root, "kind");
                  Name : constant J.Value := J.Member (Doc, Root, "name");
                  Value : US.Unbounded_String :=
                    US.To_Unbounded_String ("0");

                  procedure Walk (Node : J.Value; Found : in out Boolean);

                  procedure Walk (Node : J.Value; Found : in out Boolean) is
                     Inner : constant J.Value := J.Member (Doc, Node, "inner");
                  begin
                     if Found or else not J.Is_Kind (Doc, Node, J.Object_Value)
                     then
                        return;
                     end if;
                     if J.Is_Kind (Doc, J.Member (Doc, Node, "kind"),
                                   J.String_Value)
                       and then J.Text (Doc, J.Member (Doc, Node, "kind"))
                                = "ConstantExpr"
                       and then J.Is_Kind (Doc, J.Member (Doc, Node, "value"),
                                           J.String_Value)
                     then
                        Value := US.To_Unbounded_String
                          (J.Text (Doc, J.Member (Doc, Node, "value")));
                        Found := True;
                        return;
                     end if;
                     if J.Is_Kind (Doc, Inner, J.Array_Value) then
                        for Child in 1 .. J.Length (Doc, Inner) loop
                           Walk (J.Element (Doc, Inner, Child), Found);
                        end loop;
                     end if;
                  end Walk;

                  Found : Boolean := False;
               begin
                  if not J.Is_Kind (Doc, Root, J.Object_Value)
                    or else not J.Is_Kind (Doc, Kind, J.String_Value)
                    or else J.Text (Doc, Kind) /= "EnumConstantDecl"
                  then
                     Fail (Within, "Clang emitted an unexpected enum probe"
                           & " declaration", Clang_Fault);
                  end if;
                  if not J.Is_Kind (Doc, Name, J.String_Value)
                    or else not T.Starts_With
                      (J.Text (Doc, Name), Prefix & "type_")
                    or else not T.Is_Digits
                      (J.Text (Doc, Name)
                         (J.Text (Doc, Name)'First + Prefix'Length + 5
                          .. J.Text (Doc, Name)'Last))
                    or else J.Text (Doc, Name)'Length > Prefix'Length + 5 + 9
                    or else Natural'Value
                      (J.Text (Doc, Name)
                         (J.Text (Doc, Name)'First + Prefix'Length + 5
                          .. J.Text (Doc, Name)'Last))
                      >= Natural (Within.Probed_Enums.Length)
                    or else Codes.Contains (J.Text (Doc, Name))
                  then
                     Fail (Within, "Clang emitted an unexpected enum probe"
                           & " constant", Clang_Fault);
                  end if;
                  Walk (Root, Found);
                  Codes.Include (J.Text (Doc, Name), US.To_String (Value));
               end;
            end;
         end loop;
         for Position in 1 .. Natural (Within.Probed_Enums.Length) loop
            declare
               Index : constant Positive :=
                 C.Enum_Index (Within, Within.Probed_Enums (Position));
               Key : constant String :=
                 Prefix & "type_" & T.Image (Long_Long_Integer (Position - 1));
               Code : constant String :=
                 (if Codes.Contains (Key) then Codes (Key) else "0");
            begin
               if not T.Is_Digits (Code) or else Code'Length > 2
                 or else Natural'Value (Code)
                         not in 1 .. Natural (Candidates.Length)
               then
                  Fail (Within, "enum " & T.Repr (C.Enum_Display (Within,
                    Index))
                        & ": unsupported Clang compatible integer type");
               end if;
               Within.Enums (Index).Compatible := US.To_Unbounded_String
                 (Candidates (Natural'Value (Code)));
               Within.Enums (Index).Has_Compatible := True;
            end;
         end loop;
         Within.Stage := Probed;
      end Step;
      procedure Run is new Guarded (Step);
   begin
      Run (Into);
   end Read_Probe;

   procedure Generate
     (Into    : in out Session;
      Defines : Landin.Platform.Path_List)
   is
      procedure Step (Within : Handle);
      procedure Step (Within : Handle) is
      begin
         Generation.Generate (Within, Defines);
         Within.Stage := Generated;
      end Step;
      procedure Run is new Guarded (Step);
   begin
      Run (Into);
   end Generate;

   function Output
     (Of_Session : Session; Index : Output_Index) return String is
     (Of_Session.Data.Outputs (Index));

end Landin.Bindings;
