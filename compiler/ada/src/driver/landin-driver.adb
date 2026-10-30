with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Maps;

with Landin.Backend.Entry_Point;
with Landin.Backend.Firmware;
with Landin.Backend.Toolchain;
with Landin.Backend.Dispatch;
with Landin.Build_Reports;
with Landin.Build_Reports.Firmware;
with Landin.Build_Reports.Sources;
with Landin.Build_Reports.Stacks;
with Landin.Checking;
with Landin.Configuration;
with Landin.Debugging;
with Landin.IR.Dump;
with Landin.IR.Pipeline;
with Landin.Optimization;
with Landin.Panics;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Explanations;
with Landin.Diagnostics.Suggestions;
with Landin.Diagnostics.Text;
with Landin.Driver.Assembler_Sites;
with Landin.Driver.Checking;
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
   use type Landin.Platform.Remove_Status;
   use type Landin.Platform.Move_Status;
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
     (Emit_Nothing, Emit_Assembly, Emit_Executable, Emit_IR);

   function Identity return String is
     ("refine - the Landin bootstrap compiler" & LF
      & "use refine version for build identity" & LF
      & "language frontend: scanner, parser, names, types, definite assignment"
      & LF
      & "target-neutral IR: lowered and verified" & LF
      & "backends: linux-x86-64, linux-arm64, darwin-arm64, "
      & "freebsd-x86-64, freebsd-arm64, linux-rv64 and cortex-m0"
      & " assembly" & LF
      & "executable output: assembled and linked by a"
      & " target-selected native toolchain" & LF
      & "targets described: linux-x86-64, linux-arm64, darwin-arm64, "
      & "freebsd-x86-64, freebsd-arm64, linux-rv64, "
      & "cortex-m0, synthetic-32" & LF
      & "levels of linux-x86-64: "
      & Landin.Targets.Levels.Levels_Of (Landin.Targets.Linux_X86_64) & LF
      & "levels of linux-arm64: "
      & Landin.Targets.Levels.Levels_Of (Landin.Targets.Linux_Arm64) & LF
      & "levels of darwin-arm64: "
      & Landin.Targets.Levels.Levels_Of (Landin.Targets.Darwin_Arm64) & LF
      & "levels of freebsd-x86-64: "
      & Landin.Targets.Levels.Levels_Of (Landin.Targets.FreeBSD_X86_64) & LF
      & "levels of freebsd-arm64: "
      & Landin.Targets.Levels.Levels_Of (Landin.Targets.FreeBSD_Arm64) & LF
      & "levels of linux-rv64: "
      & Landin.Targets.Levels.Levels_Of (Landin.Targets.Linux_RV64) & LF
      & "levels of cortex-m0: "
      & Landin.Targets.Levels.Levels_Of (Landin.Targets.Cortex_M) & LF);

   function Usage return String is
     ("usage: refine [options] [source.ldn ...]" & LF
      & "       refine explain [CODE ...]" & LF
      & "       refine fmt [--check|--stdout] source.ldn|DIR ..." & LF
      & "       refine lsp" & LF
      & LF
      & "  --help              print this text" & LF
      & "  --identify          print tool identity" & LF
      & "  --target=NAME       select a described target" & LF
      & "  --level=NAME        assume a CPU feature level of that target"
      & LF
      & "  --option=NAME=VALUE set a declared fixed build option" & LF
      & "  --build-mode=NAME   debug (default) or release:"
      & " compiler.build_mode only" & LF
      & "  --optimize=NAME     none, size (default), or speed" & LF
      & "  --specialize=NAME   off, auto (default), or all: direct"
      & " evidence calls" & LF
      & "  --panic-map         emit off-target check-site mapping" & LF
      & "  --debug=NAME        none (default), full (hosted),"
      & " lines (Cortex-M0)" & LF
      & "  --build-report=PATH write deterministic build evidence JSON" & LF
      & "  --stage-report=PATH write each stage's measured time and memory"
      & LF
      & "  --stack-report=PATH write each emitted routine's frame and"
      & " deepest stack" & LF
      & "  --root=DIR          append an ordered module import root" & LF
      & "  --library=DIR       find core, hosted and platform under DIR" & LF
      & "  --emit=asm|exe      write assembly, or assemble and link" & LF
      & "  -o PATH             where to write it" & LF
      & "  -o=PATH             write to a path beginning with -" & LF
      & "  --toolchain=NAME    driver to run with --emit=exe" & LF
      & "  --linker=NAME       pass -fuse-ld=NAME with --emit=exe" & LF
      & "  --link=static|libc  Linux link: static (default) or with libc"
      & LF
      & "  --firmware-entry=NAME  Cortex entry-module routine, no results"
      & LF
      & LF
      & "Source files are scanned, parsed, resolved and checked as one"
      & LF
      & "module. With --root, pass one entry-module directory, or the"
      & LF
      & "entry module's source files; its imports"
      & LF
      & "are found under the roots in option order. Either way core, hosted"
      & LF
      & "and platform are found beside this compiler unless --library names"
      & LF
      & "another. Without --emit a program"
      & LF
      & "that is accepted produces no"
      & LF
      & "output. Hosted --emit=exe requires "
      & Landin.Backend.Entry_Point.Required_Shape & "." & LF
      & "Cortex --emit=exe requires --firmware-entry=NAME." & LF
      & LF
      & "A warning does not change the exit status; an error makes it 1."
      & LF
      & "`refine explain` lists every diagnostic code and its rule;"
      & LF
      & "`refine explain L0201` says what that code means and how to fix"
      & LF
      & "it.  `refine fmt` rewrites each named source in the one layout;"
      & LF
      & "with --check it writes nothing and reports each line that is"
      & LF
      & "not in it, and with --stdout it prints the one source named in"
      & LF
      & "it.  `refine lsp` is a language server over standard" & LF
      & "input and output." & LF
      & LF
      & "The toolchain is found by the target's GNU triplet, so"
      & LF
      & "linux-x86-64 runs x86_64-pc-linux-gnu-gcc and linux-arm64"
      & LF
      & "aarch64-linux-gnu-gcc unless --toolchain names another." & LF
      & "FreeBSD uses its target triplet with -clang; the driver wrapper"
      & LF & "must supply its FreeBSD sysroot and linker." & LF);

   ---------------------------------------------------------------------
   --  Explain
   --
   --  A request with no compilation in it.  The report it may make is a
   --  driver report with no source, rendered as every other one is.
   ---------------------------------------------------------------------

   function Explain (Arguments : Landin.Platform.Path_List) return Outcome;

   function Explain (Arguments : Landin.Platform.Path_List) return Outcome
   is
      use type Rows.Disposition;
      use type Landin.Diagnostics.Severity;

      Result : Outcome;
      Text   : Unbounded.Unbounded_String;
      Found  : Landin.Diagnostics.Diagnostic_List;

      procedure Refuse (Message : String);

      procedure Refuse (Message : String) is
      begin
         Found.Append
           (Landin.Diagnostics.Make
              (Code    => Code_Unknown_Option,
               Level   => Landin.Diagnostics.Error,
               Source  => Landin.Source.No_Source,
               Where   => Landin.Source.Empty_Span,
               Message => Message));
      end Refuse;

      function Row_Line (Name : Rows.Code_Name) return String
        is (Rows.Code (Name)
            & (if Rows.State (Name) = Rows.Retired then "  retired  "
               else "  " & Landin.Diagnostics.Text.Image (Rows.Level (Name))
                    & (if Rows.Level (Name) = Landin.Diagnostics.Error
                       then "    " else "  "))
            & Rows.Rule (Name) & LF);
   begin
      if Natural (Arguments.Length) = 1 then
         for Name in Rows.Code_Name loop
            Unbounded.Append (Text, Row_Line (Name));
         end loop;
      end if;

      for Index in 2 .. Natural (Arguments.Length) loop
         declare
            Asked : constant String := Arguments.Element (Index);
         begin
            if not Landin.Diagnostics.Is_Valid_Code (Asked)
              or else not Rows.Holds (Asked)
            then
               Refuse ((if Asked'Length > 0 and then Asked (Asked'First) = '-'
                        then "explain takes no option: "
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
               end;
            end if;
         end;
      end loop;

      if Landin.Diagnostics.Count (Found) > 0 then
         Result.Status := Status_Misuse;
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
                    Host      : Landin.Platform.Filesystem'Class)
     return Outcome;

   function Format (Arguments : Landin.Platform.Path_List;
                    Host      : Landin.Platform.Filesystem'Class)
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
            declare
               Content : Unbounded.Unbounded_String;
               Read    : Landin.Platform.Read_Status;
            begin
               Host.Read_File (Path, Content, Read);
               if Read /= Landin.Platform.Read_Ok then
                  Refuse (Code_Unreadable,
                          (if Read = Landin.Platform.Not_Found
                           then "source not found: "
                           else "source not readable: ") & Path);
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
                     else
                        Host.Replace_File
                          (Path, Unbounded.To_String (Answer.Text), Written,
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
        Landin.Diagnostics.Warning_Policy.Defaults) return Outcome
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
      Library_Path : Unbounded.Unbounded_String;
      Library_Seen : Boolean := False;
      Build_Report_Path : Unbounded.Unbounded_String;
      Stage_Report_Path : Unbounded.Unbounded_String;
      Stage_Report_Seen : Boolean := False;
      Stack_Report_Path : Unbounded.Unbounded_String;
      Stack_Report_Seen : Boolean := False;
      Optimization : Landin.Optimization.Options :=
        Landin.Optimization.Default_Options;
      Optimize_Seen, Specialize_Seen, Report_Seen : Boolean := False;
      Debug_Seen, Debug_Enabled : Boolean := False;
      Lines_Debug : Boolean := False;
      Panic_Map : Boolean := False;
      Emit_Seen, Output_Seen : Boolean := False;
      --  D362: an executable's assembly is kept beside it only on request.
      Keep_Assembly : Boolean := False;
      Skip_Compilation : Boolean := False;
      Index     : Positive := 1;
      Dependency_Directories : aliased Landin.Platform.Path_List;
   begin
      if Natural (Arguments.Length) = 0 then
         Result.Status := Status_Misuse;
         Result.Output := Unbounded.To_Unbounded_String (Usage);
         return Result;
      end if;

      if Arguments.Element (1) = Explain_Command then
         return Explain (Arguments);
      elsif Arguments.Element (1) = Format_Command then
         return Format (Arguments, Host);
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
                  elsif Kind = "ir" then
                     Emit := Emit_IR;
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
      --  debug information, a panic map and a stack report describe an
      --  emitted artifact; a build report may describe a check (D383).
      if ((Optimize_Seen or Specialize_Seen or Report_Seen
           or Debug_Seen or Panic_Map or Stage_Report_Seen
           or Stack_Report_Seen
           or Toolchain_Seen or Linker_Seen or Link_Seen or Firmware_Seen)
          and then (Wants_Usage or Wants_Identity))
        or else ((Debug_Seen or Panic_Map) and then Emit = Emit_Nothing)
        or else ((Debug_Seen or Panic_Map) and then Emit = Emit_IR)
        or else (Stack_Report_Seen
                 and then Emit in Emit_Nothing | Emit_IR)
        or else (Keep_Assembly and then Emit /= Emit_Executable)
        or else ((Optimize_Seen or Specialize_Seen or Report_Seen
                  or Firmware_Seen or Link_Seen)
                 and then Natural (Inputs.Length) = 0)
        or else (Output_Seen
                 and then Unbounded.Length (Output_Problem) = 0
                 and then
                 (Emit = Emit_Nothing or Unbounded.Length (Output) = 0))
      then
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
               & Levels.Element (1));
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
             (Facts, Unbounded.To_String (Toolchain), Native_Target);

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
         --  is linked into every C program.
         function Implicit_Module return String
           is (if Static_Link and then Emit /= Emit_Nothing
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

         --  What is wrong with an argument the driver refused.  A known
         --  option misused is said to be misused, and how; an unknown one
         --  is named with the known option nearest it, when one is near.
         function Option_Problem (Option : String) return String;

         --  The options `refine` reads, each as it is spelled before any
         --  `=`, and those that read a value after it.
         function Is_Known_Option (Stem : String) return Boolean
           is (Stem in "--help" | "--identify" | "--target" | "--level"
                     | "--option" | "--build-mode" | "--optimize"
                     | "--specialize" | "--panic-map" | "--debug"
                     | "--build-report" | "--stage-report"
                     | "--stack-report" | "--root"
                     | "--library" | "--emit" | "-o" | "--toolchain"
                     | "--linker" | "--link" | "--firmware-entry"
                     | "--keep-asm");

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

         --  The values an option takes, for a report that one was refused.
         function Accepted_Values (Stem : String) return String
           is (if Stem = "--optimize" then "; it takes none, size or speed"
               elsif Stem = "--specialize" then
                 "; it takes off, auto or all"
               elsif Stem = "--debug" then
                 "; it takes none, full or lines"
               elsif Stem = "--emit" then "; it takes asm, exe or ir"
               elsif Stem = "--link" then "; it takes static or libc"
               else "");

         type Spelling_Access is access constant String;
         Target_Spellings : constant array (Positive range <>)
           of Spelling_Access :=
             [new String'("linux-x86-64"), new String'("linux-arm64"),
              new String'("darwin-arm64"), new String'("freebsd-x86-64"),
              new String'("freebsd-arm64"), new String'("linux-rv64"),
              new String'("cortex-m0"),
              new String'("synthetic-32")];
         Option_Spellings : constant array (Positive range <>)
           of Spelling_Access :=
             [new String'("--help"), new String'("--identify"),
              new String'("--target"), new String'("--level"),
              new String'("--option"), new String'("--build-mode"),
              new String'("--optimize"), new String'("--specialize"),
              new String'("--panic-map"), new String'("--debug"),
              new String'("--build-report"), new String'("--stage-report"),
              new String'("--stack-report"),
              new String'("--root"), new String'("--library"),
              new String'("--emit"),
              new String'("--toolchain"), new String'("--linker"),
              new String'("--link"), new String'("--firmware-entry"),
              new String'("--keep-asm")];

         --  Why the options given cannot be one request.
         function Incompatible_Action return String
           is (if (Optimize_Seen or Specialize_Seen or Report_Seen
                   or Debug_Seen or Panic_Map or Stage_Report_Seen
                   or Stack_Report_Seen
                   or Toolchain_Seen or Linker_Seen or Link_Seen
                   or Firmware_Seen)
                  and then (Wants_Usage or Wants_Identity)
               then (if Wants_Usage then "--help" else "--identify")
                    & " prints and compiles nothing, so it takes no"
                    & " compilation option"
               elsif (Debug_Seen or Panic_Map) and then Emit = Emit_Nothing
               then "--debug and --panic-map describe what is emitted;"
                    & " add --emit"
               elsif (Debug_Seen or Panic_Map) and then Emit = Emit_IR
               then "--debug and --panic-map describe machine code, and"
                    & " --emit=ir writes the IR before any is chosen"
               elsif Stack_Report_Seen
                 and then Emit in Emit_Nothing | Emit_IR
               then "--stack-report measures the frames of emitted machine"
                    & " code: add --emit=asm or --emit=exe"
               elsif Keep_Assembly and then Emit /= Emit_Executable
               then "--keep-asm keeps an executable's assembly beside it;"
                    & " --emit=asm writes the assembly alone"
               elsif (Optimize_Seen or Specialize_Seen or Report_Seen
                      or Firmware_Seen or Link_Seen)
                 and then Natural (Inputs.Length) = 0
               then (if Optimize_Seen then "--optimize"
                     elsif Specialize_Seen then "--specialize"
                     elsif Report_Seen then "--build-report"
                     elsif Firmware_Seen then "--firmware-entry"
                     else "--link") & " needs a source to compile"
               elsif Emit = Emit_Nothing
               then "-o names what is emitted, and nothing is: add"
                    & " --emit=asm or --emit=exe"
               else "-o needs a path");

         --  "; did you mean T?" for the described target nearest Name,
         --  or "".  `macos` is what a reader calls `darwin`.
         function Nearest_Target (Name : String) return String;

         function Nearest_Target (Name : String) return String is
            Offered : Landin.Diagnostics.Suggestions.Ranking;
            Asked   : constant String :=
              (if Starts_With (Name, "macos")
               then "darwin" & Name (Name'First + 5 .. Name'Last)
               else Name);
         begin
            for Known of Target_Spellings loop
               Landin.Diagnostics.Suggestions.Consider
                 (Offered, Asked, Known.all);
            end loop;
            if Asked /= Name
              and then Landin.Targets.Selection.Is_Described (Asked)
            then
               return "; did you mean " & Asked & "?";
            elsif Landin.Diagnostics.Suggestions.Count (Offered) = 0 then
               return "";
            end if;
            return "; did you mean "
              & Landin.Diagnostics.Suggestions.Nth (Offered, 1) & "?";
         end Nearest_Target;

         --  The known option nearest an unknown one, or "".
         function Nearest_Option (Stem : String) return String;

         function Nearest_Option (Stem : String) return String is
            Offered : Landin.Diagnostics.Suggestions.Ranking;
         begin
            --  What other compilers spell these, which no edit distance
            --  reaches.
            if Stem in "--version" | "-v" | "-V" then
               return "--identify";
            elsif Stem = "-g" then
               return "--debug=full";
            elsif Stem in "--check" | "--format" then
               return "`refine fmt --check` (checking needs no option)";
            elsif Stem = "-O" or else Starts_With (Stem, "-O") then
               return "--optimize";
            end if;
            for Known of Option_Spellings loop
               Landin.Diagnostics.Suggestions.Consider
                 (Offered, Stem, Known.all);
            end loop;
            if Landin.Diagnostics.Suggestions.Count (Offered) = 0 then
               return "";
            end if;
            return Landin.Diagnostics.Suggestions.Nth (Offered, 1);
         end Nearest_Option;

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
               return "--target may be given once";
            elsif Option = "--level given more than once" then
               return "--level may be given once";
            elsif Is_Known_Option (Stem) then
               if Times_Written (Stem) > 1 then
                  return Stem & " may be given once";
               elsif Equals /= 0 and then Value = "" then
                  return Stem & " needs a value after `=`";
               elsif Equals /= 0 then
                  return Stem & " does not take `" & Value & "`"
                    & Accepted_Values (Stem);
               elsif Stem = "-o" then
                  return "-o needs a path after it";
               end if;
               return Stem & " is not used this way";
            end if;
            declare
               Near : constant String := Nearest_Option (Stem);
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

         procedure Check_Dependency_Path (Path : String);

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
            --  A failed read has no source in Context, but its requested
            --  path must still be protected from the report writer.
            for Input of Inputs loop
               if Host.Paths_Overlap (Path, Input) then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "stage report collides with source: " & Path);
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
                     "stage report collides with source: " & Path);
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
            Host.Write_File
              (Path,
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
               Written);
            if Written /= Landin.Platform.Write_Ok then
               Note_Failure (Code_Unwritable, "cannot write: " & Path);
            end if;
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
            Selected : constant String :=
              (if For_Firmware then Unbounded.To_String (Firmware_Name)
               else "main");
            Grouped : Landin.Modules.Table renames
              Landin.Stages.Modules (Context).all;
            Meanings : Res.Table renames
              Landin.Stages.Meanings (Context).all;
            Source : Landin.Source.Source_Id := Landin.Source.No_Source;
            Where : Landin.Source.Span := Landin.Source.Empty_Span;
         begin
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
              and then Landin.Modules.Find_Logical
                (Landin.Stages.Modules (Context).all, "platform/linux")
                  = Landin.Modules.No_Module
            then
               Note_No_Toolchain
                 ("a static link of " & Landin.Targets.Name (Facts)
                  & " starts at platform/linux's `_landin_start`, and"
                  & " no library holding platform/linux was found",
                  "name the library with --library=PATH, or link"
                  & " with --link=libc, which keeps C's runtime");
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

         --  D364: the names looked for, and what to install.  A named
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
                  & Landin.Targets.Name (Facts) & " was found; looked for "
                  & Unbounded.To_String (Looked)),
               Landin.Backend.Toolchain.Install_Advice
                 (Facts, Unbounded.To_String (Toolchain), Native_Target));
         end Note_Unavailable_Toolchain;

         --  The link that finishes an executable from assembly, whether
         --  this request emitted it or named it (D362): the driver chosen,
         --  the prior executable kept aside until a new one exists, and
         --  every failure said as the tool said it.
         procedure Link_Assembly
           (Assembly_Path, Product_Path, Map_Id : String;
            Destinations : Landin.Platform.Path_List);

         procedure Link_Assembly
           (Assembly_Path, Product_Path, Map_Id : String;
            Destinations : Landin.Platform.Path_List)
         is
            Report_Path : constant String :=
              Unbounded.To_String (Build_Report_Path);
            Cortex : constant Boolean :=
              Landin.Targets.Architecture_Of (Facts)
                = Landin.Targets.Cortex_M0;
            Written : Landin.Platform.Write_Status;
         begin
            declare
               Driver : constant String :=
                 Unbounded.To_String (Chosen_Driver);
               Target_Path : constant String :=
                 (if Unbounded.Length (Output) > 0
                  then Unbounded.To_String (Output)
                  else Default_Executable);
               Ran : Landin.Platform.Tool_Result;
               Libraries : Landin.Platform.Path_List;
               Libraries_Ready : Boolean;
               Backup : Unbounded.Unbounded_String;
               Prior_Identity : Landin.Platform.File_Identity;
               Prepared : Boolean := False;
               Removed : Landin.Platform.Remove_Status;
               Moved : Landin.Platform.Move_Status;
               Lock_Handle : Integer := -1;

               procedure Release_Lock;

               procedure Release_Lock is
               begin
                  if Lock_Handle >= 0 then
                     Host.Unlock_Output (Lock_Handle);
                     Lock_Handle := -1;
                  end if;
               end Release_Lock;

               procedure Restore_Output;

               procedure Restore_Output is
               begin
                  if not Prepared then
                     return;
                  end if;
                  if Unbounded.Length (Backup) > 0
                    and then not Host.Exists (Unbounded.To_String (Backup))
                    and then Host.Identity_Of (Target_Path) = Prior_Identity
                  then
                     --  The tool moved the old inode back itself.
                     Prepared := False;
                     return;
                  end if;
                  Host.Remove_File (Target_Path, Removed);
                  if Removed = Landin.Platform.Not_Removable then
                     Note_Failure
                        (Code_Toolchain_Failed,
                        "cannot clear failed executable: " & Target_Path
                        & (if Unbounded.Length (Backup) > 0
                           then "; prior executable retained at "
                             & Unbounded.To_String (Backup)
                           else ""));
                  elsif Unbounded.Length (Backup) > 0 then
                     Host.Move_File
                       (Unbounded.To_String (Backup), Target_Path, Moved);
                     if Moved /= Landin.Platform.Moved then
                        Note_Failure
                          (Code_Toolchain_Failed,
                           "cannot restore prior executable from "
                           & Unbounded.To_String (Backup));
                     end if;
                  end if;
                  Prepared := False;
               end Restore_Output;
            begin
               if Driver = "" then
                  Note_No_Toolchain
                    ("target " & Landin.Targets.Name (Facts)
                     & " names no toolchain",
                     "name one with --toolchain=NAME");
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
                  if Cortex then
                     Host.Write_File
                       (Product_Path & ".ld",
                        Landin.Backend.Firmware.Linker_Script, Written);
                     if Written /= Landin.Platform.Write_Ok then
                        Note_Failure
                          (Code_Unwritable,
                           "cannot write: " & Product_Path & ".ld");
                        return;
                     end if;
                     Tools.Run
                       (Driver,
                        Landin.Backend.Toolchain.Assemble_Arguments
                          (Assembly_Path, Product_Path & ".o", Facts,
                           Debug => Debug_Enabled,
                           Level => Landin.Stages.Level (Context)),
                        Ran, Landin.Platform.Merged);
                     if Ran.Ended /= Landin.Platform.Exited
                       or else Ran.Exit_Code /= 0
                     then
                        Note_Failure
                          (Code_Toolchain_Failed,
                           "firmware assembly failed" & LF
                           & Unbounded.To_String (Ran.Output));
                        return;
                     end if;
                  end if;
                  Landin.Backend.Toolchain.Resolve_Libraries
                    (Facts, Driver, Host, Tools, Libraries, Ran,
                     Libraries_Ready);
                  if not Libraries_Ready then
                     Note_Failure
                       (Code_Toolchain_Failed,
                        Unbounded.To_String (Ran.Output));
                     return;
                  end if;

                  Host.Lock_Output (Target_Path, Lock_Handle);
                  if Lock_Handle < 0 then
                     Note_Failure
                       (Code_Toolchain_Failed,
                        "cannot lock executable destination: "
                        & Target_Path);
                     return;
                  end if;

                  --  A zero-exit tool must produce a new pathname for this
                  --  invocation. Keep the old file aside until that is
                  --  established, even when the new bytes are identical.
                  if Host.Exists (Target_Path) then
                     Prior_Identity := Host.Identity_Of (Target_Path);
                     if not Prior_Identity.Valid then
                        Note_Failure
                          (Code_Toolchain_Failed,
                           "cannot identify prior executable: "
                           & Target_Path);
                        Release_Lock;
                        return;
                     end if;
                     for Index in 1 .. 100 loop
                        declare
                           Candidate : constant String := Target_Path
                             & ".landin-backup-"
                             & Ada.Strings.Fixed.Trim
                                 (Positive'Image (Index), Ada.Strings.Both);
                           Conflicts : Boolean := Host.Exists (Candidate)
                             or else (Report_Seen and then
                               Host.Paths_Overlap (Candidate, Report_Path));
                        begin
                           for Path of Destinations loop
                              Conflicts := Conflicts or else
                                Host.Paths_Overlap (Candidate, Path);
                           end loop;
                           for Source in 1 .. Landin.Stages.Source_Count
                             (Context)
                           loop
                              Conflicts := Conflicts or else
                                Host.Paths_Overlap
                                  (Candidate, Landin.Source.Name
                                     (Landin.Stages.Source
                                        (Context,
                                         Landin.Stages.Nth_Source
                                           (Context, Source))));
                           end loop;
                           if not Conflicts then
                              Host.Move_File
                                (Target_Path, Candidate, Moved);
                              if Moved = Landin.Platform.Moved then
                                 Backup := Unbounded.To_Unbounded_String
                                   (Candidate);
                                 exit;
                              end if;
                           end if;
                        end;
                     end loop;
                     if Unbounded.Length (Backup) = 0 then
                        Note_Failure
                          (Code_Toolchain_Failed,
                           "cannot preserve prior executable: "
                           & Target_Path);
                        Release_Lock;
                        return;
                     end if;
                  else
                     Host.Remove_File (Target_Path, Removed);
                     if Removed = Landin.Platform.Not_Removable then
                        Note_Failure
                          (Code_Toolchain_Failed,
                           "cannot clear executable output: "
                           & Target_Path);
                        Release_Lock;
                        return;
                     end if;
                  end if;
                  Prepared := True;
                  Tools.Prepare_Output (Host, Target_Path);
                  Tools.Run
                    (Program   => Driver,
                     Arguments =>
                       Landin.Backend.Toolchain.Link_Arguments
                         (Assembly => Assembly_Path,
                          Output   => Target_Path,
                          Linker   => Unbounded.To_String (Linker),
                          Build_Id => Map_Id,
                          Full_Debug => Debug_Enabled,
                          Libraries => Libraries, Facts => Facts,
                          Level => Landin.Stages.Level (Context),
                          Static => Static_Link,
                          Threads => Starts_C_Threads),
                     Result    => Ran,
                     Capture   => Landin.Platform.Merged);
               exception
                  when Failure : Landin.External_Tool_Failed =>
                     Restore_Output;
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
                              Driver & " could not be run to completion: "
                              & Why);
                        end if;
                     end;
                     Release_Lock;
                     return;
                  when others =>
                     Restore_Output;
                     raise;
               end;

               --  How the run ended is asked before what it returned,
               --  because a tool a signal killed has no status and the
               --  field beside it holds zero.  Reading that alone would
               --  make a dead assembler a success that wrote nothing.
               if Ran.Ended /= Landin.Platform.Exited then
                  Restore_Output;
                  Note_Failure
                    (Code_Toolchain_Failed,
                     Driver & " was stopped before it could finish" & LF
                     & Unbounded.To_String (Ran.Output));
               elsif Ran.Exit_Code /= 0 then
                  Restore_Output;
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
                          (Output  => Unbounded.To_String (Ran.Output),
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
                     else
                        Note_Failure
                          (Code_Toolchain_Failed,
                           Driver & " failed with status"
                           & Integer'Image (Ran.Exit_Code) & LF
                           & Unbounded.To_String (Ran.Output));
                     end if;
                  end;
               elsif not Tools.Output_Produced (Host, Target_Path) then
                  Restore_Output;
                  Note_Failure
                    (Code_Toolchain_Failed,
                     Driver & " reported success but produced no executable"
                     & " at " & Target_Path & LF
                     & Unbounded.To_String (Ran.Output));
               elsif Unbounded.Length (Backup) > 0
                 and then
                   (Host.Same_File
                      (Target_Path, Unbounded.To_String (Backup))
                    or else Host.Identity_Of (Target_Path) = Prior_Identity)
               then
                  Restore_Output;
                  Note_Failure
                    (Code_Toolchain_Failed,
                     Driver & " left executable output aliasing its prior"
                     & " backup at " & Target_Path);
               elsif Unbounded.Length (Backup) > 0 then
                  Host.Remove_File (Unbounded.To_String (Backup), Removed);
                  if Removed = Landin.Platform.Not_Removable then
                     Note_Failure
                       (Code_Toolchain_Failed,
                        "cannot remove prior executable backup: "
                        & Unbounded.To_String (Backup));
                  end if;
               end if;
               Release_Lock;
            exception
               when others =>
                  Release_Lock;
                  raise;
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
            Emit_Map : constant Boolean := Emit /= Emit_IR
              and then (Debug_Enabled or else Panic_Map
                or else Landin.IR.Caller_Source_Count
                  (Landin.Stages.Code (Context).all) > 0);
            Destinations : Landin.Platform.Path_List;
            Source_Paths : Landin.Platform.Path_List;
            Cortex : constant Boolean :=
              Landin.Targets.Architecture_Of (Facts)
                = Landin.Targets.Cortex_M0;
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
                  Host.Write_File
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
                       (Code_Unwritable, "cannot write: " & Stack_Path);
                  end if;
               end if;
            end Write_Stack_Report;

            procedure Write_Build_Report;

            procedure Write_Build_Report is
               Firmware : Unbounded.Unbounded_String;
               Valid : Boolean := True;
            begin
               if Report_Seen and then not Landin.Stages.Failed (Context) then
                  if Cortex and then Emit = Emit_Executable then
                     Landin.Build_Reports.Firmware.Measure
                       (Host, Product_Path, Product_Path & ".map",
                        Firmware, Valid);
                     if not Valid then
                        Note_Failure
                          (Code_Toolchain_Failed,
                           "cannot measure linked firmware image or map");
                        return;
                     end if;
                  end if;
                  Host.Write_File
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
                       (Code_Unwritable, "cannot write: " & Report_Path);
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
               if Cortex then
                  Destinations.Append (Product_Path & ".o");
                  Destinations.Append (Product_Path & ".ld");
                  Destinations.Append (Product_Path & ".map");
               end if;
               if Debug_Enabled then
                  for Path of Landin.Backend.Toolchain.Debug_Artifacts
                    (Product_Path, Facts, Host)
                  loop
                     Destinations.Append (Path);
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
                        "stage report collides with an artifact: "
                        & Stage_Path);
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
                        "build report collides with an artifact: "
                        & Report_Path);
                     return;
                  end if;
               end loop;
               if Host.Paths_Overlap_Any (Report_Path, Source_Paths) then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "build report collides with source: " & Report_Path);
                  return;
               end if;
            end if;
            if Stack_Report_Seen then
               for Path of Destinations loop
                  if Host.Paths_Overlap (Stack_Path, Path) then
                     Bad_Use := True;
                     Note_Failure
                       (Code_Unknown_Option,
                        "stack report collides with an artifact: "
                        & Stack_Path);
                     return;
                  end if;
               end loop;
               if Host.Paths_Overlap_Any (Stack_Path, Source_Paths) then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "stack report collides with source: " & Stack_Path);
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
                        "artifacts collide: " & Destinations (Index)
                        & " and " & Destinations (Earlier));
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
                     "artifact collides with source: "
                     & Destinations (Index));
                  return;
               end if;
            end loop;

            if Cortex and then not Firmware_Seen
              and then Emit = Emit_Assembly
            then
               for Index in 1 .. Landin.IR.Item_Count
                 (Landin.Stages.Code (Context).all)
               loop
                  if Landin.IR.Placement_Of
                    (Landin.Stages.Code (Context).all,
                     Landin.IR.Item_Id (Index)).Vector /= 0
                  then
                     Note_Failure
                       (Code_No_Entry, "vector placement requires an explicit"
                        & " --firmware-entry=NAME request");
                     return;
                  end if;
               end loop;
            end if;
            if Cortex and then (Emit = Emit_Executable or Firmware_Seen) then
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
               if not Landin.Backend.Firmware.Materialization_Fits
                 (Landin.Stages.Code (Context).all)
               then
                  Note_Failure
                    (Rows.Code (Rows.Image_Materialization_Limit),
                     "firmware static images exceed 8 MiB before section GC");
                  return;
               end if;
               if Landin.Configuration.Library_Count
                 (Landin.Stages.Configurations (Context).all) /= 0
               then
                  Note_No_Toolchain
                    ("firmware does not admit linker.library",
                     "remove linker.library declarations; only the"
                     & " selected private Arm runtime is linked");
                  return;
               end if;
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

            --  [1970]'s entry is required before anything is written, so a
            --  program that could never be linked does not leave a file
            --  behind on the way to saying so.
            if Emit = Emit_Executable and then not Cortex
              and then Landin.Backend.Entry_Point.Hosted_Main
                         (Landin.Stages.Code (Context).all,
                          Landin.Stages.Meanings (Context).all,
                          Landin.Stages.Modules (Context).all,
                          Landin.Stages.Identities (Context).all)
                       = Landin.IR.No_Item
            then
               Note_No_Entry;
               return;
            elsif Emit = Emit_Assembly and then not Cortex
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
                           & "4 KiB firmware stack reservation");
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
                  Host.Write_File
                    (Assembly_Path,
                     Landin.IR.Dump.Text
                       (Landin.Stages.Code (Context).all,
                        Landin.Stages.Meanings (Context).all,
                        Landin.Stages.Identities (Context).all,
                        Kept => Is_Kept'Access),
                     Written);
               end;
               if Written /= Landin.Platform.Write_Ok then
                  Note_Failure
                    (Code_Unwritable, "cannot write: " & Assembly_Path);
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
                        if Cortex then
                           Plan_Tool
                          (Landin.Backend.Toolchain.Assemble_Arguments
                             (Assembly_Path, Product_Path & ".o", Facts,
                              Debug => Debug_Enabled,
                              Level => Landin.Stages.Level (Context)));
                        end if;
                        if not Libraries.Is_Empty
                          and then Landin.Targets.Capabilities.Backend_For
                            (Facts)
                            = Landin.Targets.Capabilities.Darwin_Arm64_Mach_O
                        then
                           Unbounded.Append (Result.Output,
                             "resolve Darwin archive paths before linking"
                             & LF);
                        else
                           Plan_Tool (Landin.Backend.Toolchain.Link_Arguments
                             (Assembly => Assembly_Path,
                              Output => Product_Path,
                              Linker => Unbounded.To_String (Linker),
                              Libraries => Libraries, Facts => Facts,
                              Full_Debug => Debug_Enabled,
                              Build_Id => Unbounded.To_String (Map_Id),
                              Level => Landin.Stages.Level (Context),
                              Static => Static_Link));
                        end if;
                        if not Keep_Assembly and then not Cortex
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

               Host.Write_File
                 (Assembly_Path, Unbounded.To_String (Emitted), Written);
               if Written /= Landin.Platform.Write_Ok then
                  Note_Failure
                    (Code_Unwritable, "cannot write: " & Assembly_Path);
                  return;
               end if;
               if Emit = Emit_Executable and then not Cortex
                 and then not Keep_Assembly and then not Emit_Map
               then
                  Intermediate_Assembly :=
                    Unbounded.To_Unbounded_String (Assembly_Path);
               end if;
               if Emit_Map then
                  Host.Write_File
                    (Map_Path, Unbounded.To_String (Map_JSON), Written);
                  if Written /= Landin.Platform.Write_Ok then
                     Note_Failure
                       (Code_Unwritable, "cannot write: " & Map_Path);
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
              (Assembly_Path, Product_Path, Unbounded.To_String (Map_Id),
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
              and then Landin.Targets.Architecture_Of (Facts)
                = Landin.Targets.Cortex_M0
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
            if Landin.Targets.Architecture_Of (Facts)
                 /= Landin.Targets.Cortex_M0
              and then Public_Main_Not_Entry
            then
               Note_No_Entry;
               return;
            end if;
            if Static_Link
              and then Refused_Static_Link
                (Executable => True, Checking => True)
            then
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
                  "build report collides with source: " & Report_Path);
               return;
            end if;
            Landin.Build_Reports.Clear (Evidence);
            Host.Write_File
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
               Note_Failure (Code_Unwritable, "cannot write: " & Report_Path);
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
            Cortex : constant Boolean :=
              Landin.Targets.Architecture_Of (Facts)
                = Landin.Targets.Cortex_M0;
            Destinations : Landin.Platform.Path_List;
         begin
            Destinations.Append (Product);
            if Cortex then
               Destinations.Append (Product & ".o");
               Destinations.Append (Product & ".ld");
               Destinations.Append (Product & ".map");
            end if;
            for Path of Destinations loop
               if Host.Paths_Overlap (Path, Operand) then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "artifact collides with source: " & Path);
                  return;
               end if;
            end loop;
            if not Host.Exists (Operand) then
               Note_Failure (Code_Unreadable, "source not found: " & Operand);
               return;
            end if;
            if Dry_Run then
               declare
                  procedure Plan_Tool (Arguments : Landin.Platform.Path_List);
                  procedure Plan_Tool (Arguments : Landin.Platform.Path_List)
                  is
                  begin
                     Unbounded.Append (Result.Output,
                       "run [" & Landin.Json.Quoted (Planned_Driver));
                     for Argument of Arguments loop
                        Unbounded.Append (Result.Output,
                          "," & Landin.Json.Quoted (Argument));
                     end loop;
                     Unbounded.Append (Result.Output, "]" & LF);
                  end Plan_Tool;
               begin
                  Unbounded.Append (Result.Output,
                    "write " & Landin.Json.Quoted (Product) & LF);
                  if Cortex then
                     Plan_Tool
                       (Landin.Backend.Toolchain.Assemble_Arguments
                          (Operand, Product & ".o", Facts,
                           Debug => Debug_Enabled,
                           Level => Landin.Stages.Level (Context)));
                  end if;
                  Plan_Tool (Landin.Backend.Toolchain.Link_Arguments
                    (Assembly => Operand, Output => Product,
                     Linker => Unbounded.To_String (Linker),
                     Facts => Facts, Full_Debug => Debug_Enabled,
                     Level => Landin.Stages.Level (Context),
                     Static => Static_Link));
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
            Link_Assembly (Operand, Product, "", Destinations);
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
         Check_Dependency_Path (Depfile);
         Check_Dependency_Path (Unbounded.To_String (Output));
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

         if Stage_Report_Seen
           and then
             ((Report_Seen
               and then Host.Paths_Overlap
                 (Unbounded.To_String (Stage_Report_Path),
                  Unbounded.To_String (Build_Report_Path)))
              or else (Emit /= Emit_Nothing
                and then Host.Paths_Overlap
                  (Unbounded.To_String (Stage_Report_Path),
                   (if Unbounded.Length (Output) > 0
                    then Unbounded.To_String (Output)
                    elsif Emit = Emit_Executable then Default_Executable
                    else Default_Assembly))))
         then
            Bad_Use := True;
            Note_Failure
              (Code_Unknown_Option,
               "stage report collides with another output: "
               & Unbounded.To_String (Stage_Report_Path));
         end if;

         if Stack_Report_Seen
           and then
             ((Report_Seen
               and then Host.Paths_Overlap
                 (Unbounded.To_String (Stack_Report_Path),
                  Unbounded.To_String (Build_Report_Path)))
              or else (Stage_Report_Seen
                and then Host.Paths_Overlap
                  (Unbounded.To_String (Stack_Report_Path),
                   Unbounded.To_String (Stage_Report_Path)))
              or else (Emit /= Emit_Nothing
                and then Host.Paths_Overlap
                  (Unbounded.To_String (Stack_Report_Path),
                   (if Unbounded.Length (Output) > 0
                    then Unbounded.To_String (Output)
                    elsif Emit = Emit_Executable then Default_Executable
                    else Default_Assembly))))
         then
            Bad_Use := True;
            Note_Failure
              (Code_Unknown_Option,
               "stack report collides with another output: "
               & Unbounded.To_String (Stack_Report_Path));
         end if;

         --  D383: with roots, the operand is the entry module's directory
         --  or its source files, as without them.
         if Natural (Roots.Length) > 0
           and then (Natural (Inputs.Length) = 0
                     or else (Natural (Inputs.Length) > 1
                              and then not Rooted_Files))
         then
            Bad_Use := True;
            Note_Failure
              (Code_Unknown_Option,
               "a rooted request names one entry-module directory, or the"
               & " entry module's source files");
         end if;

         --  Target facts and emission options are known before any source
         --  is loaded.  A source error must not hide an incompatible request.
         if (Emit /= Emit_Nothing or else Firmware_Seen or else Link_Seen)
           and then Rejected.Is_Empty
         then
            declare
               Cortex : constant Boolean :=
                 Landin.Targets.Architecture_Of (Facts)
                   = Landin.Targets.Cortex_M0;
            begin
               if Emit /= Emit_Nothing and then Debug_Enabled and then
                 (Landin.Targets.Capabilities.Debug_Format_Of (Facts)
                    = Landin.Targets.Capabilities.No_Debug_Format
                  or else Lines_Debug /= Cortex)
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
                      elsif Cortex then "use --debug=lines or --debug=none"
                      else "use --debug=full or --debug=none"));
                  Target_Option_Refused := True;
               elsif Firmware_Seen and then not Cortex then
                  Bad_Use := True;
                  Note_Failure
                    (Code_Unknown_Option,
                     "--firmware-entry requires --target=cortex-m0");
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
                        "stage report collides with source: "
                        & Unbounded.To_String (Stage_Report_Path));
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
                  Loading.Load_Files (Context, Host, Inputs);
                  if Landin.Stages.Source_Count (Context) > 0
                    and then not Landin.Stages.Failed (Context)
                  then
                     Loading.Load_Rooted_Imports
                       (Context, Host, Roots, Library_Root,
                        Dependency_Directories =>
                          (if Depfile /= ""
                           then Dependency_Directories'Access else null),
                        Implicit => Implicit_Module,
                        Parsing => Watch_Parsing'Access);
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
                        Parsing => Watch_Parsing'Access);
                  end if;
               else
                  Loading.Load_Files (Context, Host, Inputs);
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
                        Parsing => Watch_Parsing'Access);
                  end if;
               end if;
            end;

            for Path of Dependency_Directories loop
               Check_Dependency_Path (Path);
            end loop;
            for Index in 1 .. Landin.Stages.Source_Count (Context) loop
               Check_Dependency_Path
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
                    (For_Firmware =>
                       Landin.Targets.Architecture_Of (Facts)
                         = Landin.Targets.Cortex_M0);
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
               Checking.Run (Context, Panic, Watch_Stage'Access);
               Policy_Denied := Landin.Diagnostics.Warning_Policy.Denied
                 (Warnings, Landin.Stages.Report (Context));

               --  The backend runs on nothing that was refused, for the same
               --  reason the lowering does: an unaccepted program has no Unit
               --  worth emitting, and a file written from one would be a
               --  plausible artefact of a failed compilation.
               if Emit /= Emit_Nothing
                 and then not Policy_Denied
                 and then not Bad_Use
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
                        Removed : Landin.Platform.Remove_Status;
                     begin
                        Host.Remove_File
                          (Unbounded.To_String (Intermediate_Assembly),
                           Removed);
                        if Removed = Landin.Platform.Not_Removable then
                           Note_Failure
                             (Code_Unwritable,
                              "cannot remove the intermediate assembly "
                              & Unbounded.To_String (Intermediate_Assembly)
                              & "; --keep-asm keeps it on purpose");
                        end if;
                     end;
                  end if;
                  Stage_Ended ("emission");
               elsif Emit = Emit_Nothing
                 and then not Policy_Denied
                 and then not Bad_Use
                 and then not Landin.Stages.Failed (Context)
               then
                  Check_Requested;
               end if;
            end if;
         end if;
         if Depfile /= "" and then not Dry_Run and then not Bad_Use
           and then not Policy_Denied
           and then not Landin.Stages.Failed (Context)
         then
            declare
               Text : Unbounded.Unbounded_String;
               Written : Landin.Platform.Write_Status;
               Product : constant String :=
                 (if Unbounded.Length (Output) > 0
                  then Unbounded.To_String (Output)
                  elsif Emit = Emit_Executable then Default_Executable
                  else Default_Assembly);
               procedure Append_Path (Path : String);
               procedure Append_Path (Path : String) is
               begin
                  for Byte of Path loop
                     case Byte is
                        when '$' => Unbounded.Append (Text, "$$");
                        when ' ' | ASCII.HT | '#' | ':' | '\' =>
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
               Unbounded.Append (Text, LF & "");
               Host.Write_File (Depfile, Unbounded.To_String (Text), Written);
               if Written /= Landin.Platform.Write_Ok then
                  Note_Failure (Code_Unwritable, "cannot write: " & Depfile);
               end if;
            end;
         end if;
         Write_Stage_Report;

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
         elsif Landin.Stages.Failed (Context) or else Policy_Denied then
            Result.Status := Status_Reported;
         end if;

      exception
         --  These retain the executable's dedicated host/tool outcomes.
         --  In particular, rendering a report after Storage_Error could
         --  require the same resource that has just run out.
         when Landin.Host_Exhausted | Storage_Error
            | Landin.External_Tool_Failed =>
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
            Result.Report :=
              Unbounded.To_Unbounded_String
                (Render_Report
                 & "refine: internal compiler defect in "
                 & Unbounded.To_String (Current_Stage)
                 & (if Ada.Exceptions.Exception_Message (Defect) = ""
                    then ""
                    else ": " & Ada.Exceptions.Exception_Message (Defect))
                 & LF);
            Result.Status := Status_Defect;
            Keep_Report;
      end;

      return Result;
   end Execute;

end Landin.Driver;
