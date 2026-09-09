with Ada.Strings.Fixed;

package body Landin.Testing.Fixtures is

   use type Landin.Platform.List_Status;
   use type Landin.Platform.Read_Status;

   Metadata_Name : constant String := "fixture.meta";

   --  The targets ROADMAP.md names.  A fixture may apply to a target the
   --  chassis does not describe yet -- macos-arm64 arrives at R5 and the
   --  Cortex-M reference profile at R6 -- but it may not name one the
   --  roadmap has never heard of, because that is how a fixture quietly
   --  stops applying to anything.
   function Is_Named_Target (Name : String) return Boolean is
     (Name in "linux-x86-64" | "macos-arm64" | "cortex-m" | "synthetic-32");

   function Class_Directory (Item : Fixture_Class) return String is
     (case Item is
         when Unit             => "unit",
         when Positive_Program => "positive",
         when Negative_Program => "negative",
         when Runtime          => "runtime",
         when Abi              => "abi",
         when Debugger         => "debugger",
         when End_To_End       => "end-to-end");

   function Class_Of (Text : String; Found : out Boolean) return Fixture_Class
   is
   begin
      for Candidate in Fixture_Class loop
         if Class_Directory (Candidate) = Text then
            Found := True;
            return Candidate;
         end if;
      end loop;
      Found := False;
      return Unit;
   end Class_Of;

   function Class (Item : Fixture) return Fixture_Class is (Item.Class);

   function Name (Item : Fixture) return String
     is (Unbounded.To_String (Item.Name));

   function Summary (Item : Fixture) return String
     is (Unbounded.To_String (Item.Summary));

   function Program (Item : Fixture) return String
     is (Unbounded.To_String (Item.Program));

   function Expect (Item : Fixture) return String
     is (Unbounded.To_String (Item.Expect));

   function Targets (Item : Fixture) return String
     is (Unbounded.To_String (Item.Targets));

   function Codes (Item : Fixture) return String
     is (Unbounded.To_String (Item.Codes));

   function Normalized_Codes (Text : String) return String is
      Found : Unbounded.Unbounded_String;
      Start : Positive := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ',' then
            declare
               Piece : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Text (Start .. Index - 1), Ada.Strings.Both);
            begin
               if Piece'Length > 0 then
                  if Unbounded.Length (Found) > 0 then
                     Unbounded.Append (Found, ", ");
                  end if;
                  Unbounded.Append (Found, Piece);
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      return Unbounded.To_String (Found);
   end Normalized_Codes;

   function Args (Item : Fixture) return String
     is (Unbounded.To_String (Item.Args));

   function Run_Args (Item : Fixture) return String
     is (Unbounded.To_String (Item.Run_Args));

   function Run_Expect (Item : Fixture) return String
     is (Unbounded.To_String (Item.Run_Expect));

   function Status (Item : Fixture) return Integer is (Item.Status);

   function Traps (Item : Fixture) return Boolean is (Item.Traps);

   function Constructs (Item : Fixture) return String
     is (Unbounded.To_String (Item.Made_Of));

   function With_Sources (Item : Fixture) return String
     is (Unbounded.To_String (Item.Beside));

   function Module_Root (Item : Fixture) return String
     is (Unbounded.To_String (Item.Root));

   function Trimmed (Text : String) return String;

   procedure Append_Module_Arguments
     (Item         : Fixture;
      Fixture_Root : String;
      To           : in out Landin.Platform.Path_List)
   is
      Directory : constant String :=
        Fixture_Root & "/" & Class_Directory (Class (Item)) & "/"
        & Name (Item);
   begin
      if Module_Root (Item) /= "" then
         Landin.Platform.Add
           (To, "--root=" & Directory & "/" & Module_Root (Item));
         Landin.Platform.Add (To, Directory);
         return;
      end if;

      Landin.Platform.Add (To, Directory & "/" & Program (Item));

      declare
         Rest  : constant String := With_Sources (Item);
         First : Integer := Rest'First;

         procedure Add_One (Named : String);

         procedure Add_One (Named : String) is
            One : constant String := Trimmed (Named);
         begin
            if One /= "" then
               Landin.Platform.Add (To, Directory & "/" & One);
            end if;
         end Add_One;
      begin
         for Index in Rest'Range loop
            if Rest (Index) = ',' then
               Add_One (Rest (First .. Index - 1));
               First := Index + 1;
            end if;
         end loop;

         if First <= Rest'Last then
            Add_One (Rest (First .. Rest'Last));
         end if;
      end;
   end Append_Module_Arguments;

   function C_Sources (Item : Fixture) return String
     is (Unbounded.To_String (Item.C_Files));

   function C_Args (Item : Fixture) return String
     is (Unbounded.To_String (Item.C_Options));

   function Stream (Item : Fixture) return Stream_Choice is (Item.Stream);

   function Count (In_Catalogue : Catalogue) return Natural
     is (Natural (In_Catalogue.Items.Length));

   function Nth (In_Catalogue : Catalogue; Index : Positive) return Fixture
     is (In_Catalogue.Items.Element (Index));

   function Count_Of
     (In_Catalogue : Catalogue; Of_Class : Fixture_Class) return Natural
   is
      Total : Natural := 0;
   begin
      for Item of In_Catalogue.Items loop
         if Item.Class = Of_Class then
            Total := Total + 1;
         end if;
      end loop;
      return Total;
   end Count_Of;

   function Problem_Count (In_Catalogue : Catalogue) return Natural
     is (Natural (In_Catalogue.Problems.Length));

   function Nth_Problem
     (In_Catalogue : Catalogue; Index : Positive) return String
     is (In_Catalogue.Problems.Element (Index));

   function Is_Relative_C_Source (Name : String) return Boolean;

   function Trimmed (Text : String) return String is
      First : Integer := Text'First;
      Last  : Integer := Text'Last;
   begin
      while First <= Last and then Text (First) = ' ' loop
         First := First + 1;
      end loop;
      while Last >= First
        and then (Text (Last) = ' '
                  or else Text (Last) = Character'Val (13))
      loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   --  ABI companions are repository files, not paths interpreted by a shell.
   --  Keep them below the fixture directory on every host, and require the
   --  extension that says which inputs the C driver should compile.
   function Is_Relative_C_Source (Name : String) return Boolean is
      First : Integer := Name'First;
   begin
      if Name'Length < 3
        or else Name (Name'Last - 1 .. Name'Last) /= ".c"
        or else Name (Name'First) in '/' | '\'
      then
         return False;
      end if;

      for Index in Name'Range loop
         if Name (Index) = '\' or else Name (Index) = ':' then
            return False;
         elsif Name (Index) = '/' then
            if Index = First
              or else Name (First .. Index - 1) in "." | ".."
            then
               return False;
            end if;
            First := Index + 1;
         end if;
      end loop;

      return First <= Name'Last
        and then Name (First .. Name'Last) not in "." | "..";
   end Is_Relative_C_Source;

   ---------------------------------------------------------------------
   --  Read_Metadata
   --
   --  `key: value` lines, `#` comments and blank lines.  Anything else is
   --  reported: a fixture whose metadata is nearly right is the one that
   --  silently stops being checked.
   ---------------------------------------------------------------------

   procedure Read_Metadata
     (Content   : String;
      Where     : String;
      Expected  : Fixture_Class;
      Fixture_Name : String;
      Item      : out Fixture;
      Problems  : in out Problem_Vectors.Vector;
      Accepted  : out Boolean);

   procedure Read_Metadata
     (Content   : String;
      Where     : String;
      Expected  : Fixture_Class;
      Fixture_Name : String;
      Item      : out Fixture;
      Problems  : in out Problem_Vectors.Vector;
      Accepted  : out Boolean)
   is
      Before       : constant Natural := Natural (Problems.Length);
      Seen_Class   : Boolean := False;
      Seen_Summary : Boolean := False;
      Seen_Program : Boolean := False;
      Seen_Expect  : Boolean := False;
      Seen_Targets : Boolean := False;
      Seen_Args    : Boolean := False;
      Seen_Run_Args : Boolean := False;
      Seen_Run_Expect : Boolean := False;
      Seen_Status  : Boolean := False;
      Seen_Traps   : Boolean := False;
      Seen_Constructs : Boolean := False;
      Seen_With    : Boolean := False;
      Seen_Root    : Boolean := False;
      Seen_C_Sources : Boolean := False;
      Seen_C_Args  : Boolean := False;
      Seen_Stream  : Boolean := False;
      Seen_Lex     : Boolean := False;
      Seen_Codes   : Boolean := False;
      Line_Number  : Natural := 0;
      First        : Integer := Content'First;

      procedure Complain (Text : String);

      procedure Complain (Text : String) is
      begin
         Problems.Append (Where & ": " & Text);
      end Complain;

      procedure Handle (Line : String);

      procedure Handle (Line : String) is
         Body_Text : constant String := Trimmed (Line);
         Colon     : Natural := 0;
      begin
         if Body_Text = "" or else Body_Text (Body_Text'First) = '#' then
            return;
         end if;

         for Index in Body_Text'Range loop
            if Body_Text (Index) = ':' then
               Colon := Index;
               exit;
            end if;
         end loop;

         if Colon = 0 then
            Complain
              ("line" & Natural'Image (Line_Number)
               & " is not `key: value`");
            return;
         end if;

         declare
            Key   : constant String :=
              Trimmed (Body_Text (Body_Text'First .. Colon - 1));
            Value : constant String :=
              Trimmed (Body_Text (Colon + 1 .. Body_Text'Last));
         begin
            if Key = "class" then
               if Seen_Class then
                  Complain ("duplicate key: class");
                  return;
               end if;
               Seen_Class := True;

               declare
                  Found : Boolean;
                  Named : constant Fixture_Class := Class_Of (Value, Found);
               begin
                  if not Found then
                     Complain ("unknown class: " & Value);
                  elsif Named /= Expected then
                     Complain
                       ("class " & Value & " does not match directory "
                        & Class_Directory (Expected));
                  else
                     Item.Class := Named;
                  end if;
               end;

            elsif Key = "summary" then
               if Seen_Summary then
                  Complain ("duplicate key: summary");
                  return;
               end if;
               Seen_Summary := True;

               if Value = "" then
                  Complain ("summary is empty");
               else
                  Item.Summary := Unbounded.To_Unbounded_String (Value);
               end if;

            elsif Key = "program" then
               if Seen_Program then
                  Complain ("duplicate key: program");
                  return;
               end if;
               Seen_Program := True;
               Item.Program := Unbounded.To_Unbounded_String (Value);

            elsif Key = "expect" then
               if Seen_Expect then
                  Complain ("duplicate key: expect");
                  return;
               end if;
               Seen_Expect := True;
               Item.Expect := Unbounded.To_Unbounded_String (Value);

            elsif Key = "targets" then
               if Seen_Targets then
                  Complain ("duplicate key: targets");
                  return;
               end if;
               Seen_Targets := True;
               Item.Targets := Unbounded.To_Unbounded_String (Value);

               declare
                  First : Integer := Value'First;
               begin
                  for Index in Value'First .. Value'Last + 1 loop
                     if Index > Value'Last or else Value (Index) = ',' then
                        declare
                           One : constant String :=
                             Trimmed (Value (First .. Index - 1));
                        begin
                           if One /= ""
                             and then not Is_Named_Target (One)
                           then
                              Complain ("unknown target: " & One);
                           end if;
                        end;
                        First := Index + 1;
                     end if;
                  end loop;
               end;

            elsif Key = "codes" then
               if Seen_Codes then
                  Complain ("duplicate key: codes");
                  return;
               end if;
               Seen_Codes := True;

               declare
                  First : Integer := Value'First;
                  Ok : Boolean := Value'Length > 0;

                  procedure Consider (Text : String);

                  procedure Consider (Text : String) is
                     One : constant String := Trimmed (Text);
                  begin
                     if One'Length /= 5 or else One (One'First) /= 'L' then
                        Ok := False;
                        return;
                     end if;
                     for Position in One'First + 1 .. One'Last loop
                        if One (Position) not in '0' .. '9' then
                           Ok := False;
                        end if;
                     end loop;
                  end Consider;
               begin
                  for Index in Value'Range loop
                     if Value (Index) = ',' then
                        Consider (Value (First .. Index - 1));
                        First := Index + 1;
                     end if;
                  end loop;
                  if First <= Value'Last then
                     Consider (Value (First .. Value'Last));
                  else
                     Ok := False;
                  end if;

                  if Expected not in Unit | Negative_Program then
                     Complain ("codes belong only to a negative or unit"
                               & " fixture");
                  elsif Ok then
                     Item.Codes := Unbounded.To_Unbounded_String (Value);
                  else
                     Complain ("a code is L and four digits: " & Value);
                  end if;
               end;

            elsif Key = "lex" then
               if Seen_Lex then
                  Complain ("duplicate key: lex");
                  return;
               end if;
               Seen_Lex := True;

            elsif Key = "args" then
               if Seen_Args then
                  Complain ("duplicate key: args");
                  return;
               end if;
               Seen_Args := True;
               Item.Args := Unbounded.To_Unbounded_String (Value);

            elsif Key = "run_args" then
               if Seen_Run_Args then
                  Complain ("duplicate key: run_args");
                  return;
               end if;
               Seen_Run_Args := True;
               Item.Run_Args := Unbounded.To_Unbounded_String (Value);

            elsif Key = "run_expect" then
               if Seen_Run_Expect then
                  Complain ("duplicate key: run_expect");
                  return;
               end if;
               Seen_Run_Expect := True;
               Item.Run_Expect := Unbounded.To_Unbounded_String (Value);

            elsif Key = "stream" then
               if Seen_Stream then
                  Complain ("duplicate key: stream");
                  return;
               end if;
               Seen_Stream := True;

               if Value = "output" then
                  Item.Stream := Output;
               elsif Value = "merged" then
                  Item.Stream := Merged;
               else
                  Complain ("stream is not output or merged: " & Value);
               end if;

            elsif Key = "with" then
               if Seen_With then
                  Complain ("duplicate key: with");
                  return;
               end if;
               Seen_With := True;

               if Value'Length = 0 then
                  Complain ("with names no file");
               else
                  Item.Beside := Unbounded.To_Unbounded_String (Value);
               end if;

            elsif Key = "root" then
               if Seen_Root then
                  Complain ("duplicate key: root");
                  return;
               end if;
               Seen_Root := True;

               if Value'Length = 0 then
                  Complain ("root names no directory");
               else
                  Item.Root := Unbounded.To_Unbounded_String (Value);
               end if;

            elsif Key = "c-sources" then
               if Seen_C_Sources then
                  Complain ("duplicate key: c-sources");
                  return;
               end if;
               Seen_C_Sources := True;

               if Expected /= Abi then
                  Complain ("c-sources belong only to an ABI fixture");
               end if;

               declare
                  First : Integer := Value'First;
                  Ok    : Boolean := Value'Length > 0;
                  Seen  : Landin.Platform.Path_List;

                  procedure Consider (Text : String);

                  procedure Consider (Text : String) is
                     One      : constant String := Trimmed (Text);
                     Repeated : Boolean := False;
                  begin
                     if not Is_Relative_C_Source (One) then
                        Ok := False;
                        Complain
                          ("c-sources path is not a relative .c file: "
                           & (if One = "" then "<empty>" else One));
                        return;
                     end if;

                     for Previous of Seen loop
                        if Previous = One then
                           Repeated := True;
                        end if;
                     end loop;

                     if Repeated then
                        Ok := False;
                        Complain ("duplicate c-sources path: " & One);
                     else
                        Seen.Append (One);
                     end if;
                  end Consider;
               begin
                  for Index in Value'First .. Value'Last + 1 loop
                     if Index > Value'Last or else Value (Index) = ',' then
                        Consider (Value (First .. Index - 1));
                        First := Index + 1;
                     end if;
                  end loop;

                  if Ok then
                     Item.C_Files := Unbounded.To_Unbounded_String (Value);
                  end if;
               end;

            elsif Key = "c-args" then
               if Seen_C_Args then
                  Complain ("duplicate key: c-args");
                  return;
               end if;
               Seen_C_Args := True;

               if Expected /= Abi then
                  Complain ("c-args belong only to an ABI fixture");
               end if;

               declare
                  Has_Argument : Boolean := False;
               begin
                  for Letter of Value loop
                     if Letter not in ' ' | ASCII.HT then
                        Has_Argument := True;
                     end if;
                  end loop;

                  if not Has_Argument then
                     Complain ("c-args names no argument");
                  else
                     Item.C_Options :=
                       Unbounded.To_Unbounded_String (Value);
                  end if;
               end;

            elsif Key = "constructs" then
               if Seen_Constructs then
                  Complain ("duplicate key: constructs");
                  return;
               end if;
               Seen_Constructs := True;

               declare
                  First : Integer := Value'First;
                  Ok    : Boolean := Value'Length > 0;

                  procedure Consider (Text : String);

                  procedure Consider (Text : String) is
                     Trimmed : constant String :=
                       Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
                  begin
                     if Trimmed'Length /= 4 then
                        Ok := False;
                        return;
                     end if;

                     for Letter of Trimmed loop
                        if Letter not in '0' .. '9' then
                           Ok := False;
                        end if;
                     end loop;
                  end Consider;
               begin
                  for Index in Value'Range loop
                     if Value (Index) = ',' then
                        Consider (Value (First .. Index - 1));
                        First := Index + 1;
                     end if;
                  end loop;

                  if First <= Value'Last then
                     Consider (Value (First .. Value'Last));
                  else
                     Ok := False;
                  end if;

                  if Ok then
                     Item.Made_Of := Unbounded.To_Unbounded_String (Value);
                  else
                     Complain
                       ("a construct is four digits, and this is not: "
                        & Value);
                  end if;
               end;

            elsif Key = "traps" then
               if Seen_Traps then
                  Complain ("duplicate key: traps");
                  return;
               end if;
               Seen_Traps := True;

               if Value = "yes" then
                  Item.Traps := True;
               elsif Value = "no" then
                  Item.Traps := False;
               else
                  Complain ("traps is not yes or no: " & Value);
               end if;

            elsif Key = "status" then
               if Seen_Status then
                  Complain ("duplicate key: status");
                  return;
               end if;
               Seen_Status := True;

               begin
                  Item.Status := Integer'Value (Value);
               exception
                  when Constraint_Error =>
                     Complain ("status is not a number: " & Value);
               end;

            else
               Complain ("unknown key: " & Key);
            end if;
         end;
      end Handle;

   begin
      Item := (Class   => Expected,
               Name    => Unbounded.To_Unbounded_String (Fixture_Name),
               Summary => Unbounded.Null_Unbounded_String,
               Program => Unbounded.Null_Unbounded_String,
               Expect  => Unbounded.Null_Unbounded_String,
               Targets => Unbounded.Null_Unbounded_String,
               Args    => Unbounded.Null_Unbounded_String,
               Run_Args => Unbounded.Null_Unbounded_String,
               Run_Expect => Unbounded.Null_Unbounded_String,
               Codes   => Unbounded.Null_Unbounded_String,
               Status  => 0,
               Traps   => False,
               Made_Of => Unbounded.Null_Unbounded_String,
               Beside  => Unbounded.Null_Unbounded_String,
               Root    => Unbounded.Null_Unbounded_String,
               C_Files => Unbounded.Null_Unbounded_String,
               C_Options => Unbounded.Null_Unbounded_String,
               Stream  => Merged);

      for Index in Content'Range loop
         if Content (Index) = Character'Val (10) then
            Line_Number := Line_Number + 1;
            Handle (Content (First .. Index - 1));
            First := Index + 1;
         end if;
      end loop;

      if First <= Content'Last then
         Line_Number := Line_Number + 1;
         Handle (Content (First .. Content'Last));
      end if;

      if not Seen_Class then
         Complain ("missing required key: class");
      end if;

      if not Seen_Summary then
         Complain ("missing required key: summary");
      end if;

      if not Seen_Targets then
         Complain ("missing required key: targets");
      end if;

      --  An expectation nothing can produce is the failure mode this
      --  format was written to prevent: a golden file that looks like
      --  coverage and is never compared to anything.
      if Seen_Expect and then not Seen_Args then
         Complain ("expect without args: nothing would produce it");
      end if;

      if Seen_Args and then not Seen_Expect then
         Complain ("args without expect: nothing would be compared");
      end if;

      if Seen_Run_Args
        and then (not Seen_Class
                  or else Item.Class not in Runtime | Abi)
      then
         Complain ("run_args belong only to a runtime or ABI fixture");
      end if;

      if Seen_Run_Expect
        and then (not Seen_Class
                  or else Item.Class not in Runtime | Abi)
      then
         Complain ("run_expect belongs only to a runtime or ABI fixture");
      end if;

      --  Runtime and ABI fixtures both produce and execute a hosted program.
      --  ABI compilation stops at assembly inside refine, then the harness
      --  adds the required C companions through the selected target driver.
      if Seen_Class and then Item.Class in Runtime | Abi
        and then not Seen_Program
      then
         Complain
           ((if Item.Class = Runtime then "a runtime" else "an ABI")
            & " fixture needs a program to run");
      end if;

      if Seen_Class and then Item.Class = Abi and then not Seen_C_Sources then
         Complain ("an ABI fixture needs c-sources");
      end if;

      --  A `.ldn` program is written in the language, so it is evidence
      --  about some construct of it and R1.90 wants to know which.  A
      --  fixture with no program is about the tool rather than the
      --  language -- an unknown option, the identity text, an
      --  implementation-side note -- and names no construct for the same
      --  reason.
      --  The rest of a module is only meaningful beside the file the
      --  fixture is named for.
      if Seen_With and then not Seen_Program then
         Complain ("with names the rest of a module and there is no"
                   & " program to be the rest of");
      end if;

      if Seen_With then
         declare
            Value : constant String := Unbounded.To_String (Item.Beside);
            First : Integer := Value'First;

            procedure Consider (Text : String);

            procedure Consider (Text : String) is
               One : constant String := Trimmed (Text);
            begin
               if One'Length >= 2
                 and then One (One'Last - 1 .. One'Last) = ".c"
               then
                  Complain
                    ("C source belongs in c-sources, never with: " & One);
               end if;
            end Consider;
         begin
            for Index in Value'First .. Value'Last + 1 loop
               if Index > Value'Last or else Value (Index) = ',' then
                  Consider (Value (First .. Index - 1));
                  First := Index + 1;
               end if;
            end loop;
         end;
      end if;

      if Seen_Root
        and then (not Seen_Class
                  or else Item.Class not in Positive_Program
                                            | Negative_Program
                                            | Runtime
                                            | Abi)
      then
         Complain
           ("root belongs only to a positive, negative, runtime or ABI"
            & " fixture");
      end if;

      --  Rooted compile-only fixtures still name the corpus file their
      --  acceptance or refusal is evidence about.  Without a nonempty program,
      --  the whole-corpus parser and positive-emission loops would omit them.
      if Seen_Root
        and then Seen_Class
        and then Item.Class in Positive_Program | Negative_Program
        and then (not Seen_Program
                  or else Unbounded.Length (Item.Program) = 0)
      then
         Complain
           ("a rooted positive or negative fixture needs a nonempty program");
      end if;

      if Seen_Root and then Seen_With then
         Complain ("a rooted fixture discovers its module files"
                   & " instead of naming them with `with`");
      end if;

      if Seen_Program and then not Seen_Constructs then
         Complain
           ("a fixture with a program says which constructs it is about");
      end if;

      --  [1960] leaves a trap no status to carry, so a fixture that says
      --  its program traps and also names a status is claiming two
      --  answers, and only one of them can be observed.
      if Seen_Traps and then Item.Traps and then Seen_Status then
         Complain ("a trapping fixture has no exit status to compare");
      end if;

      if Seen_Traps and then Item.Traps
        and then Seen_Class and then Item.Class not in Runtime | Abi
      then
         Complain
           ("only a runtime or ABI fixture runs a program that could trap");
      end if;

      --  Any reported fault rejects the fixture.  A fixture that is
      --  half-accepted is a fixture whose fault stops being visible.
      Accepted := Natural (Problems.Length) = Before;
   end Read_Metadata;

   procedure Discover
     (Into : in out Catalogue;
      Root : String;
      Host : Landin.Platform.Filesystem'Class)
   is
      procedure Consider
        (Kind : Fixture_Class; Directory : String; Fixture_Name : String);

      procedure Consider
        (Kind : Fixture_Class; Directory : String; Fixture_Name : String)
      is
         Path : constant String := Directory & "/" & Fixture_Name;
         Meta : constant String := Path & "/" & Metadata_Name;
         Text : Unbounded.Unbounded_String;
         Read : Landin.Platform.Read_Status;
      begin
         if not Host.Is_Directory (Path) then
            Into.Problems.Append
              (Path & ": fixture entry is not a directory");
            return;
         end if;

         Host.Read_File (Meta, Text, Read);

         if Read /= Landin.Platform.Read_Ok then
            Into.Problems.Append
              (Meta & ": metadata is missing or unreadable");
            return;
         end if;

         declare
            Item     : Fixture;
            Accepted : Boolean;
         begin
            Read_Metadata
              (Content      => Unbounded.To_String (Text),
               Where        => Meta,
               Expected     => Kind,
               Fixture_Name => Fixture_Name,
               Item         => Item,
               Problems     => Into.Problems,
               Accepted     => Accepted);

            if Accepted then
               declare
                  Sources : constant String := C_Sources (Item);
                  First   : Integer := Sources'First;
                  Valid   : Boolean := True;
               begin
                  if Sources = "" then
                     Into.Items.Append (Item);
                     return;
                  end if;

                  for Index in Sources'First .. Sources'Last + 1 loop
                     if Index > Sources'Last
                       or else Sources (Index) = ','
                     then
                        declare
                           One : constant String :=
                             Trimmed (Sources (First .. Index - 1));
                           Source_Path : constant String := Path & "/" & One;
                        begin
                           if not Host.Exists (Source_Path)
                             or else Host.Is_Directory (Source_Path)
                           then
                              Into.Problems.Append
                                (Meta & ": c-sources names " & One
                                 & ", which is missing or not a file");
                              Valid := False;
                           end if;
                        end;
                        First := Index + 1;
                     end if;
                  end loop;

                  if Valid then
                     Into.Items.Append (Item);
                  end if;
               end;
            end if;
         end;
      end Consider;

   begin
      Into.Items := Fixture_Vectors.Empty_Vector;
      Into.Problems := Problem_Vectors.Empty_Vector;

      for Kind in Fixture_Class loop
         declare
            Directory : constant String :=
              Root & "/" & Class_Directory (Kind);
            Names     : Landin.Platform.Path_List;
            Status    : Landin.Platform.List_Status;
         begin
            Host.List_Directory (Directory, Names, Status);

            if Status = Landin.Platform.Not_A_Directory then
               Into.Problems.Append
                 (Directory & ": fixture class path is not a directory");

            elsif Status = Landin.Platform.List_Ok then
               for Fixture_Name of Names loop
                  --  Host clutter such as .DS_Store is not a fixture and
                  --  not a fault; a name a fixture could have is.
                  if Fixture_Name'Length > 0
                    and then Fixture_Name (Fixture_Name'First) /= '.'
                  then
                     Consider (Kind, Directory, Fixture_Name);
                  end if;
               end loop;
            end if;
         end;
      end loop;
   end Discover;

end Landin.Testing.Fixtures;
