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

   function Args (Item : Fixture) return String
     is (Unbounded.To_String (Item.Args));

   function Status (Item : Fixture) return Integer is (Item.Status);

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

   function Trimmed (Text : String) return String;

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
      Seen_Status  : Boolean := False;
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
               Item.Codes := Unbounded.To_Unbounded_String (Value);

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
               Codes   => Unbounded.Null_Unbounded_String,
               Status  => 0,
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

      --  An expectation nothing can produce is the failure mode this
      --  format was written to prevent: a golden file that looks like
      --  coverage and is never compared to anything.
      if Seen_Expect and then not Seen_Args then
         Complain ("expect without args: nothing would produce it");
      end if;

      if Seen_Args and then not Seen_Expect then
         Complain ("args without expect: nothing would be compared");
      end if;

      --  A runtime fixture is compiled, linked and executed, so its
      --  program is the whole of what it is.  Without one there is
      --  nothing to run, and a status on its own is a number nobody
      --  produces -- the same dead data the two rules above refuse.
      if Seen_Class and then Item.Class = Runtime
        and then not Seen_Program
      then
         Complain ("a runtime fixture needs a program to run");
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
               Into.Items.Append (Item);
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
