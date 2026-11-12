with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Maps;

with Landin.Backend.Entry_Point;
with Landin.Backend.Firmware;
with Landin.Backend.Images;
with Landin.Backend.Toolchain;
with Landin.Backend.Dispatch;
with Landin.Build_Identity;
with Landin.Build_Reports;
with Landin.Build_Reports.Firmware;
with Landin.Build_Reports.Sources;
with Landin.Build_Reports.Stacks;
with Landin.Commands.Catalogue;
with Landin.Checking;
with Landin.Configuration;
with Landin.Debugging;
with Landin.IR.Dump;
with Landin.IR.Pipeline;
with Landin.Optimization;
with Landin.Panics;
with Landin.Platform.Publication;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Citations.Answers;
with Landin.Diagnostics.Explanations;
with Landin.Diagnostics.Suggestions;
with Landin.Diagnostics.Text;
with Landin.Driver.Assembler_Sites;
with Landin.Driver.Boot_Stage;
with Landin.Driver.Checking;
with Landin.Driver.ESP_Image;
with Landin.Driver.Image_Block;
with Landin.Driver.Library;
with Landin.Driver.Loading;
with Landin.Formatting;
with Landin.IR;
with Landin.Json;
with Landin.Modules;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Source_Digests;
with Landin.Source_Maps;
with Landin.Stages;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Targets.Capabilities;
with Landin.Targets.Firmware;
with Landin.Targets.Levels;

package body Landin.Driver is

   use type Landin.Targets.Architecture;
   use type Landin.Targets.Target_Facts;

   package Unbounded renames Ada.Strings.Unbounded;

   package Path_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   LF : constant Character := Character'Val (10);

   --  The codes come from the catalogue, which is the only place in this
   --  compiler where a code is written.  These four were literals here
   --  until the catalogue was built, and check.py now refuses a code written
   --  anywhere else.
   package Rows renames Landin.Diagnostics.Catalogue;

   use type Landin.IR.Item_Id;
   use type Landin.Checking.Signature_Id;
   use type Landin.Formatting.Verdict;
   use type Landin.IR.Item_Kind;
   use type Landin.Modules.Module_Id;
   use type Landin.Platform.Read_Status;
   use type Landin.Platform.Termination;
   use type Landin.Platform.Write_Status;
   use type Landin.Platform.File_Identity;
   use type Landin.Targets.Capabilities.Backend_Kind;
   use type Landin.Targets.Capabilities.Debug_Format;
   use type Landin.Targets.Capabilities.Hosted_System;


   Code_Unknown_Level : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Unknown_Level);
   Code_Unknown_Option : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Unknown_Option);
   Code_Unreadable : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Unreadable_Source);
   Code_Unknown_Target : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Unknown_Target);
   Code_Unwritable : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Unwritable_Output);
   Code_No_Toolchain : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.No_Toolchain);
   Code_Toolchain_Failed : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Toolchain_Failed);
   Code_No_Entry : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Entry_Point_Missing);
   Code_Wide_Frame : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Frame_Not_Addressable);
   Code_Firmware_Frame : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Firmware_Frame_Exceeds_Stack);
   Code_Handler_Margin : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Handler_Exceeds_Stack_Margin);
   Code_Library_Not_Found : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Library_Not_Found);
   Code_Other_Citations : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Citations_From_Other_Sources);

   procedure Keep_Locations
     (Result : in out Outcome;
      Sources : aliased Landin.Source.Sets.Source_Set);

   procedure Keep_Locations
     (Result : in out Outcome;
      Sources : aliased Landin.Source.Sets.Source_Set)
   is
      use type Landin.Source.Source_Id;
   begin
      Result.Positions.Clear;
      for Index in 1 .. Landin.Diagnostics.Count (Result.Found) loop
         declare
            Label : constant Landin.Diagnostics.Label :=
              Landin.Diagnostics.Primary
                (Landin.Diagnostics.Get (Result.Found, Index));
            Id : constant Landin.Source.Source_Id :=
              Landin.Diagnostics.Source_Of (Label);
            Position : Landin.Source.Position;
         begin
            if Id /= Landin.Source.No_Source and then Sources.Contains (Id)
              and then Landin.Source.Is_Valid
                (Sources.Get (Id), Landin.Diagnostics.Span_Of (Label))
            then
               Position := Landin.Source.Position_Of
                 (Sources.Get (Id), Landin.Diagnostics.Span_Of (Label).First);
            end if;
            Result.Positions.Append (Position);
         end;
      end loop;
   end Keep_Locations;

   --  What a request asked to be left behind.  Nothing is the state every
   --  request had before the native path and most still have: a program is
   --  read, checked and lowered, and no file is written.
   --  Emit_IR is the verified IR as the backend receives it, after every
   --  pass the request's objective runs (D365).
   type Emit_Kind is
     (Emit_Nothing, Emit_Assembly, Emit_Executable, Emit_IR,
      --  D589: the selected profile's derived linker script, alone.
      Emit_Linker_Script);

   --  The targets are Landin.Targets.Selection's, in its order: every one
   --  is described, and those a backend emits for are named again, each
   --  with its levels.
   --  ": WORDS; retry when ..." when the host ran short of
   --  what comparing Path with Rights needed, WORDS its own (D1051), and
   --  "" when it did not, so the overlap it answered is the paths'.
   function Shortage
     (Host : Landin.Platform.Filesystem'Class; Path : String;
      Rights : Landin.Platform.Path_List) return String;

   function Shortage
     (Host : Landin.Platform.Filesystem'Class; Path : String;
      Rights : Landin.Platform.Path_List) return String
   is
      Words : constant String := Host.Separation_Shortage (Path, Rights);
   begin
      return (if Words = "" then ""
              else ": " & Words & "; retry when the host can spare more");
   end Shortage;

   --  Said & Short when the host ran short, Otherwise when it did not.
   function Unless_Short (Short, Said, Otherwise : String) return String
     is (if Short /= "" then Said & Short else Otherwise);

   function Identity return String is
      package Selection renames Landin.Targets.Selection;
      function Emits (Index : Positive) return Boolean
        is (Landin.Targets.Capabilities.Emits
              (Selection.Described_At (Index)));
      Backends, Described, Levels : Unbounded.Unbounded_String;
      Emitting, Named : Natural := 0;
   begin
      for Index in 1 .. Selection.Described_Count loop
         if Emits (Index) then
            Emitting := Emitting + 1;
         end if;
      end loop;
      for Index in 1 .. Selection.Described_Count loop
         declare
            Name : constant String := Selection.Described_Name (Index);
         begin
            Unbounded.Append
              (Described, (if Index = 1 then "" else ", ") & Name);
            if Emits (Index) then
               Named := Named + 1;
               Unbounded.Append
                 (Backends,
                  (if Named = 1 then ""
                   elsif Named = Emitting then " and "
                   else ", ") & Name);
               Unbounded.Append
                 (Levels, "levels of " & Name & ": "
                  & Landin.Targets.Levels.Levels_Of
                      (Selection.Described_At (Index)) & LF);
            end if;
         end;
      end loop;
      return "refine - the Landin bootstrap compiler" & LF
        & "use refine version for build identity" & LF
        & "language frontend: scanner, parser, names, types,"
        & " definite assignment" & LF
        & "target-neutral IR: lowered and verified" & LF
        & "backends: " & Unbounded.To_String (Backends) & " assembly" & LF
        & "executable output: assembled and linked by a"
        & " target-selected native toolchain" & LF
        & "targets described: " & Unbounded.To_String (Described) & LF
        & Unbounded.To_String (Levels);
   end Identity;

   --  The command catalogue's own overview: one text for `refine`,
   --  `refine --help` and a request the driver is handed with nothing in it.
   function Usage return String is (Landin.Commands.Catalogue.Usage);

   ---------------------------------------------------------------------
   --  Explain
   --
   --  A request with no compilation in it.  The report it may make is a
   --  driver report with no source, rendered as every other one is.  It
   --  answers a diagnostic code, and a construct or decision a note cites
   --  (D530); `--full` adds a construct's or decision's own text.
   --
   --  A code's explanation is built in.  A construct's and a decision's
   --  words are not (D1240): they are read from `citations.txt` in the
   --  library, found as a compilation finds it (D275) or where
   --  `--library=DIR` says, and read only when one is asked for.  A file
   --  that is missing, unreadable or in another format is reported with
   --  its path, and what was asked for is still named with its document.
   --  One generated from other compiler sources than this refine's, or
   --  that names none, is read and answers, with one warning that names
   --  both (D1357).
   ---------------------------------------------------------------------

   function Explain
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class) return Outcome;

   function Explain
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class) return Outcome
   is
      use type Rows.Disposition;
      use type Landin.Diagnostics.Severity;

      package Citations renames Landin.Diagnostics.Citations.Answers;

      Library_Option : constant String := "--library=";

      Result  : Outcome;
      Text    : Unbounded.Unbounded_String;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Misused : Boolean := False;

      --  The library `--library=DIR` names, the last one written.
      Named   : Unbounded.Unbounded_String;

      --  The citations, read at most once and only when one is asked for;
      --  Unread says why they could not be, and is "" when they were.
      Table   : Landin.Diagnostics.Citations.Table;
      Asked_Table : Boolean := False;
      Unread  : Unbounded.Unbounded_String;

      procedure Refuse (Message : String);

      procedure Refuse (Message : String) is
      begin
         Misused := True;
         Found.Append
           (Landin.Diagnostics.Make
              (Code    => Code_Unknown_Option,
               Level   => Landin.Diagnostics.Error,
               Source  => Landin.Source.No_Source,
               Where   => Landin.Source.Empty_Span,
               Message => Message));
      end Refuse;

      function Is_Library (Word : String) return Boolean
        is (Word'Length > Library_Option'Length
            and then Word (Word'First
                           .. Word'First + Library_Option'Length - 1)
                     = Library_Option);

      --  D1357: warn, once, when the file read from Path names other
      --  compiler sources than the ones this refine was built from, or
      --  names none.
      procedure Compare_Source (Path : String);

      procedure Compare_Source (Path : String) is
         Named_Source : constant String :=
           Landin.Diagnostics.Citations.Source (Table);
         Own : constant String := Landin.Build_Identity.Source_Digest;

         function Short (Text : String) return String
           is (Text (Text'First
                     .. Text'First + Natural'Min (12, Text'Length) - 1));

         --  Where a build with this revision and dirtiness was made from;
         --  a function, since the build's constants make the choices
         --  static.
         function Made_At (Revision : String; Dirty : Boolean) return String
           is (if Revision = "unknown" then " outside a git checkout"
               else " at revision " & Short (Revision)
                    & (if Dirty then " with uncommitted edits" else ""));
      begin
         if Named_Source = Own then
            return;
         end if;
         Found.Append
           (Landin.Diagnostics.Make
              (Code    => Code_Other_Citations,
               Level   => Landin.Diagnostics.Warning,
               Source  => Landin.Source.No_Source,
               Where   => Landin.Source.Empty_Span,
               Message =>
                 Path
                 & (if Named_Source = ""
                    then " names no compiler sources it was generated from"
                    else " was generated from compiler sources "
                         & Short (Named_Source))
                 & ", and this refine was built from compiler sources "
                 & Short (Own)
                 & Made_At (Landin.Build_Identity.Revision,
                            Landin.Build_Identity.Dirty)
                 & ", so what it says of a construct or a decision may be"
                 & " another revision's; install the "
                 & Landin.Diagnostics.Citations.File_Name
                 & " this refine came with, or regenerate a checkout's"
                 & " with python3 check.py --generate"));
      end Compare_Source;

      --  Find and read the citations file, once.
      procedure Read_Table;

      procedure Read_Table is
         Root : constant String :=
           (if Unbounded.Length (Named) > 0
            then Unbounded.To_String (Named)
            else Landin.Driver.Library.Located (Host));
         Path : constant String :=
           (if Root = "" then ""
            else Loading.Joined_Path
                   (Root, Landin.Diagnostics.Citations.File_Name));
         Content : Unbounded.Unbounded_String;
         Read    : Landin.Platform.Read_Status;
      begin
         Asked_Table := True;
         if Root = "" then
            Unread := Unbounded.To_Unbounded_String
              ("from " & Landin.Diagnostics.Citations.File_Name
               & " in its library, and no library was found: "
               & Landin.Driver.Library.Looked_In (Host)
               & "; name the library's directory with --library=DIR");
            return;
         end if;
         Host.Read_File (Path, Content, Read);
         if Read /= Landin.Platform.Read_Ok then
            Unread := Unbounded.To_Unbounded_String
              ("from " & Path
               & (if Read = Landin.Platform.Not_Found
                  then ", which is not there"
                  else ", which cannot be read")
               & "; install the " & Landin.Diagnostics.Citations.File_Name
               & " this refine came with, or name a library that holds"
               & " it with --library=DIR");
            return;
         end if;
         Table := Landin.Diagnostics.Citations.Read (Content);
         if Landin.Diagnostics.Citations.Readable (Table) then
            Compare_Source (Path);
         else
            Unread := Unbounded.To_Unbounded_String
              ("from " & Path & ", which is written for another refine:"
               & " its first line is `"
               & Landin.Diagnostics.Citations.First_Line (Table)
               & "` and this refine reads `"
               & Landin.Diagnostics.Citations.Format_Line
               & "`; install the "
               & Landin.Diagnostics.Citations.File_Name
               & " this refine came with");
         end if;
      end Read_Table;

      function Row_Line (Name : Rows.Code_Name) return String
        is (Rows.Code (Name)
            & (if Rows.State (Name) = Rows.Retired then "  retired  "
               else "  " & Landin.Diagnostics.Text.Image (Rows.Level (Name))
                    & (if Rows.Level (Name) = Landin.Diagnostics.Error
                       then "    " else "  "))
            & Rows.Rule (Name) & LF);
      Full  : constant Boolean :=
        (for some Index in 2 .. Natural (Arguments.Length) =>
           Arguments.Element (Index) = "--full");
      Asked_For : Natural := 0;
   begin
      for Index in 2 .. Natural (Arguments.Length) loop
         if Is_Library (Arguments.Element (Index)) then
            declare
               Word : constant String := Arguments.Element (Index);
            begin
               Named := Unbounded.To_Unbounded_String
                 (Word (Word'First + Library_Option'Length .. Word'Last));
            end;
         elsif Arguments.Element (Index) /= "--full" then
            Asked_For := Asked_For + 1;
         end if;
      end loop;

      if Asked_For = 0 then
         for Name in Rows.Code_Name loop
            Unbounded.Append (Text, Row_Line (Name));
         end loop;
      end if;

      for Index in 2 .. Natural (Arguments.Length) loop
         declare
            Asked : constant String := Arguments.Element (Index);
         begin
            if Asked = "--full" or else Is_Library (Asked) then
               null;
            elsif Citations.Is_Citation (Asked) then
               if not Asked_Table then
                  Read_Table;
               end if;
               if Unbounded.Length (Unread) > 0 then
                  --  D1240: not misuse, and nothing asked for is lost:
                  --  the citation is named with where else it is read.
                  Found.Append
                    (Landin.Diagnostics.Make
                       (Code    => Code_Unreadable,
                        Level   => Landin.Diagnostics.Error,
                        Source  => Landin.Source.No_Source,
                        Where   => Landin.Source.Empty_Span,
                        Message =>
                          "explain reads constructs and decisions "
                          & Unbounded.To_String (Unread) & "; "
                          & Citations.Elsewhere (Asked)));
               elsif not Citations.Is_Known (Table, Asked) then
                  Refuse (Citations.Unknown (Asked));
               else
                  if Unbounded.Length (Text) > 0 then
                     Unbounded.Append (Text, LF & "");
                  end if;
                  Unbounded.Append
                    (Text, Citations.Answer (Table, Asked, Full));
               end if;
            elsif not Landin.Diagnostics.Is_Valid_Code (Asked)
              or else not Rows.Holds (Asked)
            then
               Refuse ((if Asked'Length > 0 and then Asked (Asked'First) = '-'
                        then "explain takes --full and --library=DIR: "
                        else "no catalogue row holds the code: ")
                       & Asked);
            else
               declare
                  Name : constant Rows.Code_Name := Rows.Named (Asked);
                  Example : constant String :=
                    Landin.Diagnostics.Explanations.Example (Name);
               begin
                  if Unbounded.Length (Text) > 0 then
                     Unbounded.Append (Text, LF & "");
                  end if;
                  Unbounded.Append (Text, Row_Line (Name) & LF);
                  Unbounded.Append
                    (Text,
                     Landin.Diagnostics.Explanations.Explanation (Name)
                     & LF);
                  if Example /= "" then
                     Unbounded.Append (Text, LF & "For example:" & LF & LF);
                     declare
                        Start : Positive := Example'First;
                     begin
                        for At_Byte in Example'Range loop
                           if Example (At_Byte) = LF then
                              Unbounded.Append
                                (Text,
                                 (if At_Byte > Start then "    " else "")
                                 & Example (Start .. At_Byte));
                              Start := At_Byte + 1;
                           end if;
                        end loop;
                     end;
                  end if;
                  --  D1230: a fixture named as the example, built in.
                  if Landin.Diagnostics.Explanations.Fixture (Name) /= ""
                  then
                     Unbounded.Append
                       (Text,
                        LF & Landin.Diagnostics.Explanations.Fixture (Name));
                  end if;
               end;
            end if;
         end;
      end loop;

      --  A warning alone, D1357's, leaves the answer and the status as
      --  they are; an error replaces the answer with the report.
      if Landin.Diagnostics.Count (Found) > 0 then
         if Landin.Diagnostics.Has_Errors (Found) then
            Result.Status :=
              (if Misused then Status_Misuse else Status_Reported);
         else
            Result.Output := Text;
         end if;
         Result.Found := Found;
         declare
            None : Landin.Source.Sets.Source_Set;
         begin
            Result.Report := Unbounded.To_Unbounded_String
              (Landin.Diagnostics.Text.Render (Found, None));
         end;
      else
         Result.Output := Text;
      end if;
      return Result;
   end Explain;

   ---------------------------------------------------------------------
   --  Format
   --
   --  Also a request with no compilation in it.  Every source is its own:
   --  it is read, laid out and written back, or refused, before the next
   --  one is read, and its snapshot joins one source set so the report can
   --  point into every file it names.
   ---------------------------------------------------------------------

   function Format (Arguments : Landin.Platform.Path_List;
                    Host      : Landin.Platform.Filesystem'Class;
                    Protected_Inputs : Landin.Platform.Path_List;
                    Protected_Identities : Landin.Platform.Identity_List)
     return Outcome;

   function Format (Arguments : Landin.Platform.Path_List;
                    Host      : Landin.Platform.Filesystem'Class;
                    Protected_Inputs : Landin.Platform.Path_List;
                    Protected_Identities : Landin.Platform.Identity_List)
     return Outcome
   is
      Result  : Outcome;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Sources : Landin.Source.Sets.Source_Set;
      Named   : Landin.Platform.Path_List;
      Seen    : Path_Sets.Set;
      Explicit : Path_Sets.Set;
      Check   : Boolean := False;
      Printing : Boolean := False;
      Misused : Boolean := False;

      procedure Refuse (Code : Landin.Diagnostics.Code_String;
                        Message : String);

      procedure Refuse (Code : Landin.Diagnostics.Code_String;
                        Message : String) is
      begin
         Found.Append
           (Landin.Diagnostics.Make
              (Code    => Code,
               Level   => Landin.Diagnostics.Error,
               Source  => Landin.Source.No_Source,
               Where   => Landin.Source.Empty_Span,
               Message => Message));
      end Refuse;

      --  One L0008 for every line the layout changes, each showing the
      --  line as the layout writes it (D359), so a reader who cannot or
      --  will not have the file rewritten can lay it out by hand.
      procedure Not_Formatted (Answer : Landin.Formatting.Result);

      procedure Not_Formatted (Answer : Landin.Formatting.Result) is
         Snapshot : Landin.Source.Snapshot renames
           Sources.Get (Answer.Id).Element.all;
         Changes : constant Landin.Formatting.Difference_List :=
           Landin.Formatting.Differences (Snapshot, Answer);
         First : Boolean := True;
      begin
         for Change of Changes loop
            declare
               use type Landin.Formatting.Difference_Kind;
               use type Landin.Source.Byte_Offset;
               Was : constant String :=
                 Landin.Source.Line_Text (Snapshot, Change.Line);
               Wanted : constant String :=
                 Unbounded.To_String (Change.Wanted);
               Trimmed : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Was, Ada.Strings.Maps.Null_Set,
                    Ada.Strings.Maps.To_Set (" " & ASCII.HT));
               Line : constant Landin.Source.Span :=
                 Landin.Source.Line_Text_Span (Snapshot, Change.Line);
               --  D385: a respaced line is marked where it differs, from
               --  its first byte the layout changes to its last, so one
               --  space too many is under the caret rather than somewhere
               --  in a line quoted whole.
               function Marked return Landin.Source.Span;
               function Marked return Landin.Source.Span is
                  Length : constant Natural := Was'Length;
                  Same_Before : Natural := 0;
                  Same_After : Natural := 0;
                  First : Natural;
                  Last : Natural;
               begin
                  if Change.Kind /= Landin.Formatting.Respaced
                    or else Length = 0
                  then
                     return Line;
                  end if;
                  while Same_Before < Length
                    and then Same_Before < Wanted'Length
                    and then Was (Was'First + Same_Before)
                      = Wanted (Wanted'First + Same_Before)
                  loop
                     Same_Before := Same_Before + 1;
                  end loop;
                  while Same_After < Length - Same_Before
                    and then Same_After < Wanted'Length - Same_Before
                    and then Was (Was'Last - Same_After)
                      = Wanted (Wanted'Last - Same_After)
                  loop
                     Same_After := Same_After + 1;
                  end loop;
                  First := Same_Before;
                  Last := Length - Same_After;
                  --  An insertion removes no byte: mark the byte it goes
                  --  before, or the last one when it goes at the end.
                  if Last = First then
                     if First = Length then
                        First := First - 1;
                     else
                        Last := Last + 1;
                     end if;
                  end if;
                  return
                    (First => Line.First + Landin.Source.Byte_Offset (First),
                     Last  => Line.First + Landin.Source.Byte_Offset (Last));
               end Marked;
               Item : Landin.Diagnostics.Diagnostic :=
                 Landin.Diagnostics.Make
                   (Code    => Rows.Code (Rows.Not_Formatted),
                    Level   => Landin.Diagnostics.Error,
                    Source  => Answer.Id,
                    Where   => Marked,
                    Message =>
                      (if Change.Kind = Landin.Formatting.Removed
                       then "this blank line is not in the layout"
                       else "this line is not in the layout"));
            begin
               case Change.Kind is
                  when Landin.Formatting.Removed =>
                     Landin.Diagnostics.Add_Note
                       (Item, "the layout removes it: a run of blank lines"
                              & " is one, and none begins or ends a file");
                  when Landin.Formatting.Ended =>
                     Landin.Diagnostics.Add_Note
                       (Item,
                        (if Landin.Source.Line_Text_Span
                              (Snapshot, Change.Line).Last
                            = Landin.Source.Line_Span
                                (Snapshot, Change.Line).Last
                         then "the layout ends the file's last line with"
                              & " a line end"
                         else "the layout ends this line with LF alone"));
                  when Landin.Formatting.Respaced =>
                     Landin.Diagnostics.Add_Note
                       (Item,
                        (if Wanted = "" then "the layout writes it empty"
                         else "the layout writes it `" & Wanted & "`"
                         & (if Trimmed = Wanted and then Trimmed /= Was
                            then ", without the space at its end"
                            else "")
                         & ", which differs from column"
                         & Landin.Source.Column_Number'Image
                             (Landin.Source.Position_Of
                                (Snapshot,
                                 Landin.Diagnostics.Span_Of
                                   (Landin.Diagnostics.Primary (Item)).First)
                                .Column)));
               end case;
               if First then
                  Landin.Diagnostics.Add_Note
                    (Item, "D252: `refine fmt` writes the whole file in the"
                           & " layout, and `refine fmt --stdout` prints it");
                  First := False;
               end if;
               Found.Append (Item);
            end;
         end loop;
      end Not_Formatted;
      --  D385: every `.ldn` file under a directory, in the order the host
      --  lists names, depth first; a name beginning with a dot is not
      --  entered, as a checkout's `.git` is not, and a directory reached
      --  twice, through a link, is listed once.  A source a directory
      --  reaches that is already named is formatted once.
      Visited : Landin.Platform.Path_List;
      procedure Add_Directory (Directory : String);
      procedure Add_Directory (Directory : String) is
         use type Landin.Platform.List_Status;
         Entries : Landin.Platform.Path_List;
         Listed : Landin.Platform.List_Status;
         Identity : constant Landin.Platform.File_Identity :=
           Host.Existing_Identity (Directory);
      begin
         if Identity.Valid then
            for Other of Visited loop
               if Host.Existing_Identity (Other) = Identity then
                  return;
               end if;
            end loop;
         end if;
         Visited.Append (Directory);
         Host.List_Directory (Directory, Entries, Listed);
         if Listed /= Landin.Platform.List_Ok then
            Misused := True;
            Refuse (Code_Unreadable, "fmt cannot list " & Directory);
            return;
         end if;
         for Name of Entries loop
            if Name'Length > 0 and then Name (Name'First) /= '.' then
               declare
                  Path : constant String :=
                    Loading.Joined_Path (Directory, Name);
               begin
                  if Host.Is_Directory (Path) then
                     Add_Directory (Path);
                  elsif Loading.Is_Source_Name (Name)
                    and then not Seen.Contains (Path)
                  then
                     Seen.Insert (Path);
                     Named.Append (Path);
                  end if;
               end;
            end if;
         end loop;
      end Add_Directory;
   begin
      for Index in 2 .. Natural (Arguments.Length) loop
         declare
            Argument : constant String := Arguments.Element (Index);
         begin
            if Argument = "--check" and then not Check then
               Check := True;
            elsif Argument = "--stdout" and then not Printing then
               Printing := True;
            elsif Argument'Length > 0
              and then Argument (Argument'First) = '-'
            then
               Misused := True;
               Refuse (Code_Unknown_Option,
                       "fmt takes no option but --check or --stdout, once: "
                       & Argument);
            elsif Host.Is_Directory (Argument) then
               --  D385: a directory is the `.ldn` files under it.
               declare
                  Before : constant Natural := Natural (Named.Length);
               begin
                  Add_Directory (Argument);
                  if Natural (Named.Length) = Before and then not Misused
                  then
                     Misused := True;
                     Refuse (Code_Unknown_Option,
                             "fmt found no .ldn source under " & Argument);
                  end if;
               end;
            elsif Explicit.Contains (Argument) then
               Misused := True;
               Refuse (Code_Unknown_Option,
                       "fmt is given one source twice: " & Argument);
            elsif Seen.Contains (Argument) then
               --  A directory named before it already holds it.
               Explicit.Insert (Argument);
            else
               Explicit.Insert (Argument);
               Seen.Insert (Argument);
               Named.Append (Argument);
            end if;
         end;
      end loop;
      if Named.Is_Empty and then not Misused then
         Misused := True;
         Refuse (Code_Unknown_Option, "fmt needs a source to format");
      end if;
      if Check and then Printing and then not Misused then
         Misused := True;
         Refuse (Code_Unknown_Option,
                 "fmt --check reports and fmt --stdout prints; give one");
      end if;
      if Printing and then Natural (Named.Length) > 1 and then not Misused
      then
         Misused := True;
         Refuse (Code_Unknown_Option,
                 "fmt --stdout prints one source; it was given"
                 & Natural'Image (Natural (Named.Length)));
      end if;

      if not Misused then
         for Path of Named loop
            --  A signal that arrived while a source was being rewritten
            --  is recorded, so that rewrite ends whole; no later source
            --  is read, formatted or reported after it.
            exit when Host.Cancellation_Requested;
            declare
               Content : Unbounded.Unbounded_String;
               Read    : Landin.Platform.Read_Status;
               Lease : Landin.Platform.Update_Handle :=
                 Landin.Platform.No_Update;
               Lease_Reason : Unbounded.Unbounded_String;
            begin
               if not Check and then not Printing
                 and then
                   (Host.Paths_Overlap_Any (Path, Protected_Inputs)
                    or else
                      (for some Identity of Protected_Identities =>
                         Identity.Valid and then
                           Host.Identity_Of (Path) = Identity))
               then
                  Lease_Reason := Unbounded.To_Unbounded_String
                    (Unless_Short
                       (Shortage (Host, Path, Protected_Inputs),
                        "cannot compare it with the consumed response"
                        & " inputs",
                        "consumed response input cannot be rewritten;"
                        & " choose another source, or use fmt --stdout"));
                  Read := Landin.Platform.Not_Readable;
               elsif Check or else Printing then
                  Host.Read_File (Path, Content, Read);
               else
                  Host.Read_For_Update
                    (Path, Content, Lease, Read, Lease_Reason);
               end if;
               if Read /= Landin.Platform.Read_Ok then
                  Refuse (Code_Unreadable,
                          (if Read = Landin.Platform.Not_Found
                           then "source not found: "
                           else "source not readable: ") & Path
                          & (if Unbounded.Length (Lease_Reason) > 0
                             then ": " & Unbounded.To_String (Lease_Reason)
                               & "; use fmt --stdout to format"
                               & " without rewriting"
                             else ""));
               else
                  declare
                     Answer : constant Landin.Formatting.Result :=
                       Landin.Formatting.Format
                         (Sources, Path, Unbounded.To_String (Content));
                     Written : Landin.Platform.Write_Status;
                     Reason  : Unbounded.Unbounded_String;
                  begin
                     Result.Named.Append (Path);
                     for Position in 1 .. Answer.Found.Count loop
                        Found.Append (Answer.Found.Get (Position));
                     end loop;
                     if Answer.Outcome = Landin.Formatting.Refused then
                        null;
                     elsif Printing then
                        Unbounded.Append (Result.Output, Answer.Text);
                     elsif Answer.Edits.Is_Empty then
                        null;
                     elsif Check then
                        Not_Formatted (Answer);
                     elsif (for some Identity of Protected_Identities =>
                              Identity.Valid and then
                                Host.Update_Identity (Lease) = Identity)
                     then
                        Refuse
                          (Code_Unwritable,
                           "cannot rewrite consumed response input " & Path
                           & "; choose another source, or use fmt --stdout");
                     else
                        Host.Replace_Update
                          (Lease, Unbounded.To_String (Answer.Text), Written,
                           Reason);
                        if Written /= Landin.Platform.Write_Ok then
                           declare
                              Item : Landin.Diagnostics.Diagnostic :=
                                Landin.Diagnostics.Make
                                  (Code    => Code_Unwritable,
                                   Level   => Landin.Diagnostics.Error,
                                   Source  => Landin.Source.No_Source,
                                   Where   => Landin.Source.Empty_Span,
                                   Message => "cannot rewrite " & Path & ": "
                                     & Unbounded.To_String (Reason));
                           begin
                              Landin.Diagnostics.Add_Note
                                (Item, "`refine fmt --stdout " & Path
                                       & "` prints it in the layout without"
                                       & " writing it");
                              Found.Append (Item);
                           end;
                        end if;
                     end if;
                  end;
               end if;
               Host.Close_Update (Lease);
            exception
               when others =>
                  Host.Close_Update (Lease);
                  raise;
            end;
         end loop;
      end if;

      Result.Found := Found;
      Keep_Locations (Result, Sources);
      Result.Report := Unbounded.To_Unbounded_String
        (Landin.Diagnostics.Text.Render (Found, Sources));
      Result.Status :=
        (if Misused then Status_Misuse
         elsif Found.Has_Errors then Status_Reported
         else Status_Success);
      return Result;
   end Format;

   function Is_Server (Arguments : Landin.Platform.Path_List)
     return Boolean
     is (Natural (Arguments.Length) in 1 .. 2
         and then Arguments.Element (1) = Server_Command
         and then (Natural (Arguments.Length) = 1
                   or else Arguments.Element (2) = "--stdio"));

   --  Where a contributor learns to find the defect's caller: the
   --  compiler guide's section on debugging one, which the published site
   --  renders from the same file.
   Defect_Route : constant String :=
     "refine: compiler/ada/README.md, ""Debugging an internal defect"","
     & " shows how a debug build under gdb's catch assert finds the caller";

   --  Every described firmware target as --target options, in the
   --  selection's order: "--target=cortex-m0, --target=rv32 or
   --  --target=xtensa".  Read from the targets, so a new one is listed.
   function Firmware_Targets (From : Positive := 1) return String;
   function Firmware_Targets (From : Positive := 1) return String is
   begin
      for Index in From .. Landin.Targets.Selection.Described_Count loop
         declare
            Name : constant String :=
              Landin.Targets.Selection.Described_Name (Index);
         begin
            if Landin.Targets.Is_Firmware
                 (Landin.Targets.Selection.Described (Name))
            then
               declare
                  Rest : constant String :=
                    (if Index = Landin.Targets.Selection.Described_Count
                     then "" else Firmware_Targets (Index + 1));
               begin
                  if Rest = "" then
                     return "--target=" & Name;
                  elsif Ada.Strings.Fixed.Index (Rest, " or ") = 0 then
                     return "--target=" & Name & " or " & Rest;
                  end if;
                  return "--target=" & Name & ", " & Rest;
               end;
            end if;
         end;
      end loop;
      return "";
   end Firmware_Targets;

   function Starts_With (Text : String; Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   --  D362: an operand naming GNU assembly, which `compile` links as it
   --  links the assembly it emits, rather than reading it as Landin.
   function Is_Assembly_Operand (Text : String) return Boolean
     is (Text'Length > 2
         and then Text (Text'Last - 1 .. Text'Last) = ".s");

   function After (Text : String; Prefix : String) return String is
     (Text (Text'First + Prefix'Length .. Text'Last));

   ---------------------------------------------------------------------
   --  Execute
   ---------------------------------------------------------------------

   function Execute
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class) return Outcome
   is
      Nothing : Landin.Platform.Unmetered;
   begin
      return Execute (Arguments, Host, Tools, Nothing);
   end Execute;

   function Execute
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Meter     : Landin.Platform.Resource_Meter'Class;
      Built_For : String := Landin.Targets.Selection.Build_Triplet;
      Dry_Run   : Boolean := False;
      Depfile   : String := "";
      Warnings  : Landin.Diagnostics.Warning_Policy.Policy :=
        Landin.Diagnostics.Warning_Policy.Defaults;
      Protected_Inputs : Landin.Platform.Path_List :=
        Landin.Platform.No_Arguments;
      Protected_Identities : Landin.Platform.Identity_List :=
        Landin.Platform.Identity_Vectors.Empty_Vector) return Outcome
   is
      --  D257: the compiler's own host unless --target= names another.  A
      --  host no description covers has no default, and a build that then
      --  names none is refused before it is compiled for anything.
      Has_Default : constant Boolean :=
        Landin.Targets.Selection.Has_Host_Default (Built_For);
      Facts    : Landin.Targets.Target_Facts :=
        (if Has_Default
         then Landin.Targets.Selection.Host_Default (Built_For)
         else Landin.Targets.Synthetic_32);
      Inputs   : Landin.Platform.Path_List;
      Roots    : Landin.Platform.Path_List;
      Options  : Landin.Platform.Path_List;
      Modes    : Landin.Platform.Path_List;
      Result   : Outcome;
      Bad_Use  : Boolean := False;
      Unknowns : Landin.Platform.Path_List;
      Targets  : Landin.Platform.Path_List;
      Rejected : Landin.Platform.Path_List;
      Levels   : Landin.Platform.Path_List;
      Level    : Landin.Targets.Levels.Feature_Level;
      Level_Problem : Unbounded.Unbounded_String;
      Wants_Usage    : Boolean := False;
      Wants_Identity : Boolean := False;
      Emit      : Emit_Kind := Emit_Nothing;
      Output    : Unbounded.Unbounded_String;
      Output_Problem : Unbounded.Unbounded_String;
      Toolchain : Unbounded.Unbounded_String;
      Linker    : Unbounded.Unbounded_String;
      Toolchain_Seen, Linker_Seen : Boolean := False;
      --  How a hosted executable is linked.  Static on Linux,
      --  where the program's own `_landin_start` and system calls need no
      --  C library; libc, with C's runtime and library, everywhere else
      --  and when asked for.
      type Link_Kind is (Link_Default, Link_Static, Link_Libc);
      Link_Mode : Link_Kind := Link_Default;
      Link_Seen : Boolean := False;
      Firmware_Name : Unbounded.Unbounded_String;
      Firmware_Seen : Boolean := False;
      use type Landin.Targets.Firmware.Layout_Kind;
      Layout_Seen : Boolean := False;
      Selected_Layout : Landin.Targets.Firmware.Layout_Kind :=
        Landin.Targets.Firmware.Boot_Layout;
      --  D546: a developer's linker script, linked in place of OUT.ld.
      Script_Path : Unbounded.Unbounded_String;
      Script_Seen : Boolean := False;
      Library_Path : Unbounded.Unbounded_String;
      Library_Seen : Boolean := False;
      --  D524: each `-L` as written, in the order written.
      Search_Options : Landin.Platform.Path_List;
      Build_Report_Path : Unbounded.Unbounded_String;
      Stage_Report_Path : Unbounded.Unbounded_String;
      Stage_Report_Seen : Boolean := False;
      Stack_Report_Path : Unbounded.Unbounded_String;
      Stack_Report_Seen : Boolean := False;
      Optimization : Landin.Optimization.Options :=
        Landin.Optimization.Default_Options;
      Optimize_Seen, Specialize_Seen, Report_Seen : Boolean := False;
      Annotated_IR : Boolean := False;
      Debug_Seen, Debug_Enabled : Boolean := False;
      Lines_Debug : Boolean := False;
      Panic_Map : Boolean := False;
      Emit_Seen, Output_Seen : Boolean := False;
      --  D362: an executable's assembly is kept beside it only on request.
      Keep_Assembly : Boolean := False;
      Skip_Compilation : Boolean := False;
      Index     : Positive := 1;
      Dependency_Directories : aliased Landin.Platform.Path_List;

      --  Why the options given cannot be one request, or "": the command
      --  catalogue's sentence for the first option whose requirement the
      --  request does not meet (D565).
      function Incompatible_Action return String;

      function Incompatible_Action return String is
         package C renames Landin.Commands.Catalogue;
         use type C.Option;
         Present : constant array (C.Option) of Boolean :=
           [C.Optimize => Optimize_Seen, C.Specialize => Specialize_Seen,
            C.Build_Report => Report_Seen, C.Debug => Debug_Seen,
            C.Panic_Map => Panic_Map, C.Stage_Report => Stage_Report_Seen,
            C.Stack_Report => Stack_Report_Seen,
            C.Toolchain => Toolchain_Seen, C.Linker => Linker_Seen,
            C.Link => Link_Seen, C.Firmware_Entry => Firmware_Seen,
            C.Firmware_Layout => Layout_Seen,
            C.Keep_Asm => Keep_Assembly,
            C.Output => Output_Seen
              and then Unbounded.Length (Output_Problem) = 0,
            others => False];
         Emitted : constant C.Emission :=
           (case Emit is
               when Emit_Nothing => C.No_Emission,
               when Emit_Assembly => C.Emit_Asm,
               when Emit_Executable => C.Emit_Exe,
               when Emit_IR => C.Emit_IR,
               when Emit_Linker_Script => C.Emit_Linker_Script);
      begin
         if (Wants_Usage or Wants_Identity)
           and then (for some Flag in C.Option =>
                       Present (Flag) and then Flag /= C.Output)
         then
            return C.Informational_Problem
              (if Wants_Usage then "--help" else "--identify");
         end if;
         for Flag in C.Option loop
            if Present (Flag) then
               declare
                  Problem : constant String :=
                    C.Requirement_Problem
                      (Flag, Emitted, Natural (Inputs.Length) > 0);
               begin
                  if Problem /= "" then
                     return Problem;
                  end if;
               end;
            end if;
         end loop;
         if Present (C.Output) and then Unbounded.Length (Output) = 0 then
            return "-o needs a path";
         end if;
         return "";
      end Incompatible_Action;
   begin
      if Natural (Arguments.Length) = 0 then
         Result.Status := Status_Misuse;
         Result.Output := Unbounded.To_Unbounded_String (Usage);
         return Result;
      end if;

      if Arguments.Element (1) = Explain_Command then
         return Explain (Arguments, Host);
      elsif Arguments.Element (1) = Format_Command then
         return Format
           (Arguments, Host, Protected_Inputs, Protected_Identities);
      elsif Arguments.Element (1) = Server_Command then
         --  A server is started by the caller when Is_Server says so, so
         --  an argument list that reaches here is a misuse of it.
         declare
            Found : Landin.Diagnostics.Diagnostic_List;
            Sources : Landin.Source.Sets.Source_Set;
         begin
            Found.Append
              (Landin.Diagnostics.Make
                 (Code    => Code_Unknown_Option,
                  Level   => Landin.Diagnostics.Error,
                  Source  => Landin.Source.No_Source,
                  Where   => Landin.Source.Empty_Span,
                  Message => "lsp takes no argument but --stdio"));
            Result.Found := Found;
            Result.Report := Unbounded.To_Unbounded_String
              (Landin.Diagnostics.Text.Render (Found, Sources));
            Result.Status := Status_Misuse;
            return Result;
         end;
      end if;

      --  Argument classification first, so that a request is fully known
      --  before anything is acted on.  Returning from inside this loop was
      --  a real defect: `refine --wat --identify` printed the identity and
      --  exited zero, so a script checking the status read a misuse as a
      --  success.
      --
      --  An index and not a cursor, because `-o` takes the argument after
      --  it.  `-o=PATH` keeps a leading dash in a literal path unambiguous.
      --  Every other option carries its value with an `=`.
      while Index <= Natural (Arguments.Length) loop
         declare
            Argument : constant String := Arguments.Element (Index);
         begin
            if Argument = "--help" then
               Wants_Usage := True;

            elsif Argument = "--identify" then
               Wants_Identity := True;

            elsif Starts_With (Argument, "--target=") then
               Targets.Append (After (Argument, "--target="));

            elsif Starts_With (Argument, "--level=") then
               Levels.Append (After (Argument, "--level="));

            elsif Starts_With (Argument, "--option=") then
               Options.Append (After (Argument, "--option="));

            elsif Starts_With (Argument, "--build-mode=") then
               Modes.Append (After (Argument, "--build-mode="));

            elsif Starts_With (Argument, "--optimize=") then
               declare
                  Accepted : Boolean;
               begin
                  Landin.Optimization.Parse
                    (After (Argument, "--optimize="),
                     Optimization.Optimize, Accepted);
                  if Optimize_Seen or else not Accepted then
                     Unknowns.Append (Argument);
                     Bad_Use := True;
                  end if;
                  Optimize_Seen := True;
               end;

            elsif Starts_With (Argument, "--specialize=") then
               declare
                  Accepted : Boolean;
               begin
                  Landin.Optimization.Parse
                    (After (Argument, "--specialize="),
                     Optimization.Specialize, Accepted);
                  if Specialize_Seen or else not Accepted then
                     Unknowns.Append (Argument);
                     Bad_Use := True;
                  end if;
                  Specialize_Seen := True;
               end;

            elsif Argument = "--keep-asm" then
               if Keep_Assembly then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Keep_Assembly := True;

            elsif Argument = "--panic-map" then
               if Panic_Map then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Panic_Map := True;

            elsif Starts_With (Argument, "--debug=") then
               if Debug_Seen
                 or else After (Argument, "--debug=")
                   not in "none" | "full" | "lines"
               then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Debug_Seen := True;
               Lines_Debug := After (Argument, "--debug=") = "lines";
               Debug_Enabled := Lines_Debug
                 or else After (Argument, "--debug=") = "full";

            elsif Starts_With (Argument, "--build-report=") then
               if Report_Seen
                 or else After (Argument, "--build-report=") = ""
               then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Report_Seen := True;
               Build_Report_Path := Unbounded.To_Unbounded_String
                 (After (Argument, "--build-report="));

            elsif Starts_With (Argument, "--stage-report=") then
               if Stage_Report_Seen
                 or else After (Argument, "--stage-report=") = ""
               then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Stage_Report_Seen := True;
               Stage_Report_Path := Unbounded.To_Unbounded_String
                 (After (Argument, "--stage-report="));

            elsif Starts_With (Argument, "--stack-report=") then
               if Stack_Report_Seen
                 or else After (Argument, "--stack-report=") = ""
               then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Stack_Report_Seen := True;
               Stack_Report_Path := Unbounded.To_Unbounded_String
                 (After (Argument, "--stack-report="));

            elsif Starts_With (Argument, "--root=") then
               Roots.Append (After (Argument, "--root="));

            elsif Starts_With (Argument, "--library=") then
               if Library_Seen then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Library_Seen := True;
               Library_Path := Unbounded.To_Unbounded_String
                 (After (Argument, "--library="));

            elsif Starts_With (Argument, "-L=") then
               Search_Options.Append (After (Argument, "-L="));

            elsif Starts_With (Argument, "--firmware-entry=") then
               if Firmware_Seen
                 or else After (Argument, "--firmware-entry=") = ""
               then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Firmware_Seen := True;
               Firmware_Name := Unbounded.To_Unbounded_String
                 (After (Argument, "--firmware-entry="));

            elsif Starts_With (Argument, "--firmware-layout=") then
               if Layout_Seen
                 or else After (Argument, "--firmware-layout=")
                   not in "boot" | "ram"
               then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Layout_Seen := True;
               Selected_Layout :=
                 (if After (Argument, "--firmware-layout=") = "ram"
                  then Landin.Targets.Firmware.RAM_Layout
                  else Landin.Targets.Firmware.Boot_Layout);

            elsif Starts_With (Argument, "--linker-script=") then
               if Script_Seen
                 or else After (Argument, "--linker-script=") = ""
               then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Script_Seen := True;
               Script_Path := Unbounded.To_Unbounded_String
                 (After (Argument, "--linker-script="));

            elsif Starts_With (Argument, "--toolchain=") then
               if Toolchain_Seen
                 or else After (Argument, "--toolchain=") = ""
               then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Toolchain_Seen := True;
               Toolchain :=
                 Unbounded.To_Unbounded_String
                   (After (Argument, "--toolchain="));

            elsif Starts_With (Argument, "--linker=") then
               if Linker_Seen
                 or else After (Argument, "--linker=") = ""
               then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Linker_Seen := True;
               Linker :=
                 Unbounded.To_Unbounded_String
                   (After (Argument, "--linker="));

            elsif Starts_With (Argument, "--link=") then
               if Link_Seen then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Link_Seen := True;
               declare
                  Mode : constant String := After (Argument, "--link=");
               begin
                  if Mode = "static" then
                     Link_Mode := Link_Static;
                  elsif Mode = "libc" then
                     Link_Mode := Link_Libc;
                  else
                     Unknowns.Append (Argument);
                     Bad_Use := True;
                  end if;
               end;

            elsif Starts_With (Argument, "--emit=") then
               if Emit_Seen then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Emit_Seen := True;
               declare
                  Kind : constant String := After (Argument, "--emit=");
               begin
                  if Kind = "asm" then
                     Emit := Emit_Assembly;
                  elsif Kind = "exe" then
                     Emit := Emit_Executable;
                  elsif Kind in "ir" | "ir-annotated" then
                     Emit := Emit_IR;
                     Annotated_IR := Kind = "ir-annotated";
                  elsif Kind = "linker-script" then
                     Emit := Emit_Linker_Script;
                  else
                     Unknowns.Append (Argument);
                     Bad_Use := True;
                  end if;
               end;

            elsif Starts_With (Argument, "-o=") then
               if Output_Seen or else After (Argument, "-o=") = "" then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Output_Seen := True;
               Output := Unbounded.To_Unbounded_String
                 (After (Argument, "-o="));

            elsif Argument = "-o" then
               if Output_Seen then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               end if;
               Output_Seen := True;
               --  A `-o` with nothing after it is a misuse and not an
               --  empty path: silently writing to "" would be the worst
               --  reading of a request that is simply unfinished.
               if Index = Natural (Arguments.Length) then
                  Unknowns.Append (Argument);
                  Bad_Use := True;
               elsif Starts_With (Arguments.Element (Index + 1), "-") then
                  Output_Problem := Unbounded.To_Unbounded_String
                    ("-o needs a path before " & Arguments.Element
                       (Index + 1));
                  Bad_Use := True;
               else
                  Index := Index + 1;
                  Output :=
                    Unbounded.To_Unbounded_String (Arguments.Element (Index));
               end if;

            elsif Starts_With (Argument, "-") then
               Unknowns.Append (Argument);
               Bad_Use := True;

            else
               Inputs.Append (Argument);
            end if;
         end;

         Index := Index + 1;
      end loop;

      --  Compilation controls do not modify informational actions, and
      --  what each option needs of the request is the command catalogue's
      --  (D565): debug information, a panic map and a stack report describe
      --  emitted machine code, and a build report may describe a check
      --  (D383).
      if Incompatible_Action /= "" then
         Unknowns.Append ("incompatible compilation action");
         Bad_Use := True;
      end if;

      --  The target is resolved before the compilation exists.  Creating
      --  the context first and reassigning the local afterwards was a real
      --  defect: every compilation silently carried the default target
      --  however the command line was written.
      for Name of Targets loop
         if Landin.Targets.Selection.Is_Described (Name) then
            Facts := Landin.Targets.Selection.Described (Name);
         else
            Rejected.Append (Name);
         end if;
      end loop;
      if Natural (Targets.Length) > 1 then
         Unknowns.Append ("--target given more than once");
         Bad_Use := True;
      end if;

      --  A level is a level of the family the target selected, so it is
      --  resolved after the target, and a level named for another family
      --  is refused rather than read as the nearest one this family has.
      Level := Landin.Targets.Levels.Default_Level (Facts);
      if Natural (Levels.Length) > 1 then
         Unknowns.Append ("--level given more than once");
         Bad_Use := True;
      elsif Natural (Levels.Length) = 1 and then Rejected.Is_Empty then
         if Landin.Targets.Levels.Is_Level_Of
           (Facts, Levels.Element (1))
         then
            Level := Landin.Targets.Levels.Level_Named
              (Facts, Levels.Element (1));
         else
            Level_Problem := Unbounded.To_Unbounded_String
              ("unknown level for " & Landin.Targets.Name (Facts) & ": "
               & Levels.Element (1) & "; valid levels: "
               & Landin.Targets.Levels.Levels_Of (Facts)
               & "; refine targets lists every target and its levels");
         end if;
      end if;

      declare
         Context : Landin.Stages.Compilation :=
           Landin.Stages.Create (Facts, Level);
         Panic : aliased Landin.Panics.Plan;
         Panic_Problem : Unbounded.Unbounded_String;
         --  The driver a link runs, once the program is known to need one.
         Chosen_Driver : Unbounded.Unbounded_String;
         --  An executable's assembly once written, which D362 removes
         --  after the link unless --keep-asm asked for it.
         Intermediate_Assembly : Unbounded.Unbounded_String;
         package Publication renames Landin.Platform.Publication;
         Artifacts, Stage_Report : Publication.Transaction;
         Reserved, Known_Inputs, Absent_Tool_Names : Landin.Platform.Path_List;
         Publication_Failed : Boolean := False;
         --  A signal asked the invocation to stop, and publication refused
         --  because of it.  The build stops publishing as on any refusal,
         --  but reports no output fault: the command line names the signal,
         --  and nothing it names was replaced.
         Cancelled : Boolean := False;
         Pending_Publication_Failure : Unbounded.Unbounded_String;
         Pending_Write_Reason : Unbounded.Unbounded_String;
         Artifacts_Closed : Boolean := False;
         --  D685: what the build report records of the ESP application
         --  image the link was followed by, once written and read back.
         ESP_Image_Report : Unbounded.Unbounded_String;
         --  The image that report describes, which a cleanup refusal after
         --  publication names as written and read back.
         ESP_Image_Path : Unbounded.Unbounded_String;
         --  Whether each group's cleanup state has been reported, so the
         --  exception paths that finish again do not report it twice.
         Artifacts_Cleanup_Noted, Stage_Report_Cleanup_Noted : Boolean :=
           False;
         Target_Option_Refused : Boolean := False;
         Policy_Denied : Boolean := False;

         --  A Linux executable links static unless --link=libc asks for C's
         --  runtime; every other hosted system links through its libc.
         function Static_Link return Boolean
           is (Landin.Targets.Capabilities.Hosted_System_Of (Facts)
                 = Landin.Targets.Capabilities.Linux
               and then Link_Mode /= Link_Libc);

         --  D364: the drivers a link may use, in the order tried; the
         --  host's own `gcc` among them only for the compiler's own host.
         Native_Target : constant Boolean :=
           Has_Default
           and then Facts = Landin.Targets.Selection.Host_Default (Built_For);
         Candidates : constant Landin.Platform.Path_List :=
           Landin.Backend.Toolchain.Driver_Candidates
             (Facts, Unbounded.To_String (Toolchain), Native_Target,
              Landin.Targets.Levels.Name (Level));

         --  The first candidate the host can start, or "".  Run asks the
         --  host again, so a driver removed meanwhile is still reported.
         function Available_Driver return String;
         function Available_Driver return String is
         begin
            for Name of Candidates loop
               if Tools.Available (Name) then
                  return Name;
               end if;
            end loop;
            return "";
         end Available_Driver;

         --  What a dry run says would run: the driver a link would take
         --  now, or the first it would look for when none is installed.
         function Planned_Driver return String
           is (if Available_Driver /= "" then Available_Driver
               elsif Candidates.Is_Empty then ""
               else Candidates.First_Element);

         --  What a static link starts at is library source: the program
         --  holds platform/linux, whose `_landin_start` is the process entry,
         --  whether or not its own imports reach it, as C's startup object
         --  is linked into every C program. Checking uses that same graph
         --  when the selected library supplies it; a standalone check with
         --  no such library keeps the loader's existing optional boundary.
         function Implicit_Module return String
           is (if Static_Link
               then "platform/linux" else "");

         function Policy_Report return Landin.Diagnostics.Diagnostic_List;
         function Policy_Report return Landin.Diagnostics.Diagnostic_List is
           (Landin.Diagnostics.Warning_Policy.Apply
              (Warnings, Landin.Stages.Report (Context)));

         function Render_Report return String;
         function Render_Report return String is
           (Landin.Diagnostics.Text.Render
              (Policy_Report, Landin.Stages.Sources (Context).all));

         procedure Keep_Report;

         --  The report as data beside its rendering, sorted as it was
         --  rendered, and every source's name so a Source_Id means a path.
         procedure Keep_Report is
         begin
            Result.Named.Clear;
            Result.Found :=
              Landin.Diagnostics.Sorted (Policy_Report);
            for Index in 1 .. Landin.Stages.Source_Count (Context) loop
               Result.Named.Append
                 (Landin.Source.Name
                    (Landin.Stages.Source
                       (Context,
                        Landin.Stages.Nth_Source (Context, Index))
                       .Element.all));
            end loop;
            Keep_Locations (Result, Landin.Stages.Sources (Context).all);
         end Keep_Report;

         procedure Note_Failure
           (Code : Landin.Diagnostics.Code_String; Text : String);

         --  A tool's failure: one line saying which tool and how it
         --  ended, and under it what the tool said, a line each.
         procedure Note_Tool_Failure (Summary, Said : String);

         --  An absent destination is ordinary only when its parent can be
         --  resolved. Paths_Overlap deliberately answers True for unknown
         --  identities; that conservative answer is not proof of collision.
         procedure Check_Output_Parent (Path, Kind : String);

         procedure Check_Output_Parent (Path, Kind : String) is
            Seen : Landin.Platform.Identity_Observation;
         begin
            if Bad_Use or else Path = "" or else Host.Exists (Path) then
               return;
            end if;
            Seen := Host.Observe_Identity (Path);
            if Seen.Status = Landin.Platform.Not_Found
              and then not Seen.Parent_Resolved
            then
               Bad_Use := True;
               Note_Failure
                 (Code_Unwritable, Kind & " parent is missing: " & Path
                  & "; create the parent directory or choose an output"
                  & " path under an existing directory, then retry");
            elsif Seen.Status = Landin.Platform.Not_Readable then
               Bad_Use := True;
               Note_Failure
                 (Code_Unwritable, "cannot establish " & Kind
                  & " identity: " & Path
                  & "; check the destination and parent access or choose"
                  & " another output path, then retry");
            end if;
         end Check_Output_Parent;

         function Source_Conflict
           (Kind, Path : String; Sources : Landin.Platform.Path_List)
            return String;

         function Source_Conflict
           (Kind, Path : String; Sources : Landin.Platform.Path_List)
            return String is
           (if (for some Input of Sources =>
                  Path = Input or else Host.Same_File (Path, Input))
            then Kind & " collides with source: " & Path
              & "; choose another output path and retry"
            else Unless_Short
              (Shortage (Host, Path, Sources),
               "cannot compare " & Kind & " " & Path & " with the sources",
               "cannot prove " & Kind & " separate from source: " & Path
               & "; check source and output paths and access, or choose"
               & " another output path and retry"));

         function Output_Conflict
           (Kind, Path, Other : String;
            Other_Kind : String := "another output")
            return String;

         function Output_Conflict
           (Kind, Path, Other : String;
            Other_Kind : String := "another output")
            return String is
           (if Path = Other or else Host.Same_File (Path, Other)
            then Kind & " collides with " & Other_Kind & ": " & Path
              & " and " & Other & "; choose another output path and retry"
            else Unless_Short
              (Shortage (Host, Path, [Other]),
               "cannot compare " & Kind & " " & Path & " with "
               & Other_Kind & " " & Other,
               "cannot prove " & Kind & " separate from " & Other_Kind
               & ": " & Path & " and " & Other
               & (if (for some Byte of String'(Path & Other) =>
                        Byte in '~' | ':' or else Character'Pos (Byte) > 127)
                  then "; this filesystem's rules for names are not known"
                    & " here, and one holding '~', ':' or a character"
                    & " outside ASCII may be another spelling of a"
                    & " different name"
                  else "")
               & "; check output paths and access, or choose another"
               & " output path and retry"));

         --  An output said to collide with or not be provably separate
         --  from an input, unless the host ran short of what the lookup
         --  needed, which is said instead.
         function Input_Conflict (Kind, Path, Input : String) return String;

         function Input_Conflict (Kind, Path, Input : String) return String
           is (Unless_Short
                 ((if Path = Input then ""
                   else Shortage (Host, Path, [Input])),
                  "cannot compare " & Kind & " " & Path & " with input "
                  & Input,
                  Kind & " " & Path
                  & " collides with or cannot be proved separate"
                  & " from input " & Input
                  & "; check paths and access or choose another"
                  & " output path and retry"));

         function Artifact_Output return String is
           (if Unbounded.Length (Output) > 0
            then Unbounded.To_String (Output)
            elsif Emit = Emit_Executable then Default_Executable
            elsif Emit = Emit_IR then Default_IR
            elsif Emit = Emit_Linker_Script then Default_Script
            else Default_Assembly);

         procedure Check_Separate_Output (Kind, Path, Other : String);

         procedure Check_Separate_Output (Kind, Path, Other : String) is
         begin
            if not Bad_Use and then Other /= ""
              and then Host.Paths_Overlap (Path, Other)
            then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option, Output_Conflict (Kind, Path, Other));
            end if;
         end Check_Separate_Output;

         --  What is wrong with an argument the driver refused.  A known
         --  option misused is said to be misused, and how; an unknown one
         --  is named with the known option nearest it, when one is near.
         function Option_Problem (Option : String) return String;

         --  The options `refine` reads, each as it is spelled before any
         --  `=`, and those that read a value after it.
         function Is_Known_Option (Stem : String) return Boolean
           is (Stem in "--help" | "--identify"
               or else
                 (Landin.Commands.Catalogue.Known_Option (Stem)
                  and then Landin.Commands.Catalogue.Name
                    (Landin.Commands.Catalogue.Named_Option (Stem)) = Stem
                  and then Landin.Commands.Catalogue.Compilation_Option
                    (Landin.Commands.Catalogue.Named_Option (Stem))));

         --  How many times an option with this stem was written.
         function Times_Written (Stem : String) return Natural;

         function Times_Written (Stem : String) return Natural is
            Seen : Natural := 0;
         begin
            for Written of Arguments loop
               if Written = Stem
                 or else Starts_With (Written, Stem & "=")
               then
                  Seen := Seen + 1;
               end if;
            end loop;
            return Seen;
         end Times_Written;

         --  A recognized Cortex core's target/level pair, otherwise
         --  "; did you mean T?" for the described target nearest Name,
         --  or "".  `macos` is what a reader calls `darwin`.  A system
         --  named alone, `linux` or `darwin`, is too far from any target
         --  to be near one, and is offered every target of that system.
         function Nearest_Target (Name : String) return String;

         function Nearest_Target (Name : String) return String is
            Offered : Landin.Diagnostics.Suggestions.Ranking;
            Asked   : constant String :=
              (if Starts_With (Name, "macos")
               then "darwin" & Name (Name'First + 5 .. Name'Last)
               else Name);

            --  The described targets from Index on that Asked begins, as
            --  a system begins its targets, separated by commas.
            function Begun (Index : Positive) return String;

            function Begun (Index : Positive) return String is
               Rest : constant String :=
                 (if Index < Landin.Targets.Selection.Described_Count
                  then Begun (Index + 1) else "");
               Here : constant String :=
                 Landin.Targets.Selection.Described_Name (Index);
            begin
               if not Starts_With (Here, Asked & "-") then
                  return Rest;
               elsif Rest = "" then
                  return Here;
               end if;
               return Here & ", " & Rest;
            end Begun;
         begin
            if Landin.Targets.Firmware.Is_Core_Name (Name) then
               declare
                  Core : constant Landin.Targets.Firmware.Core_Kind :=
                    Landin.Targets.Firmware.Core_Named (Name);
               begin
                  if Core in Landin.Targets.Firmware.Arm_Core then
                     return "; Cortex-M cores share one target, so for "
                       & Name & " use --target="
                       & Landin.Targets.Name (Landin.Targets.Cortex_M)
                       & " --level="
                       & Landin.Targets.Firmware.Level_Name (Core);
                  end if;
               end;
            end if;
            --  A Cortex-M core the table lacks is near `cortex-m0` in
            --  spelling only: offering that target would read as if it
            --  covered the core, so the cores it does cover are named.
            if Starts_With (Name, "cortex-m") then
               declare
                  Covered : Unbounded.Unbounded_String;
                  use type Landin.Targets.Firmware.Core_Kind;
               begin
                  for Core in Landin.Targets.Firmware.Arm_Core loop
                     Unbounded.Append
                       (Covered,
                        (if Core = Landin.Targets.Firmware.Arm_Core'First
                         then ""
                         elsif Core = Landin.Targets.Firmware.Arm_Core'Last
                         then " and "
                         else ", ")
                        & Landin.Targets.Firmware.Spelling (Core)
                        & " (--level="
                        & Landin.Targets.Firmware.Level_Name (Core) & ")");
                  end loop;
                  return "; no Cortex-M core of that name is supported:"
                    & " --target="
                    & Landin.Targets.Name (Landin.Targets.Cortex_M)
                    & " covers " & Unbounded.To_String (Covered);
               end;
            end if;
            for Index in 1 .. Landin.Targets.Selection.Described_Count loop
               Landin.Diagnostics.Suggestions.Consider
                 (Offered, Asked,
                  Landin.Targets.Selection.Described_Name (Index));
            end loop;
            if Asked /= Name
              and then Landin.Targets.Selection.Is_Described (Asked)
            then
               return "; did you mean " & Asked & "?";
            elsif Landin.Diagnostics.Suggestions.Count (Offered) = 0 then
               declare
                  Listed : constant String := Begun (1);
                  Last   : constant Natural :=
                    Ada.Strings.Fixed.Index
                      (Listed, ", ", Going => Ada.Strings.Backward);
               begin
                  if Listed = "" then
                     return "";
                  elsif Last = 0 then
                     return "; did you mean " & Listed & "?";
                  end if;
                  return "; did you mean "
                    & Listed (Listed'First .. Last - 1) & " or "
                    & Listed (Last + 2 .. Listed'Last) & "?";
               end;
            end if;
            return "; did you mean "
              & Landin.Diagnostics.Suggestions.Nth (Offered, 1) & "?";
         end Nearest_Target;

         function Option_Problem (Option : String) return String is
            Equals : constant Natural :=
              Ada.Strings.Fixed.Index (Option, "=");
            Stem : constant String :=
              (if Equals = 0 then Option
               else Option (Option'First .. Equals - 1));
            Value : constant String :=
              (if Equals = 0 then ""
               else Option (Equals + 1 .. Option'Last));
         begin
            if Option = "incompatible compilation action" then
               return Incompatible_Action;
            elsif Option = "--target given more than once" then
               return Landin.Commands.Catalogue.Given_Twice ("--target");
            elsif Option = "--level given more than once" then
               return Landin.Commands.Catalogue.Given_Twice ("--level");
            elsif Is_Known_Option (Stem) then
               if Times_Written (Stem) > 1 then
                  return Landin.Commands.Catalogue.Given_Twice (Stem);
               elsif Equals /= 0 and then Value = "" then
                  return Stem & " needs a value after `=`"
                    & Landin.Commands.Catalogue.Value_Choices
                        (Landin.Commands.Catalogue.Named_Option (Stem));
               elsif Equals /= 0 then
                  return Landin.Commands.Catalogue.Value_Problem
                    (Landin.Commands.Catalogue.Named_Option (Stem), Value);
               elsif Stem = "-o" then
                  return "-o needs a path after it";
               end if;
               return Stem & " is not used this way";
            end if;
            --  An option the command line reads and this entry point
            --  does not: it exists, and saying "unknown" would deny it.
            if Landin.Commands.Catalogue.Known_Option (Stem)
              and then Landin.Commands.Catalogue.Name
                (Landin.Commands.Catalogue.Named_Option (Stem)) = Stem
            then
               declare
                  package C renames Landin.Commands.Catalogue;
                  Flag : constant C.Option := C.Named_Option (Stem);
               begin
                  return Stem & " is an option of the command line, which"
                    & " Landin.Commands.Execute reads: Landin.Driver.Execute"
                    & " does not take it as an argument"
                    & (case Flag is
                         when C.Depfile =>
                           ", and takes the path as its Depfile parameter",
                         when C.Dry_Run =>
                           ", and takes the request as its Dry_Run"
                           & " parameter",
                         when C.Warnings .. C.Deny =>
                           ", and takes the policy as its Warnings"
                           & " parameter",
                         when others => "");
               end;
            end if;
            declare
               Near : constant String :=
                 Landin.Commands.Catalogue.Nearest_Option (Stem);
            begin
               return "unknown option: " & Option
                 & (if Near /= "" then "; did you mean " & Near & "?"
                    else "");
            end;
         end Option_Problem;

         procedure Note_Failure
           (Code : Landin.Diagnostics.Code_String; Text : String)
         is
         begin
            Landin.Stages.Report
              (Context,
               Landin.Diagnostics.Make
                 (Code    => Code,
                  Level   => Landin.Diagnostics.Error,
                  Source  => Landin.Source.No_Source,
                  Where   => Landin.Source.Empty_Span,
                  Message => Text));
         end Note_Failure;

         procedure Note_Tool_Failure (Summary, Said : String) is
            Item : Landin.Diagnostics.Diagnostic :=
              Landin.Diagnostics.Make
                (Code    => Code_Toolchain_Failed,
                 Level   => Landin.Diagnostics.Error,
                 Source  => Landin.Source.No_Source,
                 Where   => Landin.Source.Empty_Span,
                 Message => Summary);
         begin
            Landin.Diagnostics.Set_Transcript (Item, Said);
            Landin.Stages.Report (Context, Item);
         end Note_Tool_Failure;

         --  D780: ld refuses an object of the other AAPCS32 variant as
         --  "A uses VFP register arguments, B does not", in either order,
         --  naming refine's own object by its output path.  The variant
         --  is the description's float unit's, so the relay says which
         --  one that is and the GCC flags that build a C archive for it.
         function Float_Variant_Advice (Said : String) return String;
         function Float_Variant_Advice (Said : String) return String is
         begin
            if not Landin.Targets.Is_Firmware (Facts)
              or else Ada.Strings.Fixed.Index
                (Said, "uses VFP register arguments") = 0
            then
               return "";
            end if;
            declare
               Unit : constant Landin.Targets.Firmware.Float_Unit :=
                 Landin.IR.Firmware_Profile
                   (Landin.Stages.Code (Context).all).Float;
               use type Landin.Targets.Firmware.Float_Unit;
            begin
               return LF & "the object ld names by the output's path is"
                 & " this program's, and the other is a C archive's built"
                 & " for the other AAPCS32 variant; "
                 & (if Unit = Landin.Targets.Firmware.No_Float_Unit
                    then "the device description names no float unit, so"
                      & " this program passes floats in core registers:"
                      & " build the archive with -mfloat-abi=soft"
                    else "the device description's float unit is "
                      & Landin.Targets.Firmware.Spelling (Unit)
                      & ", so this program passes floats in VFP registers:"
                      & " build the archive with -mfloat-abi=hard -mfpu="
                      & Landin.Targets.Firmware.Spelling (Unit));
            end;
         end Float_Variant_Advice;

         --  Protect both the consumed object and its current public spelling.
         --  Tools have a bounded known-input contract; this does not sandbox
         --  arbitrary wrappers, compiler specs or unreported child inputs.
         procedure Observed_Input
           (Path : String; Identity : Landin.Platform.File_Identity);
         procedure Observed_Input
           (Path : String; Identity : Landin.Platform.File_Identity) is
         begin
            if not Known_Inputs.Contains (Path) then
               Known_Inputs.Append (Path);
            end if;
            Publication.Protect (Artifacts, Path, Identity);
            Publication.Protect (Stage_Report, Path, Identity);
         end Observed_Input;

         procedure Protect_Input (Path : String);
         procedure Protect_Input (Path : String) is
         begin
            if Path /= "" then
               Observed_Input (Path, Host.Identity_Of (Path));
            end if;
         end Protect_Input;

         function Absolute (Path : String) return String;

         --  A stage report may publish even when loading or option checking
         --  fails. Register selected tool names before either can fail, and
         --  retain the current resolution as bounded executable evidence.
         procedure Protect_Tool_Inputs (Driver : String);
         procedure Protect_Tool_Inputs (Driver : String) is
            procedure Protect_Program (Name : String);
            procedure Observe_Program_Path (Path : String);
            procedure Observe_Program_Path (Path : String) is
               Seen : Landin.Platform.Identity_Observation;
            begin
               if Path = "" then
                  return;
               end if;
               Seen := Host.Observe_Identity (Path);
               if Seen.Status = Landin.Platform.Not_Found then
                  if not Absent_Tool_Names.Contains (Path) then
                     Absent_Tool_Names.Append (Path);
                  end if;
                  if Seen.Parent_Resolved then
                     Observed_Input (Path, Seen.Identity);
                  end if;
               else
                  Observed_Input (Path, Seen.Identity);
               end if;
            end Observe_Program_Path;
            procedure Protect_Program (Name : String) is
               Resolved : constant String :=
                 (if Name = "" then "" else Tools.Resolve_Program (Name));
            begin
               --  A bare name is looked for along PATH and nowhere else,
               --  so once PATH has answered, the file of that name in the
               --  working directory is not the tool and reserves nothing.
               --  A name with a directory in it is a path, and a name
               --  nothing answers to is kept as it was spelled.
               if Resolved = ""
                 or else Ada.Strings.Fixed.Index (Name, "/") /= 0
               then
                  Observe_Program_Path (Name);
               end if;
               Observe_Program_Path (Resolved);
            end Protect_Program;
         begin
            Protect_Program (Unbounded.To_String (Toolchain));
            Protect_Program (Driver);
            if Debug_Enabled
              and then Landin.Targets.Capabilities.Backend_For (Facts)
                = Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
              and then Natural (Inputs.Length) = 1
              and then Is_Assembly_Operand (Inputs.First_Element)
            then
               Protect_Program
                 (Landin.Backend.Toolchain.Darwin_Debug_Bundle_Tool);
            end if;
            if Linker_Seen then
               Protect_Program (Unbounded.To_String (Linker));
               if Unbounded.Length (Linker) > 0
                 and then Ada.Strings.Fixed.Index
                   (Unbounded.To_String (Linker), "/") = 0
               then
                  Protect_Program ("ld." & Unbounded.To_String (Linker));
               end if;
            else
               --  A known default candidate, not evidence of whichever
               --  implicit linker an arbitrary driver eventually chooses.
               Protect_Program ("ld");
            end if;
         end Protect_Tool_Inputs;

         --  A definitively absent selection has no object to alias. Keep its
         --  spelling reserved without asking the object-overlap API to resolve
         --  nonexistent parents, which must conservatively answer unknown.
         --  Whether the last True answer was the same spelling, or only a
         --  pair of names the host could not tell apart; the refusal says
         --  which, so it never claims a collision that was not found.
         Tool_Name_Proven : Boolean := True;
         function Names_Tool return String is
           (if Tool_Name_Proven then " names a selected tool"
            else " cannot be proved separate from the name of a selected"
              & " tool");

         function Is_Absent_Tool_Name (Path : String) return Boolean;
         function Is_Absent_Tool_Name (Path : String) return Boolean is
            Output : constant Landin.Platform.Identity_Observation :=
              Host.Observe_Identity (Path);
         begin
            Tool_Name_Proven := True;
            for Name of Absent_Tool_Names loop
               if Path = Name or else Absolute (Path) = Absolute (Name) then
                  return True;
               end if;
               if Output.Identity.Valid or else Output.Parent_Resolved then
                  declare
                     Seen : constant Landin.Platform.Identity_Observation :=
                       Host.Observe_Identity (Name);
                  begin
                     if Seen.Status /= Landin.Platform.Not_Found
                       or else Seen.Parent_Resolved
                     then
                        Observed_Input (Name, Seen.Identity);
                        if Host.Paths_Overlap (Path, Name) then
                           Tool_Name_Proven := Host.Same_File (Path, Name);
                           return True;
                        end if;
                     end if;
                  end;
               end if;
            end loop;
            return False;
         end Is_Absent_Tool_Name;

         --  The host's reason already says what it could not do and what
         --  to do instead, and the native one begins "cannot prepare PATH";
         --  only the kind of output is added, so the path is named once and
         --  the route is the host's.
         function Preparation_Failure
           (Kind, Path : String; Reason : Unbounded.Unbounded_String)
            return String;
         function Preparation_Failure
           (Kind, Path : String; Reason : Unbounded.Unbounded_String)
            return String
         is
            Said : constant String := Unbounded.To_String (Reason);
            Head : constant String := "cannot prepare " & Path & ": ";
         begin
            if Starts_With (Said, Head) then
               return "cannot prepare " & Kind & " " & Path & ": "
                 & Said (Said'First + Head'Length .. Said'Last);
            end if;
            return "cannot prepare " & Kind & " " & Path & ": " & Said;
         end Preparation_Failure;

         --  What a reserved path is called when it cannot be prepared:
         --  the option that named it, so a report's path refused is not
         --  read as the program's.  A path no option named, one derived
         --  from the source's name or written beside the product, is an
         --  output and nothing more.
         function Reservation_Kind (Path : String) return String;
         function Reservation_Kind (Path : String) return String is
         begin
            if Path = "" then
               return "output";
            elsif Path = Unbounded.To_String (Build_Report_Path) then
               return "--build-report output";
            elsif Path = Unbounded.To_String (Stage_Report_Path) then
               return "--stage-report output";
            elsif Path = Unbounded.To_String (Stack_Report_Path) then
               return "--stack-report output";
            elsif Path = Depfile then
               return "--depfile output";
            elsif Output_Seen and then Path = Unbounded.To_String (Output)
            then
               return "-o output";
            end if;
            return "output";
         end Reservation_Kind;

         --  Whether a signal has asked this command to stop, asked where
         --  one stage hands over to the next.  While an output is reserved
         --  or a private directory exists the host records the signal
         --  rather than end the process, and this is what answers it: the
         --  group is abandoned as a refused preparation abandons it.
         function Stop_Requested return Boolean;
         function Stop_Requested return Boolean is
         begin
            if not Cancelled and then Host.Cancellation_Requested then
               Cancelled := True;
               Publication_Failed := True;
            end if;
            return Cancelled;
         end Stop_Requested;

         --  The same question for the frontend's pipeline, which asks it
         --  before each stage.  It only reads the host's record: what the
         --  stop abandons is decided by the caller, after the pipeline.
         function Frontend_Stop return Boolean is
           (Host.Cancellation_Requested);

         --  The one artifact that is a directory tree: a Darwin debug
         --  bundle.  Every other output is a file, and a directory found
         --  where one is to be written is refused when it is reserved.
         function Is_Directory_Artifact (Path : String) return Boolean is
           (Path'Length > 5
            and then Path (Path'Last - 4 .. Path'Last) = ".dSYM");

         procedure Reserve_Output
           (Path : String; Defer_Preparation_Failure : Boolean := False);
         procedure Reserve_Output
           (Path : String; Defer_Preparation_Failure : Boolean := False) is
            Status : Landin.Platform.Write_Status;
            Reason : Unbounded.Unbounded_String;
         begin
            if Dry_Run or else Reserved.Contains (Path)
              or else Publication_Failed
            then
               return;
            end if;
            Protect_Tool_Inputs (Planned_Driver);
            if Is_Absent_Tool_Name (Path) then
               Bad_Use := True;
               Publication_Failed := True;
               Note_Failure
                 (Code_Unknown_Option, "output " & Path
                  & Names_Tool & "; choose another output path"
                  & " and retry");
               return;
            end if;
            for Input of Known_Inputs loop
               if Path = Input
                 or else (Host.Exists (Path)
                          and then Host.Paths_Overlap (Path, Input))
               then
                  Bad_Use := True;
                  Publication_Failed := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     Input_Conflict ("output", Path, Input));
                  return;
               end if;
            end loop;
            Publication.Prepare
              (Artifacts, Host, Path, Status, Reason,
               Directory => Is_Directory_Artifact (Path));
            if Status /= Landin.Platform.Write_Ok
              and then Host.Cancellation_Requested
            then
               Publication_Failed := True;
               Cancelled := True;
            elsif Status /= Landin.Platform.Write_Ok then
               Publication_Failed := True;
               declare
                  Message : constant String :=
                    Preparation_Failure
                      (Reservation_Kind (Path), Path, Reason);
               begin
                  if Defer_Preparation_Failure then
                     Pending_Publication_Failure :=
                       Unbounded.To_Unbounded_String (Message);
                  else
                     Note_Failure (Code_Unwritable, Message);
                  end if;
               end;
            else
               --  Refresh after preparation so newly observable tool parents
               --  get full host name-equivalence protection before staged
               --  writes, even when the public leaf is absent.
               Protect_Tool_Inputs (Planned_Driver);
               if Is_Absent_Tool_Name (Path) then
                  Publication_Failed := True;
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option, "output " & Path
                     & Names_Tool & "; choose another output path"
                     & " and retry");
                  return;
               end if;
               Reserved.Append (Path);
               declare
                  Stage : constant String :=
                    Publication.Stage_Path (Artifacts, Path);
               begin
                  Result.Trace_Physical_Paths.Append (Stage);
                  Result.Trace_Logical_Paths.Append (Path);
                  if Stage'Length > 0 and then Stage (Stage'First) /= '/' then
                     Result.Trace_Physical_Paths.Append
                       (Host.Working_Directory & "/"
                        & (if Starts_With (Stage, "./")
                           then Stage (Stage'First + 2 .. Stage'Last)
                           else Stage));
                     Result.Trace_Logical_Paths.Append (Path);
                  end if;
               end;
            end if;
         end Reserve_Output;

         procedure Report_Publication_Failure;
         procedure Report_Publication_Failure is
         begin
            if Unbounded.Length (Pending_Publication_Failure) > 0 then
               Note_Failure
                 (Code_Unwritable,
                  Unbounded.To_String (Pending_Publication_Failure));
               Unbounded.Set_Unbounded_String
                 (Pending_Publication_Failure, "");
            end if;
         end Report_Publication_Failure;

         function Private_Path (Path : String) return String is
           (Publication.Stage_Path (Artifacts, Path));

         procedure Write_Output
           (Path, Content : String; Status : out Landin.Platform.Write_Status);
         procedure Write_Output
           (Path, Content : String;
            Status : out Landin.Platform.Write_Status) is
         begin
            Pending_Write_Reason := Unbounded.Null_Unbounded_String;
            Reserve_Output (Path);
            if Publication_Failed then
               Status := Landin.Platform.Not_Writable;
            else
               Host.Write_File
                 (Private_Path (Path), Content, Status, Pending_Write_Reason);
            end if;
         end Write_Output;

         function Logical_Text (Text : String) return String;
         function Logical_Text (Text : String) return String is
            Result : Unbounded.Unbounded_String :=
              Unbounded.To_Unbounded_String (Text);

            procedure Replace_Path (Path, Stage : String);
            procedure Replace_Path (Path, Stage : String) is
               At_Position : Natural := 0;
               From : Positive := 1;
            begin
               if Stage = "" or else Stage = Path then
                  return;
               end if;
               loop
                  exit when From > Unbounded.Length (Result);
                  At_Position := Ada.Strings.Fixed.Index
                    (Unbounded.To_String (Result), Stage, From);
                  exit when At_Position = 0;
                  Unbounded.Replace_Slice
                    (Result, At_Position, At_Position + Stage'Length - 1,
                     Path);
                  From := At_Position + Path'Length;
               end loop;
            end Replace_Path;
         begin
            for Path of Reserved loop
               Replace_Path (Path, Private_Path (Path));
            end loop;
            if Stage_Report_Seen then
               declare
                  Path : constant String :=
                    Unbounded.To_String (Stage_Report_Path);
               begin
                  Replace_Path
                    (Path, Publication.Stage_Path (Stage_Report, Path));
               end;
            end if;
            return Unbounded.To_String (Result);
         end Logical_Text;

         function Write_Failure (Path : String) return String is
           ("cannot write: " & Path
            & (if Unbounded.Length (Pending_Write_Reason) = 0 then ""
               else ": " & Logical_Text
                 (Unbounded.To_String (Pending_Write_Reason))));

         procedure Close_Artifacts (Publish : Boolean);
         procedure Close_Artifacts (Publish : Boolean) is
            Status : Landin.Platform.Write_Status;
            Reason : Unbounded.Unbounded_String;
         begin
            if Artifacts_Closed and then Publish then
               return;
            end if;
            if Publish and then not Publication_Failed then
               Protect_Tool_Inputs (Planned_Driver);
               for Path of Reserved loop
                  if Is_Absent_Tool_Name (Path) then
                     Publication_Failed := True;
                     Bad_Use := True;
                     Note_Failure
                       (Code_Unknown_Option, "output " & Path
                        & Names_Tool & "; choose another output path"
                        & " and retry");
                  end if;
                  for Input of Known_Inputs loop
                     if Path = Input
                       or else (Host.Exists (Path)
                                and then Host.Paths_Overlap (Path, Input))
                     then
                        Publication_Failed := True;
                        Bad_Use := True;
                        Note_Failure
                          (Code_Unknown_Option,
                           Input_Conflict ("output", Path, Input));
                     end if;
                  end loop;
               end loop;
            end if;
            if Publish and then not Publication_Failed then
               Publication.Commit (Artifacts, Host, Status, Reason);
               if Status /= Landin.Platform.Write_Ok then
                  Publication_Failed := True;
                  Cancelled := Host.Cancellation_Requested;
                  if not Cancelled then
                     Note_Failure
                       (Code_Unwritable, "cannot publish artifact generation: "
                        & Unbounded.To_String (Reason));
                  end if;
               end if;
            end if;
            --  A cleanup refusal here is reported once, by
            --  Finish_Publications, from the state the group ends in.
            if not Publish or else Publication_Failed then
               Publication.Abort_Transaction (Artifacts, Host, Status, Reason);
            end if;
            Artifacts_Closed := True;
         end Close_Artifacts;

         --  After a cleanup refusal, say which state publication
         --  ended in, from what the group recorded rather than from the
         --  host's wording: published with the replaced copy retained, put
         --  back with only private files retained, or a rollback that did
         --  not finish.  Only an image that was written and read back is
         --  said to have been, and the recovery entries are the ones the
         --  host's reason names, which are the ones it holds.
         function Cleanup_Summary
           (Group : Publication.Transaction; Subject : String;
            Image : String := "")
            return String;
         function Cleanup_Summary
           (Group : Publication.Transaction; Subject : String;
            Image : String := "")
            return String
         is
            Reason : constant String := Publication.Cleanup_Reason (Group);
         begin
            case Publication.State (Group) is
               when Publication.Clean =>
                  return "";
               when Publication.Published_Prior_Retained =>
                  return Subject & " is published"
                    & (if Image = "" then ""
                       else ", and its image " & Image
                            & " was written and read back")
                    & ", but cleaning up after it failed: " & Reason
                    & "; the published outputs are complete, and what the"
                    & " recovery directory holds may be inspected and"
                    & " removed";
               when Publication.Restored_Stage_Retained =>
                  return Subject & " was not published, and every output"
                    & " it would have replaced is as it was before; cleaning"
                    & " up its private files failed: " & Reason
                    & "; they may be removed";
               when Publication.Rollback_Incomplete =>
                  return "rollback of " & Subject & " is incomplete, so an"
                    & " output named here may hold the new or the previous"
                    & " version: " & Reason & "; put back what the recovery"
                    & " directory holds before building again";
            end case;
         end Cleanup_Summary;

         procedure Note_Cleanup
           (Group : Publication.Transaction; Subject : String;
            Status : Landin.Platform.Write_Status;
            Reason : Unbounded.Unbounded_String;
            Noted : in out Boolean;
            Image : String := "");
         procedure Note_Cleanup
           (Group : Publication.Transaction; Subject : String;
            Status : Landin.Platform.Write_Status;
            Reason : Unbounded.Unbounded_String;
            Noted : in out Boolean;
            Image : String := "")
         is
            Summary : constant String :=
              Cleanup_Summary (Group, Subject, Image);
         begin
            if Noted then
               return;
            elsif Summary /= "" then
               Noted := True;
               Note_Failure (Code_Unwritable, Summary);
            elsif Status /= Landin.Platform.Write_Ok then
               Noted := True;
               Note_Failure
                 (Code_Unwritable, "cleaning up " & Subject & " failed: "
                  & Unbounded.To_String (Reason));
            end if;
         end Note_Cleanup;

         procedure Finish_Publications;
         procedure Finish_Publications is
            Status : Landin.Platform.Write_Status;
            Reason : Unbounded.Unbounded_String;
         begin
            Publication.Finish (Artifacts, Host, Status, Reason);
            Note_Cleanup
              (Artifacts,
               (if Emit = Emit_Nothing then "this build"
                else "this build of " & Artifact_Output),
               Status, Reason, Artifacts_Cleanup_Noted,
               Unbounded.To_String (ESP_Image_Path));
            Publication.Finish (Stage_Report, Host, Status, Reason);
            Note_Cleanup
              (Stage_Report,
               "the stage report " & Unbounded.To_String (Stage_Report_Path),
               Status, Reason, Stage_Report_Cleanup_Noted);
         end Finish_Publications;

         procedure Check_Dependency_Path (Path : String);
         procedure Check_Make_Path
           (Path : String; Target : Boolean := False);

         procedure Check_Dependency_Path (Path : String) is
         begin
            if Depfile /= ""
              and then (for some Byte of Path => Byte in ASCII.LF | ASCII.CR)
            then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option,
                  "dependency paths cannot contain line breaks");
            end if;
         end Check_Dependency_Path;

         --  D1058: a path the depfile would write, held to what Make can
         --  read back as that one name.  `$`, blank, TAB, `#` and `:`
         --  have a spelling in a prerequisite and are written in it;
         --  these have none, or none every GNU make shares: `;` begins a
         --  recipe, `|` the order-only prerequisites, `=` an assignment,
         --  `&` a grouped target, `%` a pattern, `*`, `?` and `[` a
         --  wildcard and a leading `~` a home directory, and a backslash
         --  quotes or does not by what follows it.  A target has no
         --  spelling for `#` or `:` either.
         procedure Check_Make_Path (Path : String; Target : Boolean := False)
         is
            function Refused return String;

            function Refused return String is
            begin
               if Path'Length > 0 and then Path (Path'First) = '~' then
                  return "~";
               end if;
               for Byte of Path loop
                  if Byte in ';' | '|' | '=' | '&' | '%' | '*' | '?' | '['
                    | '\'
                    or else (Target and then Byte in '#' | ':')
                  then
                     return "" & Byte;
                  end if;
               end loop;
               return "";
            end Refused;
         begin
            if Depfile /= "" and then not Bad_Use and then Refused /= "" then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option,
                  "a Make depfile cannot carry `" & Refused & "` in "
                  & (if Target then "its target" else "a dependency")
                  & ": " & Path & "; rename it, or build without --depfile");
            end if;
         end Check_Make_Path;

         --  D524: a path as the link names it, absolute.  A relative one is
         --  read against the working directory the host reports.
         function Absolute (Path : String) return String is
            Last : Natural := Path'Last;
         begin
            while Last > Path'First and then Path (Last) = '/' loop
               Last := Last - 1;
            end loop;
            declare
               Trimmed : constant String := Path (Path'First .. Last);
            begin
               if Trimmed'Length > 0 and then Trimmed (Trimmed'First) = '/'
               then
                  return Trimmed;
               elsif Trimmed = "." or else Trimmed = "" then
                  return Host.Working_Directory;
               elsif Starts_With (Trimmed, "./") then
                  --  `.//x` is `./x` to the host, which checked it as
                  --  that: the slashes after `./` go with it, or the
                  --  rest would read as the absolute `/x`.
                  declare
                     First : Positive := Trimmed'First + 2;
                  begin
                     while First <= Trimmed'Last
                       and then Trimmed (First) = '/'
                     loop
                        First := First + 1;
                     end loop;
                     return Absolute (Trimmed (First .. Trimmed'Last));
                  end;
               end if;
               return Host.Working_Directory & "/" & Trimmed;
            end;
         end Absolute;

         --  D524: the directory a `linker.directory` names, as a report
         --  names it: a relative one joined to the declaring file's
         --  directory as that file was named.
         function Directive_Named (Index : Positive) return String;

         function Directive_Named (Index : Positive) return String is
            Table : Landin.Configuration.Table renames
              Landin.Stages.Configurations (Context).all;
            Written : constant String :=
              Landin.Configuration.Directory_Written (Table, Index);
            Declaring : constant String :=
              Landin.Source.Name
                (Landin.Stages.Source
                   (Context,
                    Landin.Configuration.Directory_Source (Table, Index)));
            Slash : Natural := 0;
         begin
            if Written (Written'First) = '/' then
               return Written;
            end if;
            for Position in Declaring'Range loop
               if Declaring (Position) = '/' then
                  Slash := Position;
               end if;
            end loop;
            if Written = "." then
               return (if Slash = 0 then "."
                       else Declaring (Declaring'First .. Slash - 1));
            end if;
            return (if Slash = 0 then ""
                    else Declaring (Declaring'First .. Slash))
              & Written;
         end Directive_Named;

         --  The same, absolute, as the link is given it.
         function Directive_Directory (Index : Positive) return String
           is (Absolute (Directive_Named (Index)));

         --  D524's order: the command line's directories first, so whoever
         --  builds can put another copy ahead, then the directives'.
         function Search_Directories return Landin.Platform.Path_List;

         function Search_Directories return Landin.Platform.Path_List is
            List : Landin.Platform.Path_List;
         begin
            for Directory of Search_Options loop
               List.Append (Absolute (Directory));
            end loop;
            for Index in 1 .. Landin.Configuration.Directory_Count
              (Landin.Stages.Configurations (Context).all)
            loop
               List.Append (Directive_Directory (Index));
            end loop;
            return List;
         end Search_Directories;

         --  D524: a `linker.directory` naming no directory is refused at
         --  the directive, before any tool runs, by a check as well.
         procedure Check_Directories;

         procedure Check_Directories is
            Table : Landin.Configuration.Table renames
              Landin.Stages.Configurations (Context).all;
         begin
            for Index in 1 .. Landin.Configuration.Directory_Count (Table)
            loop
               declare
                  Named : constant String := Directive_Directory (Index);
                  Item : Landin.Diagnostics.Diagnostic;
               begin
                  if not Host.Is_Directory (Named) then
                     Item := Landin.Diagnostics.Make
                       (Code    => Rows.Code (Rows.Invalid_Tool_Directive),
                        Level   => Landin.Diagnostics.Error,
                        Source  =>
                          Landin.Configuration.Directory_Source (Table, Index),
                        Where   =>
                          Landin.Configuration.Directory_Where (Table, Index),
                        Message => "linker.directory names no directory: "
                          & Directive_Named (Index));
                     Landin.Diagnostics.Add_Note
                       (Item,
                        "[1590]/D524: a relative directory is read against"
                        & " the directory of the file that declares it;"
                        & " name a directory that exists");
                     Landin.Stages.Report (Context, Item);
                  end if;
               end;
            end loop;
         end Check_Directories;

         --  `--stage-report`: one row per stage, each the processor time
         --  spent in it and the process's peak resident set when it ended.
         --  The peak is a high-water mark, so the stage that raised it is
         --  the one whose row first shows the new value.  Loading scans and
         --  parses each batch of modules it reads, to find their imports;
         --  that time is the syntax stage's, so it is taken out of the
         --  loading row and counted in the syntax row instead.
         Stage_Rows : Unbounded.Unbounded_String;
         Parse_Start : Landin.Platform.Resource_Sample;
         Parse_Microseconds : Long_Long_Integer := 0;
         --  The stage running now, for a defect to say where it arose.
         Current_Stage : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String ("the driver");
         Stage_Start : Landin.Platform.Resource_Sample;

         procedure Stage_Began;
         procedure Stage_Ended (Name : String);
         procedure Watch_Parsing (Finished : Boolean);
         procedure Watch_Stage (Name : String; Finished : Boolean);
         procedure Write_Stage_Report;

         procedure Stage_Began is
         begin
            if Stage_Report_Seen then
               Stage_Start := Meter.Sample;
            end if;
         end Stage_Began;

         procedure Stage_Ended (Name : String) is
            function Image (Value : Long_Long_Integer) return String is
              (Ada.Strings.Fixed.Trim
                 (Long_Long_Integer'Image (Value), Ada.Strings.Both));
            Now : Landin.Platform.Resource_Sample;
            Spent : Long_Long_Integer;
         begin
            if not Stage_Report_Seen or else Dry_Run then
               return;
            end if;
            Now := Meter.Sample;
            Spent := Now.Processor_Microseconds
              - Stage_Start.Processor_Microseconds;
            if Name = "loading" then
               Spent := Long_Long_Integer'Max (0, Spent - Parse_Microseconds);
            elsif Name = "syntax" then
               Spent := Spent + Parse_Microseconds;
               Parse_Microseconds := 0;
            end if;
            if Unbounded.Length (Stage_Rows) > 0 then
               Unbounded.Append (Stage_Rows, "," & LF);
            end if;
            Unbounded.Append
              (Stage_Rows,
               "    {""stage"":""" & Name & """,""processor_us"":"
               & Image (Spent)
               & ",""peak_kib"":" & Image (Now.Peak_Resident_KiB) & "}");
         end Stage_Ended;

         procedure Watch_Parsing (Finished : Boolean) is
            Now : Landin.Platform.Resource_Sample;
         begin
            if not Stage_Report_Seen or else Dry_Run then
               return;
            end if;
            Now := Meter.Sample;
            if Finished then
               Parse_Microseconds := Parse_Microseconds
                 + (Now.Processor_Microseconds
                    - Parse_Start.Processor_Microseconds);
            else
               Parse_Start := Now;
            end if;
         end Watch_Parsing;

         procedure Watch_Stage (Name : String; Finished : Boolean) is
         begin
            if Finished then
               Stage_Ended (Name);
               Current_Stage := Unbounded.To_Unbounded_String ("the driver");
            else
               Current_Stage := Unbounded.To_Unbounded_String
                 ("the " & Name & " stage");
               Stage_Began;
            end if;
         end Watch_Stage;

         --  Written whenever a well-formed request reaches a stage, a
         --  refused program included: where a refusal's time and storage
         --  went is exactly what a bound is measured by.  An early target
         --  refusal can also write an empty report once source paths are
         --  known to be safe.  The sizes are the compilation's own counts
         --  and are the same on every run; the rows are not.
         procedure Write_Stage_Report is
            Path : constant String := Unbounded.To_String (Stage_Report_Path);
            Written : Landin.Platform.Write_Status;
            Reason : Unbounded.Unbounded_String;
            Nodes : Natural := 0;
            function Image (Value : Natural) return String is
              (Ada.Strings.Fixed.Trim
                 (Natural'Image (Value), Ada.Strings.Both));
         begin
            if not Stage_Report_Seen or else Bad_Use
              or else Skip_Compilation or else Dry_Run or else Policy_Denied
            then
               return;
            end if;
            Protect_Tool_Inputs (Planned_Driver);
            if Is_Absent_Tool_Name (Path) then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option, "stage report output " & Path
                  & Names_Tool & "; choose another output path"
                  & " and retry");
               return;
            end if;
            --  A failed read has no source in Context, but its requested
            --  path must still be protected from the report writer.
            for Input of Inputs loop
               if Host.Paths_Overlap (Path, Input) then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     Source_Conflict ("stage report", Path, Inputs));
                  return;
               end if;
            end loop;
            for Index in 1 .. Landin.Stages.Source_Count (Context) loop
               if Host.Paths_Overlap
                 (Path, Landin.Source.Name
                    (Landin.Stages.Source
                       (Context, Landin.Stages.Nth_Source (Context, Index))))
               then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     Source_Conflict
                       ("stage report", Path,
                        [Landin.Source.Name
                           (Landin.Stages.Source
                              (Context,
                               Landin.Stages.Nth_Source (Context, Index)))]));
                  return;
               end if;
            end loop;
            declare
               Forest : constant not null access Landin.Syntax.Forest.Table :=
                 Landin.Stages.Trees (Context);
            begin
               for Index in 1 .. Landin.Syntax.Forest.Count (Forest.all) loop
                  declare
                     Id : constant Landin.Source.Source_Id :=
                       Landin.Stages.Nth_Source (Context, Index);
                  begin
                     Nodes := Nodes + Landin.Syntax.Node_Count
                       (Landin.Syntax.Forest.Tree_Of (Forest.all, Id).all);
                  end;
               end loop;
            end;
            for Input of Known_Inputs loop
               if Path = Input
                 or else (Host.Exists (Path)
                          and then Host.Paths_Overlap (Path, Input))
               then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     Input_Conflict ("stage report output", Path, Input));
                  return;
               end if;
            end loop;
            Publication.Prepare
              (Stage_Report, Host, Path, Written, Reason);
            if Written /= Landin.Platform.Write_Ok then
               Cancelled := Cancelled or else Host.Cancellation_Requested;
               if not Cancelled then
                  Note_Failure
                    (Code_Unwritable,
                     Preparation_Failure
                       (Reservation_Kind (Path), Path, Reason));
               end if;
               return;
            end if;
            Protect_Tool_Inputs (Planned_Driver);
            if Is_Absent_Tool_Name (Path) then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option, "stage report output " & Path
                  & Names_Tool & "; choose another output path"
                  & " and retry");
               return;
            end if;
            Host.Write_File
              (Publication.Stage_Path (Stage_Report, Path),
               "{""format"":""landin-stage-report-1"",""stages"":[" & LF
               & Unbounded.To_String (Stage_Rows) & LF
               & "  ],""sizes"":{""sources"":"
               & Image (Landin.Stages.Source_Count (Context))
               & ",""nodes"":" & Image (Nodes)
               & ",""declarations"":" & Image
                 (Landin.Resolution.Declaration_Count
                    (Landin.Stages.Meanings (Context).all))
               & ",""ir_items"":" & Image
                 (Landin.IR.Item_Count (Landin.Stages.Code (Context).all))
               & "}}" & LF,
               Written, Reason);
            if Written /= Landin.Platform.Write_Ok then
               Note_Failure
                 (Code_Unwritable, "cannot write: " & Path
                  & (if Unbounded.Length (Reason) = 0 then ""
                     else ": " & Logical_Text (Unbounded.To_String (Reason))));
            end if;
            if Written = Landin.Platform.Write_Ok then
               Protect_Tool_Inputs (Planned_Driver);
               if Is_Absent_Tool_Name (Path) then
                  Bad_Use := True;
                  Written := Landin.Platform.Not_Writable;
                  Reason := Unbounded.To_Unbounded_String
                    ("stage report" & Names_Tool
                     & "; choose another output path and retry");
               else
                  Publication.Commit (Stage_Report, Host, Written, Reason);
               end if;
            end if;
            if Written /= Landin.Platform.Write_Ok then
               Cancelled := Cancelled or else Host.Cancellation_Requested;
               if not Cancelled then
                  Note_Failure
                    (Code_Unwritable, "cannot publish stage report " & Path
                     & ": " & Unbounded.To_String (Reason));
               end if;
               Publication.Abort_Transaction
                 (Stage_Report, Host, Written, Reason);
            end if;
            --  Finish_Publications reports where its cleanup ended.
            Publication.Finish (Stage_Report, Host, Written, Reason);
         end Write_Stage_Report;

         --  A `public main` in the entry module of a hosted program that
         --  is not [1970]'s entry: refused when the program is checked or
         --  emitted as assembly, as it is before a link, rather than left
         --  for the linker to miss `main` (D443).  A C-convention `main` is
         --  [1650]'s own form and is not asked about.
         function Public_Main_Not_Entry return Boolean;

         function Public_Main_Not_Entry return Boolean is
            package Res renames Landin.Resolution;
            Grouped : Landin.Modules.Table renames
              Landin.Stages.Modules (Context).all;
            Meanings : Res.Table renames
              Landin.Stages.Meanings (Context).all;
         begin
            if Landin.Targets.Capabilities.Hosted_System_Of (Facts)
                 = Landin.Targets.Capabilities.No_Hosted_System
              or else Landin.Backend.Entry_Point.Hosted_Main
                (Landin.Stages.Code (Context).all, Meanings, Grouped,
                 Landin.Stages.Identities (Context).all)
                  /= Landin.IR.No_Item
            then
               return False;
            end if;
            for Index in 1 .. Res.Declaration_Count (Meanings) loop
               declare
                  Id : constant Res.Declaration_Id :=
                    Res.Declaration_Id (Index);
                  From : constant Landin.Source.Source_Id :=
                    Res.Source_Of (Meanings, Id);
                  Node : constant Landin.Syntax.Node_Id :=
                    Res.Node_Of (Meanings, Id);
               begin
                  if Res."=" (Res.Sort_Of (Meanings, Id), Res.Module_Function)
                    and then Res.Is_Public (Meanings, Id)
                    and then Natural (From)
                      <= Landin.Modules.Source_Count (Grouped)
                    and then Landin.Modules.Module_Of (Grouped, From)
                      = Landin.Modules.Entry_Module
                    and then Landin.Source.Names.Spelling
                      (Landin.Stages.Identities (Context).all,
                       Res.Name_Of (Meanings, Id)) = "main"
                    and then Landin.Configuration.Is_Active
                      (Landin.Stages.Configurations (Context).all, From, Node)
                    and then not Landin.Syntax.Uses_C_ABI
                      (Landin.Syntax.Forest.Tree_Of
                         (Landin.Stages.Trees (Context).all, From).all,
                       Node)
                  then
                     return True;
                  end if;
               end;
            end loop;
            return False;
         end Public_Main_Not_Entry;

         procedure Note_No_Entry (For_Firmware : Boolean := False);

         procedure Note_No_Entry (For_Firmware : Boolean := False) is
            package Res renames Landin.Resolution;
            use type Res.Declaration_Id;
            use type Res.Declaration_Sort;
            Selected : constant String :=
              (if For_Firmware then Unbounded.To_String (Firmware_Name)
               else "main");
            Grouped : Landin.Modules.Table renames
              Landin.Stages.Modules (Context).all;
            Meanings : Res.Table renames
              Landin.Stages.Meanings (Context).all;
            Source : Landin.Source.Source_Id := Landin.Source.No_Source;
            Where : Landin.Source.Span := Landin.Source.Empty_Span;
            Candidate : Unbounded.Unbounded_String;
            Candidate_Count : Natural := 0;
         begin
            if For_Firmware and then Selected = "" then
               for Index in 1 .. Landin.IR.Item_Count
                 (Landin.Stages.Code (Context).all)
               loop
                  declare
                     Item : constant Landin.IR.Item_Id :=
                       Landin.IR.Item_Id (Index);
                     Id : constant Res.Declaration_Id := Landin.IR.Declares
                       (Landin.Stages.Code (Context).all, Item);
                  begin
                     if Id /= Res.No_Declaration
                       and then Res.Sort_Of (Meanings, Id)
                         = Res.Module_Function
                       and then Landin.Modules.Module_Of
                         (Grouped, Res.Source_Of (Meanings, Id))
                           = Landin.Modules.Entry_Module
                     then
                        declare
                           Name : constant String :=
                             Landin.Source.Names.Spelling
                             (Landin.Stages.Identities (Context).all,
                              Res.Name_Of (Meanings, Id));
                        begin
                           if Landin.Backend.Entry_Point.Firmware_Start
                             (Landin.Stages.Code (Context).all, Meanings,
                              Grouped, Landin.Stages.Identities (Context).all,
                              Name) = Item
                           then
                              Candidate :=
                                Unbounded.To_Unbounded_String (Name);
                              Candidate_Count := Candidate_Count + 1;
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end if;
            --  With no candidate, point at the start of the first entry
            --  source, including an empty file where main could be added.
            for Index in 1 .. Landin.Modules.Source_Count (Grouped) loop
               if Landin.Modules.Module_Of
                 (Grouped, Landin.Source.Source_Id (Index))
                 = Landin.Modules.Entry_Module
               then
                  Source := Landin.Source.Source_Id (Index);
                  exit;
               end if;
            end loop;
            --  A wrong-shaped, private or renamed main is more useful than
            --  that insertion point. Imported and local names are not entry
            --  candidates; inactive declarations cannot supply the anchor.
            for Index in 1 .. Res.Declaration_Count (Meanings) loop
               declare
                  Id : constant Res.Declaration_Id :=
                    Res.Declaration_Id (Index);
                  From : constant Landin.Source.Source_Id :=
                    Res.Source_Of (Meanings, Id);
                  Node : constant Landin.Syntax.Node_Id :=
                    Res.Node_Of (Meanings, Id);
               begin
                  if Res.Sort_Of (Meanings, Id) in
                    Res.Module_Function .. Res.Module_Binding
                    and then Natural (From)
                      <= Landin.Modules.Source_Count (Grouped)
                    and then Landin.Modules.Module_Of (Grouped, From)
                      = Landin.Modules.Entry_Module
                    and then Landin.Source.Names.Spelling
                      (Landin.Stages.Identities (Context).all,
                       Res.Name_Of (Meanings, Id)) = Selected
                    and then Landin.Configuration.Is_Active
                      (Landin.Stages.Configurations (Context).all, From, Node)
                  then
                     Source := From;
                     Where := Landin.Syntax.Anchor
                       (Landin.Syntax.Forest.Tree_Of
                          (Landin.Stages.Trees (Context).all, From).all, Node);
                     exit;
                  end if;
               end;
            end loop;
            Landin.Stages.Report
              (Context, Landin.Diagnostics.Make
                 (Code_No_Entry, Landin.Diagnostics.Error, Source, Where,
                  (if For_Firmware then
                     "firmware requires --firmware-entry="
                     & (if Selected = "" then "NAME" else Selected)
                     & " naming a nongeneric entry-module definition"
                     & " () -> none or noreturn with an empty error set"
                     & (if Candidate_Count = 1
                        then "; add --firmware-entry="
                          & Unbounded.To_String (Candidate)
                        else "")
                   else "a hosted program needs "
                     & Landin.Backend.Entry_Point.Required_Shape)));
         end Note_No_Entry;

         --  L0500 owes a note, because it is the one diagnostic here a
         --  reader is stuck on rather than informed by.
         procedure Note_No_Toolchain (Text : String; Advice : String);

         procedure Note_No_Toolchain (Text : String; Advice : String) is
            Item : Landin.Diagnostics.Diagnostic :=
              Landin.Diagnostics.Make
                (Code    => Code_No_Toolchain,
                 Level   => Landin.Diagnostics.Error,
                 Source  => Landin.Source.No_Source,
                 Where   => Landin.Source.Empty_Span,
                 Message => Text);
         begin
            Landin.Diagnostics.Add_Note (Item, Advice);
            Landin.Stages.Report (Context, Item);
         end Note_No_Toolchain;

         --  D280's refusals of a static Linux link, before any tool runs:
         --  no platform/linux to start at, a C library asked for, or a C
         --  symbol nothing defines.  An executable, and a check that asks
         --  what one would refuse, are held to the last two; assembly and
         --  IR need platform/linux.  A check loads no platform/linux, which
         --  defines no C symbol a program could import, so it asks only
         --  the last two.  True when one was reported.
         function Refused_Static_Link
           (Executable : Boolean; Checking : Boolean := False)
            return Boolean;

         --  D518: whether a FreeBSD program starts a thread through the C
         --  library, whose `pthread_create` is libthr's, which the link
         --  then names: a program that starts none links libc alone.
         function Starts_C_Threads return Boolean;

         function Starts_C_Threads return Boolean is
            Needed : Landin.Platform.Path_List;
            Referrers : Landin.Platform.Path_List;
         begin
            if Landin.Targets.Capabilities.Hosted_System_Of (Facts)
              /= Landin.Targets.Capabilities.FreeBSD
            then
               return False;
            end if;
            Landin.Backend.Entry_Point.Unsatisfied_Imports
              (Landin.Stages.Code (Context).all,
               Landin.Stages.Meanings (Context).all,
               Landin.Stages.Modules (Context).all,
               Landin.Stages.Identities (Context).all,
               Needed, Referrers);
            return (for some Name of Needed => Name = "pthread_create");
         end Starts_C_Threads;

         function Refused_Static_Link
           (Executable : Boolean; Checking : Boolean := False)
            return Boolean
         is
            Needed : Landin.Platform.Path_List;
            Referrers : Landin.Platform.Path_List;
            Requests : constant Natural :=
              Landin.Configuration.Library_Count
                (Landin.Stages.Configurations (Context).all);
         begin
            if not Checking
              and then not Landin.Modules.Supplies
                (Landin.Stages.Modules (Context).all, "platform/linux")
            then
               Note_No_Toolchain
                 ("a static link of " & Landin.Targets.Name (Facts)
                  & " starts at platform/linux's `_landin_start`, and"
                  & " no library holding platform/linux was found",
                  "name the directory holding core, hosted and platform"
                  & " with --library=DIR, or link with --link=libc, which"
                  & " keeps C's runtime");
               return True;
            elsif not Executable then
               return False;
            elsif Requests > 0 then
               Note_No_Toolchain
                 ("a static link of " & Landin.Targets.Name (Facts)
                  & " cannot link the C library `"
                  & Landin.Configuration.Library_Name
                      (Landin.Stages.Configurations (Context).all, 1)
                  & "` the program asks for with linker.library",
                  "link with --link=libc, which keeps C's runtime"
                  & " and library");
               return True;
            elsif Landin.Configuration.Directory_Count
                (Landin.Stages.Configurations (Context).all) > 0
              or else not Search_Options.Is_Empty
            then
               --  D524: where libraries are is a question only a link
               --  with the C library asks.
               Note_No_Toolchain
                 ("a static link of " & Landin.Targets.Name (Facts)
                  & " links no C library, so it searches no directory: "
                  & (if Search_Options.Is_Empty
                     then "linker.directory(" & '"'
                       & Landin.Configuration.Directory_Written
                           (Landin.Stages.Configurations (Context).all, 1)
                       & '"' & ")"
                     else "-L " & Search_Options.First_Element),
                  "link with --link=libc, which keeps C's runtime"
                  & " and library");
               return True;
            end if;
            Landin.Backend.Entry_Point.Unsatisfied_Imports
              (Landin.Stages.Code (Context).all,
               Landin.Stages.Meanings (Context).all,
               Landin.Stages.Modules (Context).all,
               Landin.Stages.Identities (Context).all,
               Needed, Referrers);
            if Needed.Is_Empty then
               return False;
            end if;
            --  Each name with what in the program refers to it, so a
            --  library routine that needs the C library, as platform/posix's
            --  loader does, is named by its own name and not only by the C
            --  symbol it calls.
            declare
               Listed : Unbounded.Unbounded_String;
            begin
               for Index in 1 .. Natural (Needed.Length) loop
                  Unbounded.Append
                    (Listed,
                     (if Index = 1 then ""
                      elsif Index = Natural (Needed.Length)
                      then ", or "
                      else ", ")
                     & "`" & Needed (Index) & "`, which "
                     & (if Referrers (Index) = "" then "the program"
                        else Referrers (Index))
                     & " refers to");
               end loop;
               Note_No_Toolchain
                 ("a static link of " & Landin.Targets.Name (Facts)
                  & " has no C library to define "
                  & Unbounded.To_String (Listed),
                  "link with --link=libc, which keeps C's runtime"
                  & " and library");
            end;
            return True;
         end Refused_Static_Link;


         procedure Note_Unavailable_Toolchain (Driver : String);

         --  D364: the names looked for, in the order they are tried, as
         --  the message says, and what to install.  A named
         --  driver is the only one looked for, so it is the one named.
         procedure Note_Unavailable_Toolchain (Driver : String) is
            Looked : Unbounded.Unbounded_String;
         begin
            for Index in 1 .. Natural (Candidates.Length) loop
               Unbounded.Append
                 (Looked,
                  (if Index = 1 then ""
                   elsif Index = Natural (Candidates.Length) then " and "
                   else ", ")
                  & Candidates (Index));
            end loop;
            Note_No_Toolchain
              ((if Natural (Candidates.Length) <= 1
                then "cannot run " & Driver & " for target "
                  & Landin.Targets.Name (Facts)
                else "no compiler driver to link "
                  & Landin.Targets.Name (Facts)
                  & " was found; looked, in this order, for "
                  & Unbounded.To_String (Looked)),
               Landin.Backend.Toolchain.Install_Advice
                 (Facts, Unbounded.To_String (Toolchain), Native_Target));
         end Note_Unavailable_Toolchain;

         procedure Note_Unavailable_Debug_Bundle;
         procedure Note_Unavailable_Debug_Bundle is
         begin
            Note_No_Toolchain
              ("cannot run "
               & Landin.Backend.Toolchain.Darwin_Debug_Bundle_Tool
               & " to package Darwin debug information",
               (if Native_Target
                then "install Apple's command line tools with"
                else "run this debug build on macOS and install Apple's"
                  & " command line tools with")
               & " `xcode-select --install`, or use --debug=none");
         end Note_Unavailable_Debug_Bundle;

         --  D525's report: the library at its directive, the files looked
         --  for, every named directory with where it was named, and that
         --  the driver's own directories were searched as well.
         procedure Note_Missing_Library
           (Index : Positive;
            Files, Directories : Landin.Platform.Path_List);

         procedure Note_Missing_Library
           (Index : Positive;
            Files, Directories : Landin.Platform.Path_List)
         is
            Table : Landin.Configuration.Table renames
              Landin.Stages.Configurations (Context).all;
            Name : constant String :=
              Landin.Configuration.Library_Name (Table, Index);
            Looked_For : Unbounded.Unbounded_String;
            Places : Unbounded.Unbounded_String;
            Item : Landin.Diagnostics.Diagnostic;
            Options : constant Natural := Natural (Search_Options.Length);
         begin
            for Position in 1 .. Natural (Files.Length) loop
               Unbounded.Append
                 (Looked_For,
                  (if Position = 1 then ""
                   elsif Position = Natural (Files.Length) then " or "
                   else ", ")
                  & Files (Position));
            end loop;
            for Position in 1 .. Natural (Directories.Length) loop
               if Position <= Options then
                  Unbounded.Append
                    (Places, Search_Options (Position) & " (-L), ");
               else
                  declare
                     Directive : constant Positive := Position - Options;
                     Declaring : constant Landin.Source.Snapshot_Reference :=
                       Landin.Stages.Source
                         (Context,
                          Landin.Configuration.Directory_Source
                            (Table, Directive));
                  begin
                     Unbounded.Append
                       (Places, Directive_Named (Directive)
                        & " (linker.directory at "
                        & Landin.Source.Name (Declaring) & ":"
                        & Ada.Strings.Fixed.Trim
                            (Landin.Source.Line_Number'Image
                               (Landin.Source.Position_Of
                                  (Declaring,
                                   Landin.Configuration.Directory_Where
                                     (Table, Directive).First).Line),
                             Ada.Strings.Both)
                        & "), ");
                  end;
               end if;
            end loop;
            Item := Landin.Diagnostics.Make
              (Code    => Code_Library_Not_Found,
               Level   => Landin.Diagnostics.Error,
               Source  => Landin.Configuration.Library_Source (Table, Index),
               Where   => Landin.Configuration.Library_Where (Table, Index),
               Message => "the link found no library `" & Name & "`: no "
                 & Unbounded.To_String (Looked_For) & " in "
                 & Unbounded.To_String (Places)
                 & (if Directories.Is_Empty then ""
                    else "or ")
                 & "the C driver's own directories");
            Landin.Diagnostics.Add_Note
              (Item,
               "[1590]/D525: name the directory that holds it with"
               & " linker.directory(""DIR"") beside the source, or with"
               & " -L DIR when building");
            Landin.Stages.Report (Context, Item);
         end Note_Missing_Library;

         --  D525: after a failed link, each library asked for that no named
         --  directory and none of the driver's own holds, as L0509 at its
         --  directive instead of the linker's text.  True when one was
         --  reported.  A library the search cannot settle, because the
         --  driver could not answer, counts as found: the linker's own
         --  text is then the better report.
         function Libraries_Missing
           (Driver : String; Directories : Landin.Platform.Path_List)
            return Boolean;

         function Libraries_Missing
           (Driver : String; Directories : Landin.Platform.Path_List)
            return Boolean
         is
            Table : Landin.Configuration.Table renames
              Landin.Stages.Configurations (Context).all;
            Reported : Landin.Platform.Path_List;
            Any : Boolean := False;

            function Driver_Holds (File : String) return Boolean;

            function Driver_Holds (File : String) return Boolean is
               Asked : Landin.Platform.Tool_Result;
            begin
               Tools.Run
                 (Driver, Landin.Backend.Toolchain.Print_File_Arguments (File),
                  Asked, Landin.Platform.Output_Only);
               if Asked.Ended /= Landin.Platform.Exited
                 or else Asked.Exit_Code /= 0
               then
                  return True;
               end if;
               declare
                  Path : constant String :=
                    Unbounded.To_String (Asked.Output);
                  Last : Natural := Path'Last;
               begin
                  while Last >= Path'First
                    and then Path (Last) in ASCII.LF | ASCII.CR | ' '
                  loop
                     Last := Last - 1;
                  end loop;
                  --  The driver echoes the name alone when it has none.
                  return Path (Path'First .. Last) /= File
                    and then Last >= Path'First
                    and then Host.Exists (Path (Path'First .. Last))
                    and then not Host.Is_Directory
                      (Path (Path'First .. Last));
               end;
            exception
               when Landin.External_Tool_Failed =>
                  return True;
            end Driver_Holds;

            --  Apple's driver answers `-print-file-name` from its own
            --  directories and not from the SDK it links against, where
            --  `libm.tbd` and the system's other stubs are, so on Darwin
            --  the SDK's `usr/lib` is asked of `xcrun` once, which honours
            --  SDKROOT as the driver does.  A host that cannot say where
            --  its SDK is cannot settle the search, and the library then
            --  counts as found.
            Darwin : constant Boolean :=
              Landin.Targets.Capabilities.Hosted_System_Of (Facts)
                = Landin.Targets.Capabilities.Darwin;
            SDK_Asked : Boolean := False;
            SDK_Library : Unbounded.Unbounded_String;

            function SDK_Holds (File : String) return Boolean;

            function SDK_Holds (File : String) return Boolean is
            begin
               if not SDK_Asked then
                  SDK_Asked := True;
                  declare
                     Asked : Landin.Platform.Tool_Result;
                     Arguments : Landin.Platform.Path_List;
                  begin
                     Arguments.Append ("--sdk");
                     Arguments.Append ("macosx");
                     Arguments.Append ("--show-sdk-path");
                     Tools.Run
                       ("xcrun", Arguments, Asked,
                        Landin.Platform.Output_Only);
                     if Asked.Ended = Landin.Platform.Exited
                       and then Asked.Exit_Code = 0
                     then
                        declare
                           Path : constant String :=
                                   Ada.Strings.Fixed.Trim
                             (Unbounded.To_String (Asked.Output),
                              Ada.Strings.Maps.To_Set
                                (ASCII.LF & ASCII.CR & ' '),
                              Ada.Strings.Maps.To_Set
                                (ASCII.LF & ASCII.CR & ' '));
                        begin
                           if Path'Length > 0
                             and then Host.Is_Directory (Path & "/usr/lib")
                           then
                              SDK_Library :=
                                Unbounded.To_Unbounded_String
                                  (Path & "/usr/lib");
                           end if;
                        end;
                     end if;
                  exception
                     when Landin.External_Tool_Failed =>
                        null;
                  end;
               end if;
               if Unbounded.Length (SDK_Library) = 0 then
                  return True;
               end if;
               declare
                  Candidate : constant String :=
                    Unbounded.To_String (SDK_Library) & "/" & File;
               begin
                  return Host.Exists (Candidate)
                    and then not Host.Is_Directory (Candidate);
               end;
            end SDK_Holds;
         begin
            for Index in 1 .. Landin.Configuration.Library_Count (Table) loop
               declare
                  Name : constant String :=
                    Landin.Configuration.Library_Name (Table, Index);
                  Files : constant Landin.Platform.Path_List :=
                    Landin.Backend.Toolchain.Library_Files (Facts, Name);
                  Found : Boolean := False;
               begin
                  if not (for some Earlier of Reported => Earlier = Name)
                  then
                     Reported.Append (Name);
                     for Directory of Directories loop
                        for File of Files loop
                           Found := Found
                             or else (Host.Exists (Directory & "/" & File)
                                      and then not Host.Is_Directory
                                        (Directory & "/" & File));
                        end loop;
                     end loop;
                     for File of Files loop
                        exit when Found;
                        Found := Driver_Holds (File);
                     end loop;
                     if Darwin then
                        for File of Files loop
                           exit when Found;
                           Found := SDK_Holds (File);
                        end loop;
                     end if;
                     if not Found then
                        Any := True;
                        Note_Missing_Library (Index, Files, Directories);
                     end if;
                  end if;
               end;
            end loop;
            return Any;
         end Libraries_Missing;

         --  A staged tool works in its pinned private directory. Resolve
         --  explicit file-reading directives before launch, and refuse
         --  relative or indirect forms whose meaning that would change.
         --
         --  D1059: a text input is scanned once, by path and by identity,
         --  and the inputs of one build are bounded.  Read again at every
         --  mention, fifteen files that each named the next six times
         --  were 6 ** 14 reads.
         Scan_File_Limit : constant := 4096;
         Scan_Byte_Limit : constant := 64 * 1024 * 1024;
         Scanned_Paths : Landin.Platform.Path_List;
         Scanned_Identities : Landin.Platform.Identity_List;
         Scanned_Assembly : Landin.Platform.Identity_List;
         Scanned_Bytes : Natural := 0;

         procedure Check_External_Text
           (Text, Origin : String; Depth : Natural);
         procedure Check_Assembly_Text
           (Text, Origin : String; Depth : Natural;
            Emitted : Boolean := False);
         procedure Read_External_Input
           (Path : String; Assembly : Boolean; Depth : Natural);
         procedure File_Reference
           (Path, Origin : String; Assembly, Binary : Boolean;
            Depth : Natural);

         procedure Read_External_Input
           (Path : String; Assembly : Boolean; Depth : Natural)
         is
            Content : Unbounded.Unbounded_String;
            Identity : Landin.Platform.File_Identity;
            Read : Landin.Platform.Read_Status;
            --  An assembly input and a linker input are read by
            --  different rules, so each scan remembers its own.
            Key : constant String := (if Assembly then "s:" else "l:") & Path;
         begin
            if Depth > 16 then
               Note_Failure
                 (Code_Unreadable, "tool input nesting exceeds sixteen at "
                  & Path & "; use a standalone script or assembly input");
               return;
            elsif Scanned_Paths.Contains (Key) then
               return;
            end if;
            Host.Read_Snapshot (Path, Content, Identity, Read);
            if Read /= Landin.Platform.Read_Ok then
               Note_Failure
                 (Code_Unreadable, "cannot read tool input " & Path
                  & "; name an existing readable absolute file");
               return;
            end if;
            Observed_Input (Path, Identity);
            Scanned_Paths.Append (Key);
            if Identity.Valid then
               if (if Assembly
                   then (for some Seen of Scanned_Assembly => Seen = Identity)
                   else (for some Seen of Scanned_Identities
                           => Seen = Identity))
               then
                  return;
               elsif Assembly then
                  Scanned_Assembly.Append (Identity);
               else
                  Scanned_Identities.Append (Identity);
               end if;
            end if;
            declare
               Text : constant String := Unbounded.To_String (Content);
            begin
               --  A resolved library may be a linker script. Ordinary ELF
               --  objects and archives are opaque inputs, even an empty
               --  archive whose header contains no NUL byte.  An assembly
               --  input is text whatever bytes it holds: the assembler
               --  reads past a NUL, so the scan does.
               if Assembly
                 or else
                   (not Starts_With (Text, ASCII.DEL & "ELF")
                    and then not Starts_With (Text, "!<arch>" & ASCII.LF)
                    and then not Starts_With (Text, "!<thin>" & ASCII.LF)
                    and then not (for some Byte of Text => Byte = ASCII.NUL))
               then
                  if Natural (Scanned_Paths.Length) > Scan_File_Limit
                    or else Text'Length > Scan_Byte_Limit - Scanned_Bytes
                  then
                     Note_Failure
                       (Code_Unreadable, "tool inputs exceed"
                        & Integer'Image (Scan_File_Limit) & " files or"
                        & Integer'Image (Scan_Byte_Limit / (1024 * 1024))
                        & " MiB of text at " & Path
                        & "; use a standalone script or assembly input");
                     return;
                  end if;
                  Scanned_Bytes := Scanned_Bytes + Text'Length;
                  if Assembly then
                     Check_Assembly_Text (Text, Path, Depth);
                  else
                     Check_External_Text (Text, Path, Depth);
                  end if;
               end if;
            end;
         end Read_External_Input;

         procedure File_Reference
           (Path, Origin : String; Assembly, Binary : Boolean;
            Depth : Natural) is
         begin
            if Path'Length = 0 or else Path (Path'First) /= '/'
              or else (for some Byte of Path => Byte = '\')
            then
               Note_Failure
                 (Code_Unreadable, "tool input " & Origin
                  & " has a relative or indirect file directive: " & Path
                  & "; use plain absolute file paths, or a standalone "
                  & (if Assembly then "assembly input"
                     else "linker script"));
            elsif Binary then
               Protect_Input (Path);
            else
               Read_External_Input (Path, Assembly, Depth + 1);
            end if;
         end File_Reference;

         --  D1060: an assembly input's file directives, found without
         --  deciding what the target's assembler takes for a comment.
         --  `#`, `@`, `;` and `//` each begin one on some target and are
         --  an operand on another, and a scan that took the wrong one
         --  skipped the directive after it.  So only what every assembler
         --  agrees on is skipped: a `/* */` comment, a double-quoted
         --  string with its backslash escapes, ended by its line at the
         --  latest, and the character after a `'`.  Everywhere else the
         --  word `.include` or `.incbin` is the directive, behind a
         --  label, a separator or a comment marker alike, and it either
         --  names its file plainly or is refused.  A macro can form the
         --  word from its arguments where no scan sees it, so an input
         --  that defines one is refused.  Emitted assembly holds no file
         --  directive at all: no backend writes one, and [1990] keeps
         --  directives out of block text.
         procedure Check_Assembly_Text
           (Text, Origin : String; Depth : Natural;
            Emitted : Boolean := False)
         is
            Index : Natural := Text'First;
            Line : Positive := 1;

            function Is_Symbol (Byte : Character) return Boolean
              is (Byte in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.'
                    | '$');

            function Place return String
              is (Origin & " line" & Positive'Image (Line));

            procedure Unestablished (Word : String);

            procedure Unestablished (Word : String) is
            begin
               Note_Failure
                 (Code_Unreadable, "tool input " & Place & " names `"
                  & Word & "` where the file it reads cannot be"
                  & " established; write `" & Word
                  & " ""/absolute/path""` plainly, and keep the word out"
                  & " of comments");
            end Unestablished;
         begin
            while Index <= Text'Last
              and then not Landin.Stages.Failed (Context)
            loop
               if Text (Index) = ASCII.LF then
                  Line := Line + 1;
                  Index := Index + 1;
               elsif Index < Text'Last
                 and then Text (Index .. Index + 1) = "/*"
               then
                  Index := Index + 2;
                  while Index < Text'Last
                    and then Text (Index .. Index + 1) /= "*/"
                  loop
                     if Text (Index) = ASCII.LF then
                        Line := Line + 1;
                     end if;
                     Index := Index + 1;
                  end loop;
                  Index := Natural'Min (Text'Last + 1, Index + 2);
               elsif Text (Index) = ''' then
                  --  A character constant: the next byte is its value,
                  --  a quote among them.
                  Index := Natural'Min (Text'Last + 1, Index + 2);
               elsif Text (Index) = '"' then
                  Index := Index + 1;
                  while Index <= Text'Last
                    and then Text (Index) not in '"' | ASCII.LF
                  loop
                     Index := Index
                       + (if Text (Index) = '\' and then Index < Text'Last
                            and then Text (Index + 1) /= ASCII.LF
                          then 2 else 1);
                  end loop;
                  if Index <= Text'Last and then Text (Index) = '"' then
                     Index := Index + 1;
                  end if;
               elsif Text (Index) = '.'
                 and then (Index = Text'First
                           or else not Is_Symbol (Text (Index - 1)))
               then
                  declare
                     Stop : Natural := Index + 1;
                  begin
                     while Stop <= Text'Last and then Is_Symbol (Text (Stop))
                     loop
                        Stop := Stop + 1;
                     end loop;
                     declare
                        Word : constant String :=
                          Ada.Characters.Handling.To_Lower
                            (Text (Index .. Stop - 1));
                        First : Natural := Stop;
                        Last : Natural;
                     begin
                        if Word in ".macro" | ".irp" | ".irpc" | ".altmacro"
                        then
                           Note_Failure
                             (Code_Unreadable, "tool input " & Place
                              & " uses `" & Word & "`, and a macro can form"
                              & " a file directive where it cannot be"
                              & " found; expand the input's macros before"
                              & " giving it to refine");
                        elsif Word in ".include" | ".incbin" and then Emitted
                        then
                           Note_Failure
                             (Code_Unreadable, "emitted assembly " & Place
                              & " holds the file directive `" & Word
                              & "`, which the compiler writes nowhere and"
                              & " assembly block text may not hold");
                        elsif Word in ".include" | ".incbin" then
                           while First <= Text'Last
                             and then Text (First) in ' ' | ASCII.HT
                           loop
                              First := First + 1;
                           end loop;
                           Last := First + 1;
                           while Last <= Text'Last
                             and then Text (Last) not in '"' | ASCII.LF
                           loop
                              Last := Last + 1;
                           end loop;
                           if First > Text'Last or else Text (First) /= '"'
                             or else Last > Text'Last
                             or else Text (Last) /= '"'
                           then
                              Unestablished (Word);
                           else
                              File_Reference
                                (Text (First + 1 .. Last - 1), Origin,
                                 Assembly => True,
                                 Binary => Word = ".incbin", Depth => Depth);
                              Stop := Last + 1;
                           end if;
                        end if;
                     end;
                     Index := Stop;
                  end;
               else
                  Index := Index + 1;
               end if;
            end loop;
         end Check_Assembly_Text;

         --  A linker script's file commands, by its own tokens.
         procedure Check_External_Text
           (Text, Origin : String; Depth : Natural)
         is
            Cursor : Natural := Text'First;
            Quoted : Boolean := False;
            function Next return String;
            function Next return String is
               First : Natural;
               Quote : Character;
            begin
               Quoted := False;
               loop
                  while Cursor <= Text'Last
                    and then Text (Cursor) in ' ' | ASCII.HT
                      | ASCII.LF | ASCII.CR
                  loop
                     Cursor := Cursor + 1;
                  end loop;
                  exit when Cursor > Text'Last;
                  if Cursor < Text'Last
                    and then Text (Cursor .. Cursor + 1) = "/*"
                  then
                     Cursor := Cursor + 2;
                     while Cursor < Text'Last
                       and then Text (Cursor .. Cursor + 1) /= "*/"
                     loop
                        Cursor := Cursor + 1;
                     end loop;
                     Cursor := Natural'Min (Text'Last + 1, Cursor + 2);
                  elsif Text (Cursor) = '#' then
                     while Cursor <= Text'Last
                       and then Text (Cursor) /= ASCII.LF
                     loop
                        Cursor := Cursor + 1;
                     end loop;
                  else
                     exit;
                  end if;
               end loop;
               if Cursor > Text'Last then
                  return "";
               end if;
               First := Cursor;
               if Text (Cursor) in '(' | ')' | ',' | ';' | '{' | '}' | '=' then
                  Cursor := Cursor + 1;
                  return Text (First .. First);
               elsif Text (Cursor) in '"' | ''' then
                  Quoted := True;
                  Quote := Text (Cursor);
                  Cursor := Cursor + 1;
                  First := Cursor;
                  while Cursor <= Text'Last and then Text (Cursor) /= Quote
                  loop
                     Cursor := Cursor + 1;
                  end loop;
                  if Cursor > Text'Last then
                     return "";
                  end if;
                  Cursor := Cursor + 1;
                  return Text (First .. Cursor - 2);
               end if;
               while Cursor <= Text'Last
                 and then Text (Cursor) not in ' ' | ASCII.HT
                   | ASCII.LF | ASCII.CR | '(' | ')' | ',' | ';' | '{' | '}'
                   | '='
               loop
                  Cursor := Cursor + 1;
               end loop;
               return Text (First .. Cursor - 1);
            end Next;

            procedure File_Reference (Path : String; Binary : Boolean);
            procedure File_Reference (Path : String; Binary : Boolean) is
            begin
               File_Reference
                 (Path, Origin, Assembly => False, Binary => Binary,
                  Depth => Depth);
            end File_Reference;
         begin
            loop
               declare
                  Token : constant String := Next;
               begin
                  exit when (Token = "" and then not Quoted)
                    or else Landin.Stages.Failed (Context);
                  if Quoted then
                     null;
                  elsif Token = "INCLUDE" then
                     File_Reference (Next, Binary => False);
                  elsif Token in "INPUT" | "GROUP" | "SEARCH_DIR" | "STARTUP"
                  then
                     declare
                        Opened : constant String := Next;
                        Nesting : Natural := 1;
                     begin
                        if Opened /= "(" then
                           Note_Failure
                             (Code_Unreadable, "cannot establish inputs of "
                              & Token & " in " & Origin
                              & "; use plain absolute file directives");
                           return;
                        end if;
                        loop
                           declare
                              File : constant String := Next;
                           begin
                              exit when File = "";
                              if File = "(" then
                                 Nesting := Nesting + 1;
                              elsif File = ")" then
                                 Nesting := Nesting - 1;
                                 exit when Nesting = 0;
                              elsif File not in "," | "AS_NEEDED" then
                                 File_Reference
                                   (File, Binary => Token = "SEARCH_DIR");
                              end if;
                              exit when Landin.Stages.Failed (Context);
                           end;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
         end Check_External_Text;

         procedure Protect_Link_Inputs (Driver : String);
         procedure Protect_Link_Inputs (Driver : String) is
            Directories : constant Landin.Platform.Path_List :=
              Search_Directories;
            Table : Landin.Configuration.Table renames
              Landin.Stages.Configurations (Context).all;
         begin
            Protect_Tool_Inputs (Driver);
            for Index in 1 .. Landin.Configuration.Library_Count (Table) loop
               declare
                  Files : constant Landin.Platform.Path_List :=
                    Landin.Backend.Toolchain.Library_Files
                      (Facts, Landin.Configuration.Library_Name
                         (Table, Index));
                  Located : Boolean := False;
               begin
                  for Directory of Directories loop
                     for File of Files loop
                        if Host.Exists (Directory & "/" & File) then
                           Read_External_Input
                             (Directory & "/" & File, False, 0);
                           if Landin.Stages.Failed (Context) then
                              return;
                           end if;
                           Located := True;
                        end if;
                     end loop;
                  end loop;
                  if not Located then
                     for File of Files loop
                        declare
                           Asked : Landin.Platform.Tool_Result;
                        begin
                           Tools.Run
                             (Driver,
                              Landin.Backend.Toolchain.Print_File_Arguments
                                (File), Asked, Landin.Platform.Output_Only);
                           if Asked.Ended = Landin.Platform.Exited
                             and then Asked.Exit_Code = 0
                           then
                              declare
                                 Path : constant String :=
                                   Ada.Strings.Fixed.Trim
                                   (Unbounded.To_String (Asked.Output),
                                    Ada.Strings.Maps.To_Set
                                      (ASCII.LF & ASCII.CR & ' '),
                                    Ada.Strings.Maps.To_Set
                                      (ASCII.LF & ASCII.CR & ' '));
                              begin
                                 if Path /= File
                                   and then Host.Exists (Path)
                                 then
                                    Read_External_Input (Path, False, 0);
                                    if Landin.Stages.Failed (Context) then
                                       return;
                                    end if;
                                 end if;
                              end;
                           end if;
                        exception
                           when Landin.External_Tool_Failed => null;
                        end;
                     end loop;
                  end if;
               end;
            end loop;
         end Protect_Link_Inputs;

         --  D683, D685: the ESP application image of the executable at
         --  TARGET_PATH, written as TARGET_PATH.bin and read back before the
         --  build succeeds.  A refusal removes the executable and any
         --  image, so no build leaves an image it did not check.
         procedure Write_ESP_Image (Target_Path : String);

         procedure Write_ESP_Image (Target_Path : String) is
            Profile : constant Landin.Targets.Firmware.Profile :=
              Landin.IR.Firmware_Profile (Landin.Stages.Code (Context).all);
            Image_Path : constant String :=
              Private_Path (Target_Path & ".bin");
            Executable, Read_Back : Unbounded.Unbounded_String;
            Read : Landin.Platform.Read_Status;
            Written : Landin.Platform.Write_Status;

         begin
            Host.Read_File (Private_Path (Target_Path), Executable, Read);
            if Read /= Landin.Platform.Read_Ok then
               Note_Failure
                 (Code_Toolchain_Failed,
                  "cannot read the linked executable: " & Target_Path);
               return;
            end if;
            declare
               Made : constant Landin.Driver.ESP_Image.Made :=
                 Landin.Driver.ESP_Image.Make
                   (Unbounded.To_String (Executable), Profile);
            begin
               if Unbounded.Length (Made.Fault) > 0 then
                  Note_Failure
                    (Rows.Code (Rows.ESP_Image_Object),
                     Unbounded.To_String (Made.Fault) & ", so no ESP"
                     & " application image can hold it (D685)");
                  return;
               end if;
               Host.Write_File
                 (Image_Path, Unbounded.To_String (Made.Image), Written,
                  Pending_Write_Reason);
               if Written /= Landin.Platform.Write_Ok then
                  Note_Failure
                    (Code_Unwritable, Write_Failure (Target_Path & ".bin"));
                  return;
               end if;
               Host.Read_File (Image_Path, Read_Back, Read);
               if Read /= Landin.Platform.Read_Ok then
                  Note_Failure
                    (Code_Toolchain_Failed,
                     "cannot read the written image: " & Target_Path & ".bin");
                  return;
               end if;
               declare
                  Fault : constant String :=
                    Landin.Driver.ESP_Image.Read_Back_Fault
                      (Unbounded.To_String (Read_Back),
                       Unbounded.To_String (Executable), Profile);
               begin
                  if Fault /= "" then
                     Note_Failure
                       (Rows.Code (Rows.ESP_Image_Object),
                        Target_Path & ".bin does not read back"
                        & " as the image of "
                        & Target_Path & ": " & Fault & " (D685)");
                        return;
                  end if;
               end;
               ESP_Image_Report := Made.Report;
               ESP_Image_Path :=
                 Unbounded.To_Unbounded_String (Target_Path & ".bin");
            end;
         end Write_ESP_Image;

         --  The link that finishes an executable from assembly, whether
         --  this request emitted it or named it (D362): the driver chosen,
         --  the prior executable kept aside until a new one exists, and
         --  every failure said as the tool said it.
         procedure Link_Assembly
           (Assembly_Path, Product_Path, Map_Id : String;
            Destinations : Landin.Platform.Path_List;
            Separate_Debug_Object : Boolean := False);

         --  D924: what a firmware image's C archives brought that
         --  compiler-owned startup cannot honour, and what to do instead.
         procedure Note_Foreign_Section
           (Found : Landin.Build_Reports.Firmware.Foreign_Section);
         procedure Note_Foreign_Section
           (Found : Landin.Build_Reports.Firmware.Foreign_Section)
         is
            Name : constant String := "`" & Unbounded.To_String (Found.Name)
              & "`";
            Item : Landin.Diagnostics.Diagnostic :=
              Landin.Diagnostics.Make
                (Code    => Rows.Code (Rows.Firmware_Foreign_Section),
                 Level   => Landin.Diagnostics.Error,
                 Source  => Landin.Source.No_Source,
                 Where   => Landin.Source.Empty_Span,
                 Message =>
                   (case Found.Kind is
                      when Landin.Build_Reports.Firmware.Constructors =>
                        "the firmware image holds C constructors in " & Name
                        & ", which compiler-owned startup never runs",
                      when Landin.Build_Reports.Firmware.Thread_Storage =>
                        "the firmware image holds thread-local storage in "
                        & Name & ", which firmware has no thread pointer"
                        & " or thread image for",
                      when others =>
                        "the firmware image is linked dynamically, with "
                        & Name & ", and firmware has no loader"));
         begin
            Landin.Diagnostics.Add_Note
              (Item,
               (case Found.Kind is
                  when Landin.Build_Reports.Firmware.Constructors =>
                    "D924: build the library without"
                    & " `__attribute__((constructor))` or static"
                    & " constructors, and call its initialisation from the"
                    & " firmware entry",
                  when Landin.Build_Reports.Firmware.Thread_Storage =>
                    "D924: firmware runs one thread; declare the C variable"
                    & " without `_Thread_local` or `__thread`, as ordinary"
                    & " static data",
                  when others =>
                    "D924: link the library's static archive, built for"
                    & " the firmware's core, and no shared object"));
            Landin.Stages.Report (Context, Item);
         end Note_Foreign_Section;

         procedure Link_Assembly
           (Assembly_Path, Product_Path, Map_Id : String;
            Destinations : Landin.Platform.Path_List;
            Separate_Debug_Object : Boolean := False)
         is
            use type Landin.Build_Reports.Firmware.Foreign_Kind;
            On_Firmware : constant Boolean :=
              Landin.Targets.Is_Firmware (Facts);
            Written : Landin.Platform.Write_Status;
            pragma Unreferenced (Destinations);
         begin
            declare
               Driver : constant String :=
                 Unbounded.To_String (Chosen_Driver);
               Target_Path : constant String := Product_Path;
               Input_Assembly : constant String := Absolute (Assembly_Path);
               Input_Script : constant String :=
                 (if Unbounded.Length (Script_Path) = 0 then ""
                  else Absolute (Unbounded.To_String (Script_Path)));
               Selected_Linker : constant String :=
                 (if Ada.Strings.Fixed.Index
                       (Unbounded.To_String (Linker), "/") > 0
                  then Absolute (Unbounded.To_String (Linker))
                  else Unbounded.To_String (Linker));
               Staged_Product : constant String := Private_Path (Product_Path);
               Prior_Identity : constant Landin.Platform.File_Identity :=
                 Host.Identity_Of (Product_Path);
               Ran : Landin.Platform.Tool_Result;
               Libraries : Landin.Platform.Path_List;
               Directories : constant Landin.Platform.Path_List :=
                 Search_Directories;
            begin
               if Driver = "" then
                  Note_No_Toolchain
                    ("target " & Landin.Targets.Name (Facts)
                     & " names no toolchain",
                     "name one with --toolchain=NAME");
                  return;
               end if;

               Protect_Link_Inputs (Driver);
               if Script_Seen then
                  Read_External_Input
                    (Unbounded.To_String (Script_Path), False, 0);
               end if;
               if Landin.Stages.Failed (Context) then
                  return;
               end if;
               for Index in 1 .. Landin.Configuration.Library_Count
                 (Landin.Stages.Configurations (Context).all)
               loop
                  Libraries.Append (Landin.Configuration.Library_Name
                    (Landin.Stages.Configurations (Context).all, Index));
               end loop;

               --  A tool that cannot be started at all is the platform
               --  interface's own distinction, and it is exactly the one a
               --  host without this target's toolchain falls on.  Catching
               --  it here is what turns "not installed" into a sentence
               --  rather than an unhandled exception at the top of
               --  `refine`.
               begin
                  if Separate_Debug_Object then
                     --  Apple Clang derives -save-temps objects from input
                     --  basenames. An assembly operand can have a different
                     --  name from its product; assemble the reserved object
                     --  explicitly before linking and packaging its dSYM.
                     Tools.Prepare_Output (Host, Staged_Product & ".o");
                     Tools.Run
                       (Driver,
                        Landin.Backend.Toolchain.Assemble_Arguments
                          (Input_Assembly, Staged_Product & ".o", Facts,
                           Debug => True,
                           Level => Landin.Stages.Level (Context)),
                        Ran, Landin.Platform.Merged);
                     if Ran.Ended /= Landin.Platform.Exited
                       or else Ran.Exit_Code /= 0
                     then
                        Note_Tool_Failure
                          ("assembly failed",
                           Logical_Text (Unbounded.To_String (Ran.Output)));
                        return;
                     elsif not Tools.Output_Produced
                       (Host, Staged_Product & ".o")
                     then
                        Note_Failure
                          (Code_Toolchain_Failed,
                           Driver & " reported success but produced no object"
                           & " at " & Product_Path & ".o");
                        return;
                     end if;
                  end if;
                  if On_Firmware then
                     Host.Write_File
                       (Staged_Product & ".ld",
                        Landin.Backend.Firmware.Linker_Script
                          (Landin.IR.Firmware_Profile
                             (Landin.Stages.Code (Context).all),
                           Landin.Backend.Firmware.Used_Regions
                             (Landin.Stages.Code (Context).all,
                              Landin.Stages.Identities (Context).all),
                           Archives => not Libraries.Is_Empty),
                        Written, Pending_Write_Reason);
                     if Written /= Landin.Platform.Write_Ok then
                        Note_Failure
                          (Code_Unwritable,
                           Write_Failure (Product_Path & ".ld"));
                        return;
                     end if;
                     Tools.Prepare_Output (Host, Staged_Product & ".o");
                     Tools.Run
                       (Driver,
                        Landin.Backend.Toolchain.Assemble_Arguments
                          (Input_Assembly, Staged_Product & ".o", Facts,
                           Debug => Debug_Enabled,
                           Level => Landin.Stages.Level (Context),
                           Float => Landin.IR.Firmware_Profile
                             (Landin.Stages.Code (Context).all).Float),
                        Ran, Landin.Platform.Merged);
                     if Ran.Ended /= Landin.Platform.Exited
                       or else Ran.Exit_Code /= 0
                     then
                        Note_Tool_Failure
                          ("firmware assembly failed",
                           Logical_Text (Unbounded.To_String (Ran.Output)));
                        return;
                     end if;
                     if not Tools.Output_Produced
                       (Host, Staged_Product & ".o")
                     then
                        Note_Failure
                          (Code_Toolchain_Failed,
                           Driver & " reported success but produced no object"
                           & " at " & Product_Path & ".o");
                        return;
                     end if;
                     --  D588: the boot ROM's checksum over the second
                     --  stage as the assembler wrote it, in the object
                     --  every link of this build reads.
                     if Landin.Targets.Firmware.Takes_Stage
                       (Landin.IR.Firmware_Profile
                          (Landin.Stages.Code (Context).all).Boot)
                     then
                        declare
                           Object : Unbounded.Unbounded_String;
                           Read : Landin.Platform.Read_Status;
                           Fault : Unbounded.Unbounded_String;
                        begin
                           Host.Read_File
                             (Staged_Product & ".o", Object, Read);
                           if Read /= Landin.Platform.Read_Ok then
                              Note_Failure
                                (Code_Toolchain_Failed,
                                 "cannot read the assembled object: "
                                 & Product_Path & ".o");
                              return;
                           end if;
                           Landin.Driver.Boot_Stage.Seal (Object, Fault);
                           if Unbounded.Length (Fault) > 0 then
                              Note_Failure
                                (Rows.Code (Rows.Boot_Stage_Object),
                                 Unbounded.To_String (Fault) & " (D588)");
                              return;
                           end if;
                           Host.Write_File
                             (Staged_Product & ".o",
                              Unbounded.To_String (Object), Written,
                              Pending_Write_Reason);
                           if Written /= Landin.Platform.Write_Ok then
                              Note_Failure
                                (Code_Unwritable,
                                 Write_Failure (Product_Path & ".o"));
                              return;
                           end if;
                        end;
                     end if;
                     --  D638: the image block as the assembler wrote it,
                     --  before anything links it.
                     if Landin.Targets.Firmware.Takes_Image_Block
                       (Landin.IR.Firmware_Profile
                          (Landin.Stages.Code (Context).all).Boot)
                     then
                        declare
                           Object : Unbounded.Unbounded_String;
                           Read : Landin.Platform.Read_Status;
                        begin
                           Host.Read_File
                             (Staged_Product & ".o", Object, Read);
                           if Read /= Landin.Platform.Read_Ok then
                              Note_Failure
                                (Code_Toolchain_Failed,
                                 "cannot read the assembled object: "
                                 & Product_Path & ".o");
                              return;
                           end if;
                           declare
                              Fault : constant String := Unbounded.To_String
                                (Landin.Driver.Image_Block.Fault
                                   (Unbounded.To_String (Object),
                                    Landin.IR.Firmware_Profile
                                      (Landin.Stages.Code (Context).all)
                                      .Core));
                           begin
                              if Fault /= "" then
                                 Note_Failure
                                   (Rows.Code (Rows.Image_Block_Object),
                                    Fault & " (D638)");
                                 return;
                              end if;
                           end;
                        end;
                     end if;
                  end if;
                  Tools.Prepare_Output (Host, Staged_Product);
                  Tools.Run
                    (Program   => Driver,
                     Arguments =>
                       Landin.Backend.Toolchain.Link_Arguments
                         (Assembly => (if Separate_Debug_Object
                                       then Staged_Product & ".o"
                                       else Input_Assembly),
                          Output   => Staged_Product,
                          Linker   => Selected_Linker,
                          Build_Id => Map_Id,
                          Full_Debug => Debug_Enabled,
                          Libraries => Libraries, Facts => Facts,
                          Level => Landin.Stages.Level (Context),
                          Static => Static_Link,
                          Threads => Starts_C_Threads,
                          Directories => Directories,
                          Script => Input_Script,
                          Float => Landin.IR.Firmware_Profile
                            (Landin.Stages.Code (Context).all).Float,
                          Assembly_Is_Object => Separate_Debug_Object),
                     Result    => Ran,
                     Capture   => Landin.Platform.Merged);
               exception
                  when Failure : Landin.External_Tool_Failed =>
                     --  The adapter says why.  Only a tool that is not
                     --  there is the reader's to install; a capture file
                     --  that could not be removed is a host fault after
                     --  the tool ran, and naming it a missing toolchain
                     --  sent the reader to install one they had.
                     declare
                        Why : constant String :=
                          Ada.Exceptions.Exception_Message (Failure);
                     begin
                        if Starts_With (Why, "tool not found") then
                           Note_Unavailable_Toolchain (Driver);
                        else
                           Note_Failure
                             (Code_Toolchain_Failed,
                              Why & "; " & Driver
                              & " could not be run to completion");
                        end if;
                     end;
                     return;
               end;

               --  How the run ended is asked before what it returned,
               --  because a tool a signal killed has no status and the
               --  field beside it holds zero.  Reading that alone would
               --  make a dead assembler a success that wrote nothing.
               if Ran.Ended /= Landin.Platform.Exited then
                  Note_Tool_Failure
                    (Driver & " was stopped before it could finish",
                     Logical_Text (Unbounded.To_String (Ran.Output)));
               elsif Ran.Exit_Code /= 0 then
                  --  A line the assembler refused inside an assembly
                  --  block is the program's, and is reported there.
                  declare
                     Written_Assembly : Unbounded.Unbounded_String;
                     Read : Landin.Platform.Read_Status;
                     Found : Landin.Diagnostics.Diagnostic_List;
                     Placed : Boolean := False;
                  begin
                     Host.Read_File (Assembly_Path, Written_Assembly, Read);
                     if Read = Landin.Platform.Read_Ok
                       and then Landin.Stages.Source_Count (Context) > 0
                     then
                        Landin.Driver.Assembler_Sites.Place
                          (Output  => Logical_Text
                             (Unbounded.To_String (Ran.Output)),
                           Emitted => Unbounded.To_String (Written_Assembly),
                           Code    => Landin.Stages.Code (Context).all,
                           Names   => Landin.Stages.Identities (Context).all,
                           Facts   => Facts,
                           Into    => Found,
                           Placed  => Placed);
                     end if;
                     if Placed then
                        for Index in 1 .. Landin.Diagnostics.Count (Found) loop
                           Landin.Stages.Report
                             (Context, Landin.Diagnostics.Get (Found, Index));
                        end loop;
                     elsif not Libraries.Is_Empty
                       and then Libraries_Missing (Driver, Directories)
                     then
                        null;
                     else
                        Note_Tool_Failure
                          (Driver & " failed with status"
                           & Integer'Image (Ran.Exit_Code),
                           Logical_Text (Unbounded.To_String (Ran.Output))
                           & Float_Variant_Advice
                               (Unbounded.To_String (Ran.Output))
                           & (if Selected_Layout =
                               Landin.Targets.Firmware.RAM_Layout
                             then LF & "RAM layout capacity is bounded by"
                               & " the described SRAM; use"
                               & " --firmware-layout=boot for the board"
                               & " boot check" else ""));
                     end if;
                  end;
               elsif not Tools.Output_Produced (Host, Staged_Product) then
                  Note_Tool_Failure
                    (Driver & " reported success but produced no executable"
                     & " at " & Target_Path,
                     Logical_Text (Unbounded.To_String (Ran.Output)));
               elsif Prior_Identity.Valid
                 and then Host.Identity_Of (Staged_Product) = Prior_Identity
               then
                  Note_Failure
                    (Code_Toolchain_Failed,
                     Driver & " left executable output aliasing its prior"
                     & " output at " & Target_Path);
               elsif On_Firmware and then not Libraries.Is_Empty
                 and then Landin.Build_Reports.Firmware.Foreign_Section_Of
                   (Host, Staged_Product).Kind
                     /= Landin.Build_Reports.Firmware.No_Foreign
               then
                  Note_Foreign_Section
                    (Landin.Build_Reports.Firmware.Foreign_Section_Of
                       (Host, Staged_Product));
               elsif On_Firmware
                 and then (Script_Seen or else Selected_Layout =
                             Landin.Targets.Firmware.RAM_Layout)
                 and then Landin.Build_Reports.Firmware.Contract_Fault
                   (Host, Staged_Product,
                    Landin.IR.Firmware_Profile
                      (Landin.Stages.Code (Context).all),
                    Landin.Backend.Firmware.Used_Regions
                      (Landin.Stages.Code (Context).all,
                       Landin.Stages.Identities (Context).all)) /= ""
               then
                  --  D546: the developer's script broke a clause.
                  Note_Failure
                    (Rows.Code (Rows.Linker_Script_Contract),
                     (if Script_Seen then Unbounded.To_String (Script_Path)
                      else "the RAM layout")
                     & " breaks the firmware linker script contract, "
                     & Landin.Build_Reports.Firmware.Contract_Fault
                         (Host, Staged_Product,
                          Landin.IR.Firmware_Profile
                            (Landin.Stages.Code (Context).all),
                          Landin.Backend.Firmware.Used_Regions
                            (Landin.Stages.Code (Context).all,
                             Landin.Stages.Identities (Context).all))
                     & (if Script_Seen
                        then " (D546); the derived script beside it, "
                          & Target_Path & ".ld, keeps every clause"
                        else " (D900); keep every runtime section in SRAM,"
                          & " or use --firmware-layout=boot for the board"
                          & " boot check"));
               end if;
               if Separate_Debug_Object
                 and then not Landin.Stages.Failed (Context)
               then
                  declare
                     Program : constant String :=
                       Landin.Backend.Toolchain.Darwin_Debug_Bundle_Tool;
                     Packaged : Landin.Platform.Tool_Result;
                  begin
                     Tools.Prepare_Output (Host, Staged_Product & ".dSYM");
                     Tools.Run
                       (Program,
                        Landin.Backend.Toolchain.Debug_Bundle_Arguments
                          (Staged_Product, Staged_Product & ".dSYM"),
                        Packaged, Landin.Platform.Merged);
                     if Packaged.Ended /= Landin.Platform.Exited
                       or else Packaged.Exit_Code /= 0
                     then
                        Note_Tool_Failure
                          (Program & " failed to package debug information",
                           Logical_Text
                             (Unbounded.To_String (Packaged.Output)));
                     elsif not Host.Is_Directory
                       (Staged_Product & ".dSYM")
                     then
                        Note_Failure
                          (Code_Toolchain_Failed,
                           Program & " reported success but produced no bundle"
                           & " at " & Product_Path & ".dSYM");
                     end if;
                  exception
                     when Failure : Landin.External_Tool_Failed =>
                        declare
                           Why : constant String :=
                             Ada.Exceptions.Exception_Message (Failure);
                        begin
                           if Starts_With (Why, "tool not found") then
                              Note_Unavailable_Debug_Bundle;
                           else
                              Note_Failure
                                (Code_Toolchain_Failed,
                                 Why & "; " & Program
                                 & " could not be run to completion");
                           end if;
                        end;
                  end;
               end if;
               if On_Firmware
                 and then Landin.Targets.Firmware.Takes_ESP_Image
                   (Landin.IR.Firmware_Profile
                      (Landin.Stages.Code (Context).all).Boot)
                 and then not Landin.Stages.Failed (Context)
               then
                  Write_ESP_Image (Target_Path);
               end if;
            end;
         end Link_Assembly;

         procedure Emit_Requested;


         --  Everything past the frontend, in one place.  It runs only on a
         --  program every stage accepted, so nothing below has to ask again
         --  whether the Unit is worth reading.
         procedure Emit_Requested is
            Assembly_Path : constant String :=
              (if Emit = Emit_Executable
               then Assembly_Beside
                      (if Unbounded.Length (Output) > 0
                       then Unbounded.To_String (Output)
                       else Default_Executable)
               elsif Unbounded.Length (Output) > 0
               then Unbounded.To_String (Output)
               elsif Emit = Emit_IR then Default_IR
               elsif Emit = Emit_Linker_Script then Default_Script
               else Default_Assembly);

            Written : Landin.Platform.Write_Status;
            Map_Id : Unbounded.Unbounded_String;
            Map_JSON : Unbounded.Unbounded_String;
            Evidence : Landin.Build_Reports.Report;
            Digests : aliased Landin.Source_Digests.Cache
              (Landin.Source.Source_Id (Landin.Stages.Source_Count (Context)));
            Product_Path : constant String :=
              (if Unbounded.Length (Output) > 0
               then Unbounded.To_String (Output)
               elsif Emit = Emit_Executable then Default_Executable
               else Default_Assembly);
            Map_Path : constant String := Source_Map_Beside (Product_Path);
            Report_Path : constant String :=
              Unbounded.To_String (Build_Report_Path);
            Stage_Path : constant String :=
              Unbounded.To_String (Stage_Report_Path);
            Stack_Path : constant String :=
              Unbounded.To_String (Stack_Report_Path);
            Emit_Map : constant Boolean :=
              Emit not in Emit_IR | Emit_Linker_Script
              and then (Debug_Enabled or else Panic_Map
                or else Landin.IR.Caller_Source_Count
                  (Landin.Stages.Code (Context).all) > 0);
            Destinations, Debug_Leaves : Landin.Platform.Path_List;
            Source_Paths : Landin.Platform.Path_List;
            On_Firmware : constant Boolean :=
              Landin.Targets.Is_Firmware (Facts);
            Firmware_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;

            function Conflicts_With (Path : String) return Boolean is
              (Host.Paths_Overlap (Report_Path, Path));

            procedure Write_Stack_Report;

            --  D447: written after the emitted output, as the build report
            --  is, from the frames the backend reported (D467).
            procedure Write_Stack_Report is
               Stack_Written : Landin.Platform.Write_Status;
            begin
               if Stack_Report_Seen
                 and then not Landin.Stages.Failed (Context)
               then
                  Write_Output
                    (Stack_Path,
                     Landin.Build_Reports.Stacks.JSON
                       (Evidence, Context, Optimization, Panic,
                        Landin.Backend.Entry_Point.Hosted_Main
                          (Landin.Stages.Code (Context).all,
                           Landin.Stages.Meanings (Context).all,
                           Landin.Stages.Modules (Context).all,
                           Landin.Stages.Identities (Context).all)),
                     Stack_Written);
                  if Stack_Written /= Landin.Platform.Write_Ok then
                     Note_Failure
                       (Code_Unwritable, Write_Failure (Stack_Path));
                  end if;
               end if;
            end Write_Stack_Report;

            --  D587: the source name of the description's second stage,
            --  or "" when the profile takes none.
            function Boot_Stage_Routine return String;

            function Boot_Stage_Routine return String is
               Unit : Landin.IR.Unit renames Landin.Stages.Code (Context).all;
            begin
               for Index in 1 .. Landin.IR.Item_Count (Unit) loop
                  declare
                     use type Landin.IR.Declaration_Id;
                     Item : constant Landin.IR.Item_Id :=
                       Landin.IR.Item_Id (Index);
                  begin
                     if Landin.IR.Placement_Of (Unit, Item).Boot_Stage
                       and then Landin.IR.Declares (Unit, Item)
                         /= Landin.IR.No_Declaration
                     then
                        return Landin.Source.Names.Spelling
                          (Landin.Stages.Identities (Context).all,
                           Landin.Resolution.Name_Of
                             (Landin.Stages.Meanings (Context).all,
                              Landin.IR.Declares (Unit, Item)));
                     end if;
                  end;
               end loop;
               return "";
            end Boot_Stage_Routine;

            procedure Write_Build_Report;

            procedure Write_Build_Report is
               Firmware : Unbounded.Unbounded_String;
               Valid : Boolean := True;
            begin
               if Report_Seen and then not Landin.Stages.Failed (Context) then
                  if On_Firmware
                    and then Emit in Emit_Linker_Script | Emit_Assembly
                    and then Landin.IR.Firmware_Profile
                      (Landin.Stages.Code (Context).all).Present
                  then
                     Firmware := Unbounded.To_Unbounded_String
                       (Landin.Build_Reports.Firmware.Limits
                          (Landin.IR.Firmware_Profile
                             (Landin.Stages.Code (Context).all)));
                  elsif On_Firmware and then Emit = Emit_Executable then
                     Landin.Build_Reports.Firmware.Measure
                       (Host, Private_Path (Product_Path),
                        Private_Path (Product_Path & ".map"),
                        Landin.IR.Firmware_Profile
                          (Landin.Stages.Code (Context).all),
                        Boot_Stage_Routine, Firmware, Valid,
                        ESP_Image => Unbounded.To_String (ESP_Image_Report));
                     if not Valid then
                        Note_Failure
                          (Code_Toolchain_Failed,
                           "cannot measure linked firmware image or map");
                        return;
                     end if;
                  end if;
                  Write_Output
                    (Report_Path,
                     Landin.Build_Reports.Sources.JSON
                       (Evidence, Context, Optimization,
                        Unbounded.To_String (Firmware), Digests'Access,
                        Link =>
                          (if Landin.Targets.Capabilities.Hosted_System_Of
                                (Facts)
                                = Landin.Targets.Capabilities.No_Hosted_System
                           then ""
                           elsif Static_Link then "static" else "libc")),
                      Written);
                  if Written /= Landin.Platform.Write_Ok then
                     Note_Failure
                       (Code_Unwritable, Write_Failure (Report_Path));
                  end if;
               end if;
            end Write_Build_Report;
         begin
            --  All destinations are checked before the first artifact write,
            --  including source files discovered through module roots.
            Destinations.Append (Assembly_Path);
            if Depfile /= "" then
               Destinations.Append (Depfile);
            end if;
            if Emit = Emit_Executable then
               Destinations.Append (Product_Path);
               if On_Firmware then
                  Destinations.Append (Product_Path & ".o");
                  Destinations.Append (Product_Path & ".ld");
                  Destinations.Append (Product_Path & ".map");
                  if Landin.Targets.Firmware.Takes_ESP_Image
                    (Landin.IR.Firmware_Profile
                       (Landin.Stages.Code (Context).all).Boot)
                  then
                     Destinations.Append (Product_Path & ".bin");
                  end if;
               end if;
               if Debug_Enabled then
                  for Path of Landin.Backend.Toolchain.Debug_Artifacts
                    (Product_Path, Facts, Host)
                  loop
                     Destinations.Append (Path);
                     if Path /= Product_Path & ".o"
                       and then Path /= Product_Path & ".dSYM"
                     then
                        Debug_Leaves.Append (Path);
                     end if;
                  end loop;
               end if;
            end if;
            if Emit_Map then
               Destinations.Append (Map_Path);
            end if;
            if Stage_Report_Seen then
               for Path of Destinations loop
                  if Host.Paths_Overlap (Stage_Path, Path) then
                     Bad_Use := True;
                     Note_Failure
                       (Code_Unknown_Option,
                        Output_Conflict
                          ("stage report", Stage_Path, Path, "an artifact"));
                     return;
                  end if;
               end loop;
            end if;
            for Index in 1 .. Landin.Stages.Source_Count (Context) loop
               Source_Paths.Append
                 (Landin.Source.Name
                    (Landin.Stages.Source
                       (Context, Landin.Stages.Nth_Source (Context, Index))));
            end loop;
            if Report_Seen then
               for Path of Destinations loop
                  if Conflicts_With (Path) then
                     Bad_Use := True;
                     Note_Failure
                       (Code_Unknown_Option,
                        Output_Conflict
                          ("build report", Report_Path, Path, "an artifact"));
                     return;
                  end if;
               end loop;
               if Host.Paths_Overlap_Any (Report_Path, Source_Paths) then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     Source_Conflict
                       ("build report", Report_Path, Source_Paths));
                  return;
               end if;
            end if;
            if Stack_Report_Seen then
               for Path of Destinations loop
                  if Host.Paths_Overlap (Stack_Path, Path) then
                     Bad_Use := True;
                     Note_Failure
                       (Code_Unknown_Option,
                        Output_Conflict
                          ("stack report", Stack_Path, Path, "an artifact"));
                     return;
                  end if;
               end loop;
               if Host.Paths_Overlap_Any (Stack_Path, Source_Paths) then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     Source_Conflict
                       ("stack report", Stack_Path, Source_Paths));
                  return;
               end if;
            end if;

            for Index in Destinations.First_Index .. Destinations.Last_Index
            loop
               for Earlier in Destinations.First_Index .. Index - 1 loop
                  if Host.Paths_Overlap
                    (Destinations (Index), Destinations (Earlier))
                  then
                     Bad_Use := True;
                     Note_Failure
                       (Code_Unknown_Option,
                        Output_Conflict
                          ("artifact", Destinations (Index),
                           Destinations (Earlier), "an artifact"));
                     return;
                  end if;
               end loop;
               if Host.Paths_Overlap_Any
                 (Destinations (Index), Source_Paths)
                 or else (Emit = Emit_Executable and then Debug_Enabled
                   and then (for some Path of Source_Paths =>
                     Landin.Backend.Toolchain.Debug_Overwrites
                       (Product_Path, Path, Facts, Host)))
               then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     Source_Conflict
                       ("artifact", Destinations (Index), Source_Paths));
                  return;
               end if;
            end loop;

            if On_Firmware and then not Firmware_Seen
              and then Emit = Emit_Assembly
            then
               for Index in 1 .. Landin.IR.Item_Count
                 (Landin.Stages.Code (Context).all)
               loop
                  if Landin.IR.Placement_Of
                    (Landin.Stages.Code (Context).all,
                     Landin.IR.Item_Id (Index)).Vector /= 0
                    or else Landin.IR.Placement_Of
                      (Landin.Stages.Code (Context).all,
                       Landin.IR.Item_Id (Index)).Vector_Present
                  then
                     Note_Failure
                       (Code_No_Entry, "vector placement requires an explicit"
                        & " --firmware-entry=NAME request");
                     return;
                  end if;
               end loop;
            end if;
            if On_Firmware
              and then (Emit = Emit_Executable or Firmware_Seen)
            then
               Firmware_Entry := Landin.Backend.Entry_Point.Firmware_Start
                 (Landin.Stages.Code (Context).all,
                  Landin.Stages.Meanings (Context).all,
                  Landin.Stages.Modules (Context).all,
                  Landin.Stages.Identities (Context).all,
                  Unbounded.To_String (Firmware_Name));
               if Firmware_Entry = Landin.IR.No_Item then
                  Note_No_Entry (For_Firmware => True);
                  return;
               end if;
               if not Landin.Configuration.Profile
                 (Landin.Stages.Configurations (Context).all).Present
               then
                  --  D543: no description reached, and no library holds
                  --  the reference.
                  Note_Failure
                    (Rows.Code (Rows.No_Description),
                     "firmware needs a device profile, and the program"
                     & " selects none: import the device's description, or"
                     & " name a library holding "
                     & Landin.Targets.Firmware.Reference_Module
                       (Facts, Landin.Targets.Levels.Name (Level))
                     & " with --library=DIR (D543)");
                  return;
               end if;
               --  D923: linker.library, linker.directory and -L name
               --  static archives and where they are, which the firmware
               --  link takes as a hosted link does.
            end if;

            --  A target nothing emits for cannot be asked for a file.
            --  `synthetic-32` exists to keep layout arithmetic honest on a
            --  64-bit host and has no backend, which is what
            --  Landin.Targets.Capabilities already says.
            if Landin.Targets.Capabilities.Backend_For (Facts)
               = Landin.Targets.Capabilities.No_Backend
            then
               Note_No_Toolchain
                 ("no backend emits for target "
                  & Landin.Targets.Name (Facts),
                  "describe a target with a backend, or drop --emit");
               return;
            end if;

            --  A backend named before its emitter: the program checks and
            --  lowers to IR, and nothing that would be linked is written.
            --  A profile's script is the description's, which no emitter
            --  writes (D686).
            if Emit in Emit_Assembly | Emit_Executable
              and then not Landin.Targets.Capabilities.Emits (Facts)
            then
               Note_No_Toolchain
                 ("no backend emits for target "
                  & Landin.Targets.Name (Facts) & " yet",
                  "check it with `refine check`, or lower it with"
                  & " --emit=ir");
               return;
            end if;

            --  D589: the profile's derived script, as a firmware build
            --  would write it beside its image, and nothing linked.
            --  Snapshot before producing replacements, but let pure semantic
            --  checks retain priority over an unwritable destination.  A
            --  deferred preparation failure is reported before any write.
            if not Dry_Run then
               for Path of Destinations loop
                  --  Existing dSYM leaves are protected by the whole bundle.
                  if not Debug_Leaves.Contains (Path) then
                     Reserve_Output (Path, Defer_Preparation_Failure => True);
                  end if;
               end loop;
               if Report_Seen then
                  Reserve_Output
                    (Report_Path, Defer_Preparation_Failure => True);
               end if;
               if Stack_Report_Seen then
                  Reserve_Output
                    (Stack_Path, Defer_Preparation_Failure => True);
               end if;
               if Bad_Use or else Stop_Requested then
                  return;
               end if;
            end if;

            if Emit = Emit_Linker_Script then
               if not Landin.IR.Firmware_Profile
                 (Landin.Stages.Code (Context).all).Present
               then
                  Note_Failure
                    (Rows.Code (Rows.No_Description),
                     "a linker script is a device profile's, and the"
                     & " program selects none: import the device's"
                     & " description, or name a library holding "
                     & Landin.Targets.Firmware.Reference_Module
                       (Facts, Landin.Targets.Levels.Name (Level))
                     & " with --library=DIR (D543)");
                  return;
               elsif Dry_Run then
                  Unbounded.Append (Result.Output,
                    "write " & Landin.Json.Quoted (Assembly_Path) & LF);
                  return;
               end if;
               Report_Publication_Failure;
               if Publication_Failed then
                  return;
               end if;
               Write_Output
                 (Assembly_Path,
                  Landin.Backend.Firmware.Linker_Script
                    (Landin.IR.Firmware_Profile
                       (Landin.Stages.Code (Context).all),
                     Landin.Backend.Firmware.Used_Regions
                       (Landin.Stages.Code (Context).all,
                        Landin.Stages.Identities (Context).all),
                     Archives => Landin.Configuration.Library_Count
                       (Landin.Stages.Configurations (Context).all) > 0),
                  Written);
               if Written /= Landin.Platform.Write_Ok then
                  Note_Failure
                    (Code_Unwritable, Write_Failure (Assembly_Path));
                  return;
               end if;
               Write_Build_Report;
               return;
            end if;

            --  D537: every static image against one budget before
            --  anything is emitted, so a few lines of source cannot ask
            --  the assembler for more than the image could hold: a
            --  firmware image's profile, or the target's reach.
            if Emit in Emit_Assembly | Emit_Executable then
               declare
                  package Images renames Landin.Backend.Images;
                  use type Images.Excess;
                  Firmware : constant Boolean :=
                    On_Firmware
                    and then (Emit = Emit_Executable or Firmware_Seen);
                  Budget : constant Landin.Targets.Image_Budget :=
                    (if Firmware then Landin.Targets.Firmware.Budget
                       (Landin.IR.Firmware_Profile
                          (Landin.Stages.Code (Context).all))
                     else Landin.Targets.Capabilities.Image_Budget_Of
                       (Facts));
                  Used : constant Images.Usage :=
                    Images.Measure (Landin.Stages.Code (Context).all, Facts);
                  Over : constant Images.Excess :=
                    Images.Exceeded (Used, Budget);
               begin
                  if Over /= Images.Within then
                     declare
                        Profile : constant String :=
                          Landin.Targets.Name (Facts) & "'s "
                          & Landin.Targets.Firmware.Profile_Name
                              (Landin.IR.Firmware_Profile
                                 (Landin.Stages.Code (Context).all));
                        Refused : Landin.Diagnostics.Diagnostic :=
                          Landin.Diagnostics.Make
                            (Code    => Rows.Code
                                          (Rows.Image_Budget_Exceeded),
                             Level   => Landin.Diagnostics.Error,
                             Source  => Landin.Source.No_Source,
                             Where   => Landin.Source.Empty_Span,
                             Message => Images.Refusal
                               (Used, Budget, Over,
                                (case Over is
                                    when Images.Reserved =>
                                       Landin.Targets.Name (Facts)
                                       & "'s address space holds",
                                    when Images.Writable =>
                                       (if Firmware
                                        then "the RAM of " & Profile
                                          & " holds"
                                        else Landin.Targets.Capabilities
                                          .Image_Reach_Source (Facts)),
                                    when others =>
                                       (if Firmware
                                        then (if Selected_Layout =
                                          Landin.Targets.Firmware.RAM_Layout
                                          then "the RAM of "
                                          else "the flash of ")
                                          & Profile
                                          & " holds"
                                        else Landin.Targets.Capabilities
                                          .Image_Reach_Source (Facts)))));
                     begin
                        Landin.Diagnostics.Add_Note
                          (Refused,
                           (if Selected_Layout =
                             Landin.Targets.Firmware.RAM_Layout
                            then "RAM layout capacity exceeded; use"
                              & " --firmware-layout=boot for the board boot"
                              & " check. " else "") &
                           "every image the program lowers counts before"
                           & " section GC; make the static data smaller,"
                           & " or allocate it when the program runs (D537)");
                        Landin.Stages.Report (Context, Refused);
                     end;
                     return;
                  end if;
               end;
            end if;

            --  [1970]'s entry is required before anything is written, so a
            --  program that could never be linked does not leave a file
            --  behind on the way to saying so.
            if Emit = Emit_Executable and then not On_Firmware
              and then Landin.Backend.Entry_Point.Hosted_Main
                         (Landin.Stages.Code (Context).all,
                          Landin.Stages.Meanings (Context).all,
                          Landin.Stages.Modules (Context).all,
                          Landin.Stages.Identities (Context).all)
                       = Landin.IR.No_Item
            then
               Note_No_Entry;
               return;
            elsif Emit = Emit_Assembly and then not On_Firmware
              and then Public_Main_Not_Entry
            then
               Note_No_Entry;
               return;
            end if;

            Landin.Build_Reports.Clear (Evidence);
            --  Lowering already verified this unit with Facts. The checks
            --  above only read it; each enabled pass verifies its output.
            Landin.IR.Pipeline.Run_On_Verified
              (Landin.Stages.Code (Context).all, Facts,
               Optimization, Evidence);
            if Stop_Requested then
               return;
            end if;

            --  Specialization can expose an additional atom domain. The
            --  selected source identity and source-byte spaces stay fixed;
            --  refresh physical atom codes against the final unit.
            Landin.Panics.Prepare (Context, Panic, Panic_Problem);
            if Unbounded.Length (Panic_Problem) /= 0 then
               raise Compiler_Defect with "panic plan changed after checking";
            end if;

            if Report_Seen then
               for Index in 1 .. Landin.IR.Nominal_Type_Count
                 (Landin.Stages.Code (Context).all)
               loop
                  declare
                     Unit : Landin.IR.Unit renames
                       Landin.Stages.Code (Context).all;
                     Id : constant Landin.IR.Nominal_Type_Id :=
                       Landin.IR.Nth_Nominal_Type (Unit, Index);
                  begin
                     if Landin.IR.Has_Nominal_Shape (Unit, Id) then
                        Landin.Build_Reports.Append_Layout
                          (Evidence, Index, Landin.IR.Layout_Of (Unit, Id),
                           Landin.Backend.Nominal_Layout (Unit, Id, Facts));
                     end if;
                  end;
               end loop;
            end if;

            --  A verified frame may still exceed the displacement encoding
            --  of this backend.  Ask before anything is written, for
            --  [1970]'s reason above.
            declare
               Unit : Landin.IR.Unit renames
                 Landin.Stages.Code (Context).all;
               Known : Landin.Resolution.Table renames
                 Landin.Stages.Meanings (Context).all;
               Spellings : Landin.Source.Names.Table renames
                 Landin.Stages.Identities (Context).all;
               Refused : Boolean := False;
               --  The selected firmware profile's stack, 4 KiB in
               --  [1990]'s reference profile.
               Stack_Bytes : constant Landin.Targets.Byte_Count :=
                 Landin.IR.Firmware_Profile (Unit).Stack_Size;
               use type Landin.Targets.Byte_Count;
               Stack_Words : constant String :=
                 (if Stack_Bytes mod 1024 = 0
                  then Ada.Strings.Fixed.Trim
                    (Landin.Targets.Byte_Count'Image (Stack_Bytes / 1024),
                     Ada.Strings.Both) & " KiB"
                  else Ada.Strings.Fixed.Trim
                    (Landin.Targets.Byte_Count'Image (Stack_Bytes),
                     Ada.Strings.Both) & "-byte");
            begin
               for Index in 1 .. Landin.IR.Item_Count (Unit) loop
                  declare
                     Item : constant Landin.IR.Item_Id :=
                       Landin.IR.Item_Id (Index);
                  begin
                     if Landin.IR.Kind_Of (Unit, Item) = Landin.IR.Routine
                       and then not
                         Landin.Backend.Dispatch.Frame_Is_Addressable
                                      (Unit, Item, Facts, Optimization)
                     then
                        Note_Failure
                          (Code_Wide_Frame,
                           "`"
                           & Landin.Source.Names.Spelling
                               (Spellings,
                                Landin.Resolution.Name_Of
                                  (Known,
                                   Landin.IR.Declares (Unit, Item)))
                           & "` needs a frame outside the "
                           & Landin.Backend.Dispatch.Frame_Limit (Facts));
                        Refused := True;
                     elsif Landin.IR.Kind_Of (Unit, Item) = Landin.IR.Routine
                       and then Firmware_Entry /= Landin.IR.No_Item
                       and then not Landin.Backend.Dispatch
                         .Frame_Fits_Firmware_Stack (Unit, Item, Facts)
                     then
                        Note_Failure
                          (Code_Firmware_Frame,
                           "`"
                           & Landin.Source.Names.Spelling
                               (Spellings,
                                Landin.Resolution.Name_Of
                                  (Known,
                                   Landin.IR.Declares (Unit, Item)))
                           & "` has a frame larger than the selected "
                           & Stack_Words
                           & " firmware stack reservation");
                        Refused := True;
                     end if;
                  end;
               end loop;

               if Refused then
                  return;
               end if;
            end;

            --  A static Linux link has no C library, so a program
            --  that needs one is refused here, by name, rather than by the
            --  linker's undefined references.  Its process entry is
            --  platform/linux's, so assembly or IR for one without it is
            --  refused too, rather than written without it (D363).
            if Emit /= Emit_Nothing and then Static_Link
              and then Refused_Static_Link
                (Executable => Emit = Emit_Executable)
            then
               return;
            end if;

            --  D365: the IR the backend would be given, in Landin.IR.Dump's
            --  text, and nothing after it.
            if Emit = Emit_IR then
               if Dry_Run then
                  Unbounded.Append (Result.Output,
                    "write " & Landin.Json.Quoted (Assembly_Path) & LF);
                  return;
               end if;
               Report_Publication_Failure;
               if Publication_Failed then
                  return;
               end if;
               declare
                  --  D374's answer, as every backend gives it, so the dump
                  --  says which entries an emitted table names.
                  Entries : constant Landin.Backend.Kept_Entries :=
                    Landin.Backend.Kept_Evidence_Entries
                      (Landin.Stages.Code (Context).all,
                       Landin.Panics.Handler (Panic),
                       Landin.Stages.Meanings (Context).all,
                       Landin.Stages.Identities (Context).all);

                  function Is_Kept
                    (Id : Landin.IR.Evidence_Id; Which : Positive)
                     return Boolean
                  is (Landin.Backend.Is_Kept (Entries, Id, Which));
               begin
                  Write_Output
                    (Assembly_Path,
                     (if Annotated_IR then
                        "request target=" & Landin.Targets.Name (Facts)
                        & " level=" & Landin.Targets.Levels.Name (Level)
                        & " optimize=" & Landin.Optimization.Spelling
                          (Optimization.Optimize)
                        & " specialize=" & Landin.Optimization.Spelling
                          (Optimization.Specialize) & LF
                      else "")
                     & Landin.IR.Dump.Text
                       (Landin.Stages.Code (Context).all,
                        Landin.Stages.Meanings (Context).all,
                        Landin.Stages.Identities (Context).all,
                        With_Metadata => Annotated_IR,
                        Kept => Is_Kept'Access,
                        With_Provenance => Annotated_IR),
                     Written);
               end;
               if Written /= Landin.Platform.Write_Ok then
                  Note_Failure
                    (Code_Unwritable, Write_Failure (Assembly_Path));
                  return;
               end if;
               Write_Build_Report;
               return;
            end if;

            --  The program needs nothing it cannot have; whether the host
            --  can link it is asked now, before anything is written.
            if Emit = Emit_Executable and then not Dry_Run then
               Chosen_Driver := Unbounded.To_Unbounded_String
                 (Available_Driver);
               if Unbounded.Length (Chosen_Driver) = 0 then
                  Note_Unavailable_Toolchain
                    (if Candidates.Is_Empty then ""
                     else Candidates.First_Element);
                  return;
               end if;
            end if;

            declare
               Emitted : Unbounded.Unbounded_String;
               Debug : aliased Landin.Debugging.Information
                 (Landin.Stages.Trees (Context),
                  Landin.Stages.Sources (Context));
            begin
               if Debug_Enabled then
                  Landin.Debugging.Set_Directory
                    (Debug, Host.Working_Directory);
                  for Index in 1 .. Landin.Stages.Source_Count (Context) loop
                     Landin.Debugging.Append
                       (Debug, Landin.Stages.Source
                          (Context, Landin.Stages.Nth_Source
                            (Context, Index)),
                        Recorded => Landin.Source_Maps.Recorded_Name
                          (Context, Landin.Stages.Nth_Source
                             (Context, Index)));
                  end loop;
                  for Index in 1 .. Landin.Checking.Declaration_Limit
                    (Landin.Stages.Types (Context).all)
                  loop
                     declare
                        Binding : constant Landin.Checking.Declaration_Id :=
                          Landin.Checking.Declaration_Id (Index);
                        Shape : constant Landin.Checking.Signature_Id :=
                          Landin.Checking.Result_Shape_Of
                            (Landin.Stages.Types (Context).all, Binding);
                     begin
                        if Shape /= Landin.Checking.No_Signature then
                           for Field in 1 ..
                             Landin.Checking.Signature_Result_Count
                               (Landin.Stages.Types (Context).all, Shape)
                           loop
                              Landin.Debugging.Append_Result_Name
                                (Debug, Binding,
                                 Landin.Checking.Nth_Signature_Result
                                   (Landin.Stages.Types (Context).all,
                                    Shape, Field).Name);
                           end loop;
                        end if;
                     end;
                  end loop;
               end if;
               Landin.Backend.Dispatch.Emit
                 (Landin.Stages.Code (Context).all,
                  Landin.Stages.Meanings (Context).all,
                  Landin.Stages.Identities (Context).all,
                  Landin.Stages.Target (Context),
                  Landin.Stages.Level (Context),
                  Optimization, Emitted, Evidence,
                  Hosted_Entry => Landin.Backend.Entry_Point.Hosted_Main
                    (Landin.Stages.Code (Context).all,
                     Landin.Stages.Meanings (Context).all,
                     Landin.Stages.Modules (Context).all,
                     Landin.Stages.Identities (Context).all),
                  Debug => (if Debug_Enabled then Debug'Access else null),
                  Firmware_Entry => Firmware_Entry, Panic => Panic'Access);
               --  D474: a selected handler runs on the margin of the
               --  stack that overflowed, which only the emitted frames
               --  measure; one that does not fit is refused before
               --  anything is written.
               declare
                  Fit : constant
                    Landin.Build_Reports.Stacks.Handler_Fit :=
                      Landin.Build_Reports.Stacks.Fit_Handler
                        (Evidence, Context, Optimization, Panic,
                         Landin.Backend.Entry_Point.Hosted_Main
                           (Landin.Stages.Code (Context).all,
                            Landin.Stages.Meanings (Context).all,
                            Landin.Stages.Modules (Context).all,
                            Landin.Stages.Identities (Context).all));
               begin
                  if Fit.Refused then
                     Landin.Stages.Report
                       (Context,
                        Landin.Diagnostics.Make
                          (Code    => Code_Handler_Margin,
                           Level   => Landin.Diagnostics.Error,
                           Source  => Fit.Site.Source,
                           Where   => Fit.Site.Where,
                           Message => Unbounded.To_String
                             (Fit.Message)));
                     return;
                  end if;
               end;
               Report_Publication_Failure;
               if Publication_Failed or else Stop_Requested then
                  return;
               end if;
               if Emit_Map then
                  declare
                     Map : constant Landin.Source_Maps.Artifact :=
                       Landin.Source_Maps.Create
                         (Context, Emitted,
                          All_Sources => Debug_Enabled,
                          Panic => (if Panic_Map then Panic'Access else null),
                          Digests => Digests'Access);
                  begin
                     Map_Id := Unbounded.To_Unbounded_String (Map.Build_Id);
                     Map_JSON := Map.JSON;
                  end;
               end if;
               if Dry_Run then
                  for Path of Destinations loop
                     Unbounded.Append (Result.Output,
                       "write " & Landin.Json.Quoted (Path) & LF);
                  end loop;
                  if Report_Seen then
                     Unbounded.Append (Result.Output,
                       "write " & Landin.Json.Quoted (Report_Path) & LF);
                  end if;
                  if Stage_Report_Seen then
                     Unbounded.Append (Result.Output,
                       "write " & Landin.Json.Quoted (Stage_Path) & LF);
                  end if;
                  if Stack_Report_Seen then
                     Unbounded.Append (Result.Output,
                       "write " & Landin.Json.Quoted (Stack_Path) & LF);
                  end if;
                  if Emit = Emit_Executable then
                     declare
                        Driver : constant String := Planned_Driver;
                        Libraries : Landin.Platform.Path_List;
                        procedure Plan_Tool
                          (Arguments : Landin.Platform.Path_List);
                        procedure Plan_Tool
                          (Arguments : Landin.Platform.Path_List)
                        is
                        begin
                           Unbounded.Append (Result.Output,
                             "run [" & Landin.Json.Quoted (Driver));
                           for Argument of Arguments loop
                              Unbounded.Append (Result.Output,
                                "," & Landin.Json.Quoted (Argument));
                           end loop;
                           Unbounded.Append (Result.Output, "]" & LF);
                        end Plan_Tool;
                     begin
                        for Index in 1 .. Landin.Configuration.Library_Count
                          (Landin.Stages.Configurations (Context).all)
                        loop
                           Libraries.Append
                             (Landin.Configuration.Library_Name
                                (Landin.Stages.Configurations (Context).all,
                                 Index));
                        end loop;
                        if On_Firmware then
                           Plan_Tool
                          (Landin.Backend.Toolchain.Assemble_Arguments
                             (Assembly_Path, Product_Path & ".o", Facts,
                              Debug => Debug_Enabled,
                              Level => Landin.Stages.Level (Context),
                              Float => Landin.IR.Firmware_Profile
                                (Landin.Stages.Code (Context).all).Float));
                        end if;
                        Plan_Tool (Landin.Backend.Toolchain.Link_Arguments
                          (Assembly => Assembly_Path,
                           Output => Product_Path,
                           Linker => Unbounded.To_String (Linker),
                           Libraries => Libraries, Facts => Facts,
                           Full_Debug => Debug_Enabled,
                           Build_Id => Unbounded.To_String (Map_Id),
                           Level => Landin.Stages.Level (Context),
                           Static => Static_Link,
                           Directories => Search_Directories,
                           Float => Landin.IR.Firmware_Profile
                             (Landin.Stages.Code (Context).all).Float));
                        if not Keep_Assembly and then not On_Firmware
                          and then not Emit_Map
                        then
                           Unbounded.Append (Result.Output,
                             "remove " & Landin.Json.Quoted (Assembly_Path)
                             & LF);
                        end if;
                     end;
                  end if;
                  return;
               end if;

               if Emit = Emit_Executable then
                  Check_Assembly_Text
                    (Unbounded.To_String (Emitted), Assembly_Path, 0,
                     Emitted => True);
                  if Landin.Stages.Failed (Context) then
                     return;
                  end if;
               end if;
               Write_Output
                 (Assembly_Path, Unbounded.To_String (Emitted), Written);
               if Written /= Landin.Platform.Write_Ok then
                  Note_Failure
                    (Code_Unwritable, Write_Failure (Assembly_Path));
                  return;
               end if;
               if Emit = Emit_Executable and then not On_Firmware
                 and then not Keep_Assembly and then not Emit_Map
               then
                  Intermediate_Assembly :=
                    Unbounded.To_Unbounded_String (Assembly_Path);
               end if;
               if Emit_Map then
                  Write_Output
                    (Map_Path, Unbounded.To_String (Map_JSON), Written);
                  if Written /= Landin.Platform.Write_Ok then
                     Note_Failure
                       (Code_Unwritable, Write_Failure (Map_Path));
                     return;
                  end if;
               end if;
            end;

            if Emit /= Emit_Executable then
               Write_Build_Report;
               Write_Stack_Report;
               return;
            end if;

            Link_Assembly
              (Private_Path (Assembly_Path), Product_Path,
               Unbounded.To_String (Map_Id),
               Destinations);
            Write_Build_Report;
            Write_Stack_Report;
         end Emit_Requested;

         --  D383: what a check says beyond the program's acceptance when
         --  it is asked: that the firmware entry named is one, and the
         --  build report of what was checked, its sources and items, with
         --  no evidence only emission makes.
         procedure Check_Requested;
         procedure Check_Requested is
            Report_Path : constant String :=
              Unbounded.To_String (Build_Report_Path);
            Source_Paths : Landin.Platform.Path_List;
            Written : Landin.Platform.Write_Status;
            Evidence : Landin.Build_Reports.Report;
         begin
            if Firmware_Seen
              and then Landin.Targets.Is_Firmware (Facts)
              and then Landin.Backend.Entry_Point.Firmware_Start
                (Landin.Stages.Code (Context).all,
                 Landin.Stages.Meanings (Context).all,
                 Landin.Stages.Modules (Context).all,
                 Landin.Stages.Identities (Context).all,
                 Unbounded.To_String (Firmware_Name)) = Landin.IR.No_Item
            then
               Note_No_Entry (For_Firmware => True);
               return;
            end if;
            --  What compiling it would refuse before the link, a check
            --  refuses too: a `public main` that is not the entry, and a
            --  static link's C symbol.
            if not Landin.Targets.Is_Firmware (Facts)
              and then Public_Main_Not_Entry
            then
               Note_No_Entry;
               return;
            end if;
            Result.Without_Entry :=
              Landin.Targets.Capabilities.Hosted_System_Of (Facts)
                /= Landin.Targets.Capabilities.No_Hosted_System
              and then Landin.Backend.Entry_Point.Hosted_Main
                (Landin.Stages.Code (Context).all,
                 Landin.Stages.Meanings (Context).all,
                 Landin.Stages.Modules (Context).all,
                 Landin.Stages.Identities (Context).all)
                   = Landin.IR.No_Item;
            if Static_Link
              and then Refused_Static_Link
                (Executable => True, Checking => True)
            then
               return;
            end if;
            --  D572: a handler that would not fit the margin of a stack
            --  the program prepares is refused here as compiling refuses
            --  it, from the frames the backend emits at this profile.
            Checking.Fit_Handler
              (Context, Panic, Optimization,
               (if Firmware_Seen then Unbounded.To_String (Firmware_Name)
                else ""));
            if Landin.Stages.Failed (Context) then
               return;
            end if;
            if not Report_Seen or else Dry_Run then
               return;
            end if;
            for Index in 1 .. Landin.Stages.Source_Count (Context) loop
               Source_Paths.Append
                 (Landin.Source.Name
                    (Landin.Stages.Source
                       (Context, Landin.Stages.Nth_Source (Context, Index))));
            end loop;
            if Host.Paths_Overlap_Any (Report_Path, Source_Paths) then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option,
                  Source_Conflict
                    ("build report", Report_Path, Source_Paths));
               return;
            end if;
            Landin.Build_Reports.Clear (Evidence);
            Write_Output
              (Report_Path,
               Landin.Build_Reports.Sources.JSON
                 (Evidence, Context, Optimization,
                  Link =>
                    (if Landin.Targets.Capabilities.Hosted_System_Of (Facts)
                          = Landin.Targets.Capabilities.No_Hosted_System
                     then ""
                     elsif Static_Link then "static" else "libc")),
               Written);
            if Written /= Landin.Platform.Write_Ok then
               Note_Failure (Code_Unwritable, Write_Failure (Report_Path));
            end if;
         end Check_Requested;

         --  D362: `refine compile prog.s -o prog` links an assembly file
         --  through the same driver, arguments and output protection as a
         --  compiled program.  Nothing is compiled, so nothing is read but
         --  the operand, and the driver reads that.
         procedure Link_Operand;
         procedure Link_Operand is
            Operand : constant String := Inputs.First_Element;
            Product : constant String :=
              (if Unbounded.Length (Output) > 0
               then Unbounded.To_String (Output)
               else Default_Executable);
            On_Firmware : constant Boolean :=
              Landin.Targets.Is_Firmware (Facts);
            Destinations, Debug_Leaves : Landin.Platform.Path_List;
            Separate_Debug_Object : constant Boolean := Debug_Enabled
              and then Landin.Targets.Capabilities.Backend_For (Facts)
                = Landin.Targets.Capabilities.Darwin_Arm64_Mach_O;
         begin
            Destinations.Append (Product);
            if On_Firmware then
               Destinations.Append (Product & ".o");
               Destinations.Append (Product & ".ld");
               Destinations.Append (Product & ".map");
            end if;
            if Debug_Enabled then
               for Path of Landin.Backend.Toolchain.Debug_Artifacts
                 (Product, Facts, Host)
               loop
                  Destinations.Append (Path);
                  if Path /= Product & ".o"
                    and then Path /= Product & ".dSYM"
                  then
                     Debug_Leaves.Append (Path);
                  end if;
               end loop;
               if Landin.Backend.Toolchain.Debug_Overwrites
                 (Product, Operand, Facts, Host)
               then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "debug artifact collides with source: " & Product
                     & "; choose another output path");
                  return;
               end if;
            end if;
            for Path of Destinations loop
               if Host.Paths_Overlap (Path, Operand) then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     Source_Conflict ("artifact", Path, [Operand]));
                  return;
               end if;
            end loop;
            if not Host.Exists (Operand) then
               Note_Failure (Code_Unreadable, "source not found: " & Operand);
               return;
            end if;
            --  D524: `-L` is refused wherever a library is; firmware
            --  links archives (D923), so only a static Linux link does.
            if not Search_Options.Is_Empty and then Static_Link then
               Note_No_Toolchain
                 ("a static link of " & Landin.Targets.Name (Facts)
                  & " links no C library, so it searches no directory: -L "
                  & Search_Options.First_Element,
                  "link with --link=libc, which keeps C's runtime"
                  & " and library");
               return;
            end if;
            if Dry_Run then
               declare
                  procedure Plan_Tool
                    (Arguments : Landin.Platform.Path_List;
                     Program : String := Planned_Driver);
                  procedure Plan_Tool
                    (Arguments : Landin.Platform.Path_List;
                     Program : String := Planned_Driver)
                  is
                  begin
                     Unbounded.Append (Result.Output,
                       "run [" & Landin.Json.Quoted (Program));
                     for Argument of Arguments loop
                        Unbounded.Append (Result.Output,
                          "," & Landin.Json.Quoted (Argument));
                     end loop;
                     Unbounded.Append (Result.Output, "]" & LF);
                  end Plan_Tool;
               begin
                  Unbounded.Append (Result.Output,
                    "write " & Landin.Json.Quoted (Product) & LF);
                  if On_Firmware or else Separate_Debug_Object then
                     Plan_Tool
                       (Landin.Backend.Toolchain.Assemble_Arguments
                          (Operand, Product & ".o", Facts,
                           Debug => Debug_Enabled,
                           Level => Landin.Stages.Level (Context)));
                  end if;
                  Plan_Tool (Landin.Backend.Toolchain.Link_Arguments
                    (Assembly => (if Separate_Debug_Object
                                  then Product & ".o" else Operand),
                     Output => Product,
                     Linker => Unbounded.To_String (Linker),
                     Facts => Facts, Full_Debug => Debug_Enabled,
                     Level => Landin.Stages.Level (Context),
                     Static => Static_Link,
                     Directories => Search_Directories,
                     Assembly_Is_Object => Separate_Debug_Object));
                  if Separate_Debug_Object then
                     Plan_Tool
                       (Landin.Backend.Toolchain.Debug_Bundle_Arguments
                          (Product, Product & ".dSYM"),
                        Landin.Backend.Toolchain.Darwin_Debug_Bundle_Tool);
                  end if;
               end;
               return;
            end if;
            Chosen_Driver := Unbounded.To_Unbounded_String (Available_Driver);
            if Unbounded.Length (Chosen_Driver) = 0 then
               Note_Unavailable_Toolchain
                 (if Candidates.Is_Empty then ""
                  else Candidates.First_Element);
               return;
            end if;
            if Separate_Debug_Object and then not Tools.Available
              (Landin.Backend.Toolchain.Darwin_Debug_Bundle_Tool)
            then
               Note_Unavailable_Debug_Bundle;
               return;
            end if;
            Read_External_Input (Operand, True, 0);
            if Landin.Stages.Failed (Context) then
               return;
            end if;
            for Path of Destinations loop
               if not Debug_Leaves.Contains (Path) then
                  Reserve_Output (Path);
               end if;
            end loop;
            if not Publication_Failed then
               Link_Assembly
                 (Operand, Product, "", Destinations, Separate_Debug_Object);
            end if;
         end Link_Operand;

         --  D383: rooted operands that are the entry module's source
         --  files rather than its directory.
         Rooted_Files : constant Boolean :=
           not Roots.Is_Empty and then not Inputs.Is_Empty
           and then (for all Path of Inputs =>
                       Loading.Is_Source_Name (Path)
                       and then not Host.Is_Directory (Path));

         --  Whether the one operand is assembly to link, and if not, why
         --  an assembly operand cannot be what this request means.
         Assembly_Operand : constant Boolean :=
           Emit = Emit_Executable and then Roots.Is_Empty
           and then Natural (Inputs.Length) = 1
           and then Is_Assembly_Operand (Inputs.First_Element);

         function Operand_Problem return String;
         function Operand_Problem return String is
            Named_Assembly : Boolean := False;
         begin
            for Path of Inputs loop
               Named_Assembly := Named_Assembly
                 or else Is_Assembly_Operand (Path);
            end loop;
            if not Named_Assembly then
               return "";
            elsif Emit /= Emit_Executable then
               return "an assembly operand is linked, which --emit=exe asks"
                 & " for; Landin source is what is checked or emitted";
            elsif not Assembly_Operand then
               return "an assembly operand is linked alone, without --root"
                 & " or another operand";
            end if;
            declare
               Described : constant String :=
                 (if Report_Seen then "--build-report"
                  elsif Stage_Report_Seen then "--stage-report"
                  elsif Stack_Report_Seen then "--stack-report"
                  elsif Panic_Map then "--panic-map"
                  elsif Depfile /= "" then "--depfile"
                  elsif Firmware_Seen then "--firmware-entry"
                  elsif Keep_Assembly then "--keep-asm"
                  elsif not Options.Is_Empty then "--option"
                  elsif not Modes.Is_Empty then "--build-mode"
                  elsif Optimize_Seen then "--optimize"
                  elsif Specialize_Seen then "--specialize"
                  else "");
            begin
               return (if Described = "" then ""
                       else Described & " describes compiling Landin source,"
                         & " and an assembly operand is linked as it is"
                         & " written");
            end;
         end Operand_Problem;

      begin
         Protect_Tool_Inputs (Planned_Driver);
         for Position in 1 .. Natural (Protected_Inputs.Length) loop
            if Position <= Natural (Protected_Identities.Length) then
               Observed_Input
                 (Protected_Inputs (Position),
                  Protected_Identities (Position));
            end if;
            Protect_Input (Protected_Inputs (Position));
         end loop;
         for Path of Inputs loop
            Protect_Input (Path);
         end loop;
         if Script_Seen then
            Protect_Input (Unbounded.To_String (Script_Path));
         end if;
         Check_Dependency_Path (Depfile);
         Check_Dependency_Path (Unbounded.To_String (Output));
         Check_Make_Path (Unbounded.To_String (Output), Target => True);
         Check_Dependency_Path (Unbounded.To_String (Build_Report_Path));
         Check_Dependency_Path (Unbounded.To_String (Stage_Report_Path));
         Check_Dependency_Path (Unbounded.To_String (Stack_Report_Path));
         for Path of Inputs loop
            Check_Dependency_Path (Path);
         end loop;
         for Path of Roots loop
            Check_Dependency_Path (Path);
         end loop;
         Check_Dependency_Path (Unbounded.To_String (Library_Path));
         for Mode of Modes loop
            if Natural (Modes.Length) /= 1
              or else Mode not in "debug" | "release"
            then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option,
                  "--build-mode needs one debug or release value");
               exit;
            end if;
            Landin.Configuration.Set_Mode
              (Landin.Stages.Configurations (Context).all,
               (if Mode = "debug" then Landin.Configuration.Debug
                else Landin.Configuration.Release));
         end loop;
         --  `compiler.c_runtime` is true on Linux exactly when the request
         --  keeps C's runtime; the other systems always link it.
         Landin.Configuration.Set_Firmware_Layout
           (Landin.Stages.Configurations (Context).all, Selected_Layout);
         Landin.Configuration.Set_C_Runtime
           (Landin.Stages.Configurations (Context).all,
            Link_Mode = Link_Libc);
         for Option of Options loop
            declare
               Separator : constant Natural :=
                 Ada.Strings.Fixed.Index (Option, "=");
               Valid : Boolean := Separator > Option'First
                 and then Separator < Option'Last;
               Config : constant not null access Landin.Configuration.Table :=
                 Landin.Stages.Configurations (Context);
            begin
               if Valid then
                  Valid := Landin.Configuration.Is_Option_Name
                    (Option (Option'First .. Separator - 1));
                  for Index in 1 .. Landin.Configuration.Override_Count
                    (Config.all)
                  loop
                     if Landin.Configuration.Override_Name
                       (Config.all, Index) = Option
                         (Option'First .. Separator - 1)
                     then
                        Valid := False;
                     end if;
                  end loop;
               end if;
               if Valid then
                  Landin.Configuration.Add_Override
                    (Config.all, Option (Option'First .. Separator - 1),
                     Option (Separator + 1 .. Option'Last));
               else
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "invalid or repeated build option: " & Option);
               end if;
            end;
         end loop;

         --  An unknown target leaves nothing to compile for, so the
         --  sources are not read: their reports would be about a
         --  compilation that never runs.
         for Name of Rejected loop
            Note_Failure
              (Code_Unknown_Target,
               "unknown target: " & Name & Nearest_Target (Name));
            Skip_Compilation := True;
         end loop;

         --  Without a description of its own host the compiler has nothing
         --  to compile for until --target= says.  A request that compiles
         --  nothing, --identify or --help, needs no target.
         if not Has_Default and then Targets.Is_Empty
           and then Natural (Inputs.Length) > 0
         then
            Note_Failure
              (Code_Unknown_Target,
               "no --target given, and no target describes this compiler's"
               & " host, " & Built_For);
         end if;

         if Unbounded.Length (Level_Problem) > 0 then
            Note_Failure
              (Code_Unknown_Level, Unbounded.To_String (Level_Problem));
         end if;

         for Option of Unknowns loop
            Note_Failure (Code_Unknown_Option, Option_Problem (Option));
         end loop;

         if Emit /= Emit_Executable then
            if Toolchain_Seen then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option, "--toolchain requires --emit=exe");
            end if;
            if Linker_Seen then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option, "--linker requires --emit=exe");
            end if;
         end if;

         if Unbounded.Length (Output_Problem) > 0 then
            Note_Failure
              (Code_Unknown_Option, Unbounded.To_String (Output_Problem));
         end if;

         --  A request to emit with nothing to compile exited zero and
         --  wrote nothing, which a script read as success.  An empty root
         --  named the filesystem root and searched it.
         if Natural (Inputs.Length) = 0
           and then (Emit /= Emit_Nothing
                     or else Unbounded.Length (Output) > 0)
         then
            Bad_Use := True;
            Note_Failure
              (Code_Unknown_Option,
               "--emit and -o need a source to compile");
         end if;

         for Root of Roots loop
            if Root'Length = 0 then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option, "--root= names no directory");
            end if;
         end loop;

         --  A library named on the command line replaces the one beside
         --  the compiler, so it has to be one: a directory that holds
         --  `core`.  Refused before anything is read, as a root is.
         if Library_Seen then
            declare
               Named : constant String := Unbounded.To_String (Library_Path);
            begin
               if Named = "" then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option, "--library= names no directory");
               elsif not Landin.Driver.Library.Holds_Library (Host, Named)
               then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "--library=" & Named & " holds no core, hosted or"
                     & " platform directory; name the directory that"
                     & " holds them");
               end if;
            end;
         end if;

         --  D524: an `-L` names a directory that exists, before any tool
         --  runs and before a source is read.
         for Directory of Search_Options loop
            Check_Dependency_Path (Directory);
            if Directory = "" then
               Bad_Use := True;
               Note_Failure (Code_Unknown_Option, "-L names no directory");
            elsif not Host.Is_Directory (Directory) then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option,
                  "-L " & Directory & " is not a directory; name the"
                  & " directory that holds the library, relative to the"
                  & " working directory or absolute");
            end if;
         end loop;

         --  -o names the file the artifact is written as.  A
         --  directory there is refused before anything is compiled, with
         --  the file under it the request most likely meant; publication
         --  would refuse it only after the whole build, in words that
         --  cannot say which option named it.
         if Emit /= Emit_Nothing and then Unbounded.Length (Output) > 0
           and then not Bad_Use
           and then Host.Is_Directory (Unbounded.To_String (Output))
         then
            declare
               Named : constant String := Unbounded.To_String (Output);
               Last : Natural := Named'Last;
               function Stem return String;
               function Stem return String is
                  Operand : constant String :=
                    (if Inputs.Is_Empty then "" else Inputs.First_Element);
                  Slash : Natural := Operand'Last;
                  Dot : Natural;
               begin
                  while Slash >= Operand'First
                    and then Operand (Slash) = '/'
                  loop
                     Slash := Slash - 1;
                  end loop;
                  declare
                     Trimmed : constant String :=
                       Operand (Operand'First .. Slash);
                     Base : constant String :=
                       Trimmed (Ada.Strings.Fixed.Index
                                  (Trimmed, "/", Ada.Strings.Backward) + 1
                                .. Trimmed'Last);
                  begin
                     Dot := Ada.Strings.Fixed.Index
                       (Base, ".", Ada.Strings.Backward);
                     if Dot > Base'First then
                        return Base (Base'First .. Dot - 1);
                     elsif Base /= "" and then Base (Base'First) /= '.' then
                        return Base;
                     end if;
                     return "a";
                  end;
               end Stem;
            begin
               while Last > Named'First and then Named (Last) = '/' loop
                  Last := Last - 1;
               end loop;
               Bad_Use := True;
               Note_Failure
                 (Code_Unwritable, "-o names the file to write, and "
                  & Named & " is a directory; name a file under it, for"
                  & " example -o " & Named (Named'First .. Last) & "/" & Stem
                  & (case Emit is
                       when Emit_Assembly => ".s",
                       when Emit_IR => ".ir",
                       when Emit_Linker_Script => ".ld",
                       when others => ""));
            end;
         end if;

         --  Diagnose unavailable parents before conservative overlap checks
         --  can mistake an unknown identity for a source/output collision.
         if Emit /= Emit_Nothing then
            Check_Output_Parent (Artifact_Output, "artifact output");
         end if;
         Check_Output_Parent (Depfile, "dependency report");
         Check_Output_Parent
           (Unbounded.To_String (Build_Report_Path), "build report");
         Check_Output_Parent
           (Unbounded.To_String (Stage_Report_Path), "stage report");
         Check_Output_Parent
           (Unbounded.To_String (Stack_Report_Path), "stack report");

         if Stage_Report_Seen then
            Check_Separate_Output
              ("stage report", Unbounded.To_String (Stage_Report_Path),
               Unbounded.To_String (Build_Report_Path));
            if Emit /= Emit_Nothing then
               Check_Separate_Output
                 ("stage report", Unbounded.To_String (Stage_Report_Path),
                  Artifact_Output);
            end if;
         end if;

         if Stack_Report_Seen then
            Check_Separate_Output
              ("stack report", Unbounded.To_String (Stack_Report_Path),
               Unbounded.To_String (Build_Report_Path));
            Check_Separate_Output
              ("stack report", Unbounded.To_String (Stack_Report_Path),
               Unbounded.To_String (Stage_Report_Path));
            if Emit /= Emit_Nothing then
               Check_Separate_Output
                 ("stack report", Unbounded.To_String (Stack_Report_Path),
                  Artifact_Output);
            end if;
         end if;

         --  D383: with roots, the operand is the entry module's directory
         --  or its source files, as without them.
         if Natural (Roots.Length) > 0
           and then (Natural (Inputs.Length) = 0
                     or else (Natural (Inputs.Length) > 1
                              and then not Rooted_Files))
         then
            Bad_Use := True;
            --  A file named beside a directory is how one reaches for
            --  adding a source to the directory's module, a file that
            --  imports a device description among them, and the files
            --  form is the way to do it.
            Note_Failure
              (Code_Unknown_Option,
               "a rooted request names one entry-module directory, or the"
               & " entry module's source files"
               & (if (for some Path of Inputs => Host.Is_Directory (Path))
                    and then (for some Path of Inputs =>
                                Loading.Is_Source_Name (Path)
                                and then not Host.Is_Directory (Path))
                  then "; to add a source file to a directory's module,"
                    & " name that directory's `.ldn` files in place of the"
                    & " directory"
                  else ""));
         end if;

         --  Target facts and emission options are known before any source
         --  is loaded.  A source error must not hide an incompatible request.
         if (Emit /= Emit_Nothing or else Firmware_Seen or else Layout_Seen
             or else Link_Seen)
           and then Rejected.Is_Empty
         then
            declare
               On_Firmware : constant Boolean :=
                 Landin.Targets.Is_Firmware (Facts);
            begin
               if Emit /= Emit_Nothing and then Debug_Enabled and then
                 (Landin.Targets.Capabilities.Debug_Format_Of (Facts)
                    = Landin.Targets.Capabilities.No_Debug_Format
                  or else Lines_Debug /= On_Firmware)
               then
                  Note_No_Toolchain
                    ((if Landin.Targets.Capabilities.Debug_Format_Of (Facts)
                            = Landin.Targets.Capabilities.No_Debug_Format
                      then "target " & Landin.Targets.Name (Facts)
                           & " has no source debug format"
                      else "unsupported source debugger mode for target "
                           & Landin.Targets.Name (Facts)),
                     (if Landin.Targets.Capabilities.Debug_Format_Of (Facts)
                            = Landin.Targets.Capabilities.No_Debug_Format
                      then "describe a target with a backend, or drop --emit"
                      elsif On_Firmware
                      then "use --debug=lines or --debug=none"
                      else "use --debug=full or --debug=none"));
                  Target_Option_Refused := True;
               elsif Layout_Seen and then not On_Firmware then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "--firmware-layout requires a firmware target: "
                     & Firmware_Targets);
                  Target_Option_Refused := True;
               elsif Firmware_Seen and then not On_Firmware then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "--firmware-entry requires a firmware target: "
                     & Firmware_Targets);
                  Target_Option_Refused := True;
               elsif Emit = Emit_Linker_Script and then not On_Firmware then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "--emit=linker-script writes a firmware profile's"
                     & " derived linker script, and "
                     & Landin.Targets.Name (Facts) & " has no firmware"
                     & " profile: it needs " & Firmware_Targets
                     & " (D589)");
                  Target_Option_Refused := True;
               elsif Script_Seen
                 and then (not On_Firmware or else Emit /= Emit_Executable
                           or else not Firmware_Seen)
               then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "--linker-script links firmware: it needs"
                     & " --target=cortex-m0 or --target=rv32,"
                     & " --firmware-entry=NAME and --emit=exe (D546)");
                  Target_Option_Refused := True;
               elsif Link_Seen
                 and then Landin.Targets.Capabilities.Hosted_System_Of (Facts)
                   = Landin.Targets.Capabilities.No_Hosted_System
               then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "--link chooses how a hosted executable is linked, and "
                     & Landin.Targets.Name (Facts) & " has no hosted system");
                  Target_Option_Refused := True;
               elsif Link_Mode = Link_Static
                 and then Landin.Targets.Capabilities.Hosted_System_Of (Facts)
                   /= Landin.Targets.Capabilities.Linux
               then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "--link=static needs a Linux target; "
                     & Landin.Targets.Name (Facts) & " reaches its system"
                     & " only through its C library, so it links with"
                     & " --link=libc, the default there");
                  Target_Option_Refused := True;
               end if;
            end;
         end if;

         if Target_Option_Refused then
            --  Explicit inputs are the complete source set.  A rooted
            --  request may reach imports not named here, so its report
            --  cannot be written safely without loading the program.
            if Stage_Report_Seen and then not Bad_Use
              and then Roots.Is_Empty
            then
               for Path of Inputs loop
                  if Host.Paths_Overlap
                    (Unbounded.To_String (Stage_Report_Path), Path)
                  then
                     Bad_Use := True;
                     Note_Failure
                       (Code_Unknown_Option,
                        Source_Conflict
                          ("stage report",
                           Unbounded.To_String (Stage_Report_Path), [Path]));
                     exit;
                  end if;
               end loop;
               Write_Stage_Report;
            end if;
            Result.Report := Unbounded.To_Unbounded_String
              (Render_Report);
            Keep_Report;
            Result.Status :=
              (if Bad_Use then Status_Misuse else Status_Reported);
            return Result;
         end if;

         if Operand_Problem /= "" then
            Bad_Use := True;
            Note_Failure (Code_Unknown_Option, Operand_Problem);
         end if;

         --  Informational actions and invalid requests wait for every
         --  command-line diagnostic, then return before reading sources.
         if Wants_Usage or else Wants_Identity or else Bad_Use then
            if Bad_Use or else Landin.Stages.Failed (Context) then
               Result.Report := Unbounded.To_Unbounded_String
                 (Render_Report);
               Keep_Report;
               Result.Status :=
                 (if Bad_Use then Status_Misuse else Status_Reported);
            else
               Result.Output := Unbounded.To_Unbounded_String
                 (if Wants_Usage then Usage else Identity);
            end if;
            return Result;
         end if;

         --  A target that names no driver is refused before any source is
         --  read.  Whether a named one is installed is asked only once the
         --  program is known to need one (D364): a static link that meets
         --  a C symbol is the program's refusal, and comes first (D364's
         --  order), before anything is written.
         if Emit = Emit_Executable
           and then not Dry_Run
           and then not Bad_Use
           and then not Landin.Stages.Failed (Context)
           and then Candidates.Is_Empty
         then
            Note_No_Toolchain
              ("target " & Landin.Targets.Name (Facts)
               & " names no toolchain",
               "name one with --toolchain=NAME");
            Skip_Compilation := True;
         end if;

         if Assembly_Operand and then not Skip_Compilation then
            Current_Stage := Unbounded.To_Unbounded_String ("emission");
            Link_Operand;
            Skip_Compilation := True;
         end if;

         if not Skip_Compilation then
            Current_Stage := Unbounded.To_Unbounded_String ("loading");
            Stage_Began;
            declare
               --  Asked for only now: a request refused before it reads a
               --  source never needs to know where the library is.
               Library_Root : constant String :=
                 (if Library_Seen then Unbounded.To_String (Library_Path)
                  else Landin.Driver.Library.Located (Host));
            begin
               if Natural (Roots.Length) > 0 and then Rooted_Files then
                  Loading.Load_Files
                    (Context, Host, Inputs, Observed_Input'Access);
                  if Landin.Stages.Source_Count (Context) > 0
                    and then not Landin.Stages.Failed (Context)
                  then
                     Loading.Load_Rooted_Imports
                       (Context, Host, Roots, Library_Root,
                        Dependency_Directories =>
                          (if Depfile /= ""
                           then Dependency_Directories'Access else null),
                        Implicit => Implicit_Module,
                        Parsing => Watch_Parsing'Access,
                        Observed => Observed_Input'Access);
                  end if;
               elsif Natural (Roots.Length) > 0 then
                  if Natural (Inputs.Length) = 1 then
                     Loading.Load_Reachable_Program
                       (Context, Host, Roots, Inputs.Element (1),
                        Dependency_Directories =>
                          (if Depfile /= ""
                           then Dependency_Directories'Access else null),
                        Library => Library_Root,
                        Implicit => Implicit_Module,
                        Parsing => Watch_Parsing'Access,
                        Observed => Observed_Input'Access);
                  end if;
               else
                  Loading.Load_Files
                    (Context, Host, Inputs, Observed_Input'Access);
                  --  Named files reach the library and nothing else, and
                  --  are parsed here to say what they import, as a rooted
                  --  request's modules are.  With no library found, an
                  --  import of it is refused here naming where refine
                  --  looked (D363), and any other as D262 says.
                  if Landin.Stages.Source_Count (Context) > 0
                    and then not Landin.Stages.Failed (Context)
                  then
                     Loading.Load_Library_Imports
                       (Context, Host, Library_Root,
                        Dependency_Directories =>
                          (if Depfile /= ""
                           then Dependency_Directories'Access else null),
                        Implicit => Implicit_Module,
                        Parsing => Watch_Parsing'Access,
                        Observed => Observed_Input'Access);
                  end if;
               end if;
            end;

            for Path of Dependency_Directories loop
               Check_Dependency_Path (Path);
               Check_Make_Path (Path);
            end loop;
            for Index in 1 .. Landin.Stages.Source_Count (Context) loop
               Check_Dependency_Path
                 (Landin.Source.Name (Landin.Stages.Source
                    (Context, Landin.Stages.Nth_Source (Context, Index))));
               Check_Make_Path
                 (Landin.Source.Name (Landin.Stages.Source
                    (Context, Landin.Stages.Nth_Source (Context, Index))));
            end loop;

            --  A rooted request scans and parses each module as it is found,
            --  to read its imports; Stage_Ended moves that time from this row
            --  to the syntax row.  A module refused while loading parsed it
            --  still ends the pipeline before its syntax stage, so the
            --  parsing it did is that stage's row.
            Stage_Ended ("loading");
            if Landin.Stages.Failed (Context) and then Parse_Microseconds > 0
            then
               Stage_Began;
               Stage_Ended ("syntax");
            end if;

            --  An empty module is legal, but it supplies nothing to emit.
            --  Keep the check-only request legal and refuse emission before
            --  any existing output at the requested path can appear current.
            if Natural (Roots.Length) > 0
              and then Landin.Stages.Source_Count (Context) = 0
              and then not Bad_Use
              and then not Landin.Stages.Failed (Context)
            then
               if Emit = Emit_Executable then
                  Note_No_Entry
                    (For_Firmware => Landin.Targets.Is_Firmware (Facts));
               elsif Emit = Emit_Assembly then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option, "--emit needs a source to compile");
               end if;
            end if;

            --  Every source that was read is scanned and parsed together, as
            --  one compilation: the language is checked whole, and a stage
            --  that saw one file at a time could not be replaced later by one
            --  that resolves a name across two.
            if Landin.Stages.Source_Count (Context) > 0
              and then not Landin.Stages.Failed (Context)
            then
               --  `refine run` holds its private directory from before
               --  the first stage, so a signal during them is recorded,
               --  and it is answered where one stage hands over to the
               --  next: no later stage runs, and nothing below reads what
               --  those stages would have made.
               declare
                  Stopped : Boolean;
               begin
                  Checking.Run
                    (Context, Panic, Watch_Stage'Access,
                     Frontend_Stop'Access, Stopped);
                  if Stopped or else Host.Cancellation_Requested then
                     Cancelled := True;
                  end if;
               end;
               Policy_Denied := Landin.Diagnostics.Warning_Policy.Denied
                 (Warnings, Landin.Stages.Report (Context));
               if not Cancelled and then not Landin.Stages.Failed (Context)
               then
                  Check_Directories;
               end if;

               --  The backend runs on nothing that was refused, for the same
               --  reason the lowering does: an unaccepted program has no Unit
               --  worth emitting, and a file written from one would be a
               --  plausible artefact of a failed compilation.
               if Emit /= Emit_Nothing
                 and then not Policy_Denied
                 and then not Bad_Use
                 and then not Cancelled
                 and then not Landin.Stages.Failed (Context)
               then
                  Current_Stage := Unbounded.To_Unbounded_String ("emission");
                  Stage_Began;
                  Emit_Requested;
                  --  D362: the assembly was the link's input and nothing
                  --  else's, whether the link succeeded or not.  A source
                  --  map beside the executable names it by its hash and is
                  --  resolved against it, so the two stay together; and
                  --  firmware keeps it with the object, script and map its
                  --  link writes beside the image, which its report reads.
                  if Unbounded.Length (Intermediate_Assembly) > 0 then
                     declare
                        Removed : Landin.Platform.Write_Status;
                        Reason : Unbounded.Unbounded_String;
                     begin
                        Publication.Discard
                          (Artifacts, Host,
                           Unbounded.To_String (Intermediate_Assembly),
                           Removed, Reason);
                        if Removed /= Landin.Platform.Write_Ok then
                           Note_Failure
                             (Code_Unwritable,
                              "cannot remove the intermediate assembly "
                              & Unbounded.To_String (Intermediate_Assembly)
                              & ": " & Unbounded.To_String (Reason)
                              & "; --keep-asm keeps it on purpose");
                        else
                           for Position in 1 .. Natural (Reserved.Length) loop
                              if Reserved (Position) =
                                Unbounded.To_String (Intermediate_Assembly)
                              then
                                 Reserved.Delete (Position);
                                 exit;
                              end if;
                           end loop;
                        end if;
                     end;
                  end if;
                  Stage_Ended ("emission");
               elsif Emit = Emit_Nothing
                 and then not Policy_Denied
                 and then not Bad_Use
                 and then not Cancelled
                 and then not Landin.Stages.Failed (Context)
               then
                  Check_Requested;
               end if;
            end if;
         end if;
         --  The inputs the link named are known only now.
         if Depfile /= "" and then not Dry_Run
           and then not Landin.Stages.Failed (Context)
         then
            for Path of Protected_Inputs loop
               Check_Make_Path (Path);
            end loop;
         end if;
         if Depfile /= "" and then not Dry_Run and then not Bad_Use
           and then not Policy_Denied
           and then not Cancelled
           and then not Landin.Stages.Failed (Context)
         then
            declare
               Text : Unbounded.Unbounded_String;
               Written : Landin.Platform.Write_Status;
               --  The artifact's own name, so the rule is for the file
               --  the build wrote whatever --emit chose.
               Product : constant String := Artifact_Output;
               procedure Append_Path (Path : String);
               procedure Append_Path (Path : String) is
               begin
                  for Byte of Path loop
                     case Byte is
                        when '$' => Unbounded.Append (Text, "$$");
                        when ' ' | ASCII.HT | '#' | ':' =>
                           Unbounded.Append (Text, "\" & Byte);
                        when others => Unbounded.Append (Text, Byte);
                     end case;
                  end loop;
               end Append_Path;
            begin
               Append_Path (Product);
               Unbounded.Append (Text, ":");
               for Path of Dependency_Directories loop
                  Unbounded.Append (Text, " ");
                  Append_Path (Path);
               end loop;
               for Index in 1 .. Landin.Stages.Source_Count (Context) loop
                  Unbounded.Append (Text, " ");
                  Append_Path (Landin.Source.Name
                    (Landin.Stages.Source
                       (Context, Landin.Stages.Nth_Source (Context, Index))));
               end loop;
               for Path of Protected_Inputs loop
                  Unbounded.Append (Text, " ");
                  Append_Path (Path);
               end loop;
               Unbounded.Append (Text, LF & "");
               Write_Output (Depfile, Unbounded.To_String (Text), Written);
               if Written /= Landin.Platform.Write_Ok then
                  Note_Failure (Code_Unwritable, Write_Failure (Depfile));
               end if;
            end;
         end if;
         Close_Artifacts
           (not Bad_Use and then not Policy_Denied
            and then not Landin.Stages.Failed (Context));
         Write_Stage_Report;
         if Landin.Stages.Failed (Context) and then not Reserved.Is_Empty then
            declare
               Status : Landin.Platform.Write_Status;
               Reason : Unbounded.Unbounded_String;
            begin
               Publication.Abort_Transaction (Artifacts, Host, Status, Reason);
            end;
         end if;
         Finish_Publications;

         --  A rejected target is not a selected target, so nothing is
         --  echoed on the failing path.
         if Natural (Inputs.Length) = 0
           and then Natural (Unknowns.Length) = 0
           and then Natural (Targets.Length) > 0
           and then not Landin.Stages.Failed (Context)
         then
            Result.Output :=
              Unbounded.To_Unbounded_String
                ("target: "
                 & Landin.Targets.Name (Landin.Stages.Target (Context))
                 & LF);
         end if;

         Result.Report :=
           Unbounded.To_Unbounded_String
             (Render_Report);
         Keep_Report;

         if Bad_Use then
            Result.Status := Status_Misuse;
         elsif Landin.Stages.Failed (Context) or else Policy_Denied
           or else Cancelled
         then
            Result.Status := Status_Reported;
         end if;

      exception
         --  These retain the executable's dedicated host/tool outcomes.
         --  In particular, rendering a report after Storage_Error could
         --  require the same resource that has just run out.
         when Landin.Host_Exhausted | Storage_Error
            | Landin.External_Tool_Failed =>
            Close_Artifacts (False);
            Finish_Publications;
            raise;

         --  A defect is the compiler finding itself wrong, and it arrives
         --  after the run has usually already decided several things about
         --  the source.  Letting it escape threw those away and left a
         --  reader with one sentence about the compiler and nothing about
         --  their program; twice in one afternoon that sentence was the
         --  only thing a refused field produced.  So the report is
         --  rendered from what the context holds, the defect is written
         --  under it, and the status says which of the two happened.
         --  It names the stage it arose in and what it said, so a reader
         --  can say which construct broke it without a debugger.
         when Defect : others =>
            Close_Artifacts (False);
            Finish_Publications;
            Result.Report :=
              Unbounded.To_Unbounded_String
                (Render_Report
                 & "refine: internal compiler defect in "
                 & Unbounded.To_String (Current_Stage)
                 & (if Ada.Exceptions.Exception_Message (Defect) = ""
                    then ""
                    else ": " & Ada.Exceptions.Exception_Message (Defect))
                 & LF & Defect_Route & LF);
            Result.Status := Status_Defect;
            Keep_Report;
      end;

      return Result;
   end Execute;

end Landin.Driver;
