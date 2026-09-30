with Ada.Exceptions;
with Ada.Strings.Fixed;

with Landin.Backend.Entry_Point;
with Landin.Backend.Firmware;
with Landin.Backend.Toolchain;
with Landin.Backend.Dispatch;
with Landin.Build_Reports;
with Landin.Build_Reports.Sources;
with Landin.Checking;
with Landin.Configuration;
with Landin.Debugging;
with Landin.IR.Simplification;
with Landin.IR.Specialization;
with Landin.Optimization;
with Landin.Panics;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Explanations;
with Landin.Diagnostics.Text;
with Landin.Driver.Loading;
with Landin.Formatting;
with Landin.IR;
with Landin.Modules;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Source_Maps;
with Landin.Stages;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Targets.Capabilities;

package body Landin.Driver is

   use type Landin.Targets.Architecture;

   package Unbounded renames Ada.Strings.Unbounded;

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
   use type Landin.Targets.Capabilities.Backend_Kind;
   use type Landin.Targets.Capabilities.Debug_Format;

   --  The syntax stage holds nothing, so one instance for the process is
   --  right, and it has to outlive the access type that names it: a
   --  Stage_Reference is a library-level access type by design, because a
   --  pipeline must not be able to outlive a stage.
   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;
   Lowerer  : aliased Landin.Stages.Lowering.Instance;

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

   --  What a request asked to be left behind.  Nothing is the state every
   --  request had before the native path and most still have: a program is
   --  read, checked and lowered, and no file is written.
   type Emit_Kind is (Emit_Nothing, Emit_Assembly, Emit_Executable);

   function Identity return String is
     ("refine - the Landin bootstrap compiler" & LF
      & "no release version is assigned" & LF
      & "language frontend: scanner, parser, names, types, definite assignment"
      & LF
      & "target-neutral IR: lowered and verified" & LF
      & "backends: linux-x86-64, darwin-arm64 and cortex-m0 assembly" & LF
      & "executable output: assembled and linked by a"
      & " target-selected native toolchain" & LF
      & "targets described: linux-x86-64, darwin-arm64, cortex-m0, "
      & "synthetic-32" & LF);

   function Usage return String is
     ("usage: refine [options] [source.ldn ...]" & LF
      & "       refine explain [CODE ...]" & LF
      & "       refine fmt [--check] source.ldn ..." & LF
      & LF
      & "  --help              print this text" & LF
      & "  --identify          print tool identity" & LF
      & "  --target=NAME       select a described target" & LF
      & "  --option=NAME=VALUE set a declared fixed build option" & LF
      & "  --build-mode=NAME   debug (default) or release" & LF
      & "  --optimize=NAME     none, size (default), or speed" & LF
      & "  --specialize=NAME   off, auto (default), or all" & LF
      & "  --panic-map         emit off-target check-site mapping" & LF
      & "  --debug=NAME        none (default), full (hosted),"
      & " lines (Cortex-M0)" & LF
      & "  --build-report=PATH write deterministic build evidence JSON" & LF
      & "  --stage-report=PATH write each stage's measured time and memory"
      & LF
      & "  --root=DIR          append an ordered module import root" & LF
      & "  --emit=asm|exe      write assembly, or assemble and link" & LF
      & "  -o PATH             where to write it" & LF
      & "  --toolchain=NAME    the assembler and linker driver to run" & LF
      & "  --linker=NAME       pass -fuse-ld=NAME to that driver" & LF
      & "  --firmware-entry=NAME  Cortex entry-module routine, no results"
      & LF
      & LF
      & "Source files are scanned, parsed, resolved and checked as one"
      & LF
      & "module. With --root, pass one entry-module directory; its imports"
      & LF
      & "are found under the roots in option order. Without --emit a program"
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
      & "with --check it writes nothing and reports each source that is"
      & LF
      & "not in it." & LF
      & LF
      & "The toolchain is found by the target's GNU triplet, so"
      & LF
      & "linux-x86-64 runs x86_64-pc-linux-gnu-gcc unless --toolchain"
      & LF
      & "names another." & LF);

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
      Check   : Boolean := False;
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

      --  L0008 at the first line whose bytes the layout changes, found by
      --  reading the source and the formatted text line by line.  A line
      --  the source has and the layout drops is changed too.
      procedure Not_Formatted (Answer : Landin.Formatting.Result);

      procedure Not_Formatted (Answer : Landin.Formatting.Result) is
         Snapshot : Landin.Source.Snapshot renames
           Sources.Get (Answer.Id).Element.all;
         Formatted : constant String := Unbounded.To_String (Answer.Text);

         function Changed_Line return Landin.Source.Line_Number;

         function Changed_Line return Landin.Source.Line_Number is
            Cursor : Natural := Formatted'First;
         begin
            for Line in 1 .. Landin.Source.Line_Count (Snapshot) loop
               declare
                  Was  : constant String :=
                    Landin.Source.Line_Text (Snapshot, Line);
                  Stop : Natural :=
                    Ada.Strings.Fixed.Index (Formatted, [LF], Cursor);
               begin
                  if Stop = 0 then
                     Stop := Formatted'Last + 1;
                  end if;
                  if Cursor > Formatted'Last
                    or else Formatted (Cursor .. Stop - 1) /= Was
                  then
                     return Line;
                  end if;
                  Cursor := Stop + 1;
               end;
            end loop;
            return Landin.Source.Line_Count (Snapshot);
         end Changed_Line;

         Line : constant Landin.Source.Line_Number := Changed_Line;
         Item : Landin.Diagnostics.Diagnostic := Landin.Diagnostics.Make
           (Code    => Rows.Code (Rows.Not_Formatted),
            Level   => Landin.Diagnostics.Error,
            Source  => Answer.Id,
            Where   => Landin.Source.Line_Text_Span (Snapshot, Line),
            Message => "this source is not in the layout");
      begin
         Landin.Diagnostics.Add_Note
           (Item, "D252: `refine fmt` puts it in the layout and changes"
                  & " only its space");
         Found.Append (Item);
      end Not_Formatted;
   begin
      for Index in 2 .. Natural (Arguments.Length) loop
         declare
            Argument : constant String := Arguments.Element (Index);
         begin
            if Argument = "--check" and then not Check then
               Check := True;
            elsif Argument'Length > 0
              and then Argument (Argument'First) = '-'
            then
               Misused := True;
               Refuse (Code_Unknown_Option,
                       "fmt takes no option but --check, once: " & Argument);
            elsif Host.Is_Directory (Argument) then
               Misused := True;
               Refuse (Code_Unknown_Option,
                       "fmt formats files, not directories: " & Argument);
            elsif Named.Contains (Argument) then
               Misused := True;
               Refuse (Code_Unknown_Option,
                       "fmt is given one source twice: " & Argument);
            else
               Named.Append (Argument);
            end if;
         end;
      end loop;
      if Named.Is_Empty and then not Misused then
         Misused := True;
         Refuse (Code_Unknown_Option, "fmt needs a source to format");
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
                  begin
                     Result.Named.Append (Path);
                     for Position in 1 .. Answer.Found.Count loop
                        Found.Append (Answer.Found.Get (Position));
                     end loop;
                     if Answer.Outcome = Landin.Formatting.Refused
                       or else Answer.Edits.Is_Empty
                     then
                        null;
                     elsif Check then
                        Not_Formatted (Answer);
                     else
                        Host.Write_File
                          (Path, Unbounded.To_String (Answer.Text), Written);
                        if Written /= Landin.Platform.Write_Ok then
                           Refuse (Code_Unwritable, "cannot write: " & Path);
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end if;

      Result.Found := Found;
      Result.Report := Unbounded.To_Unbounded_String
        (Landin.Diagnostics.Text.Render (Found, Sources));
      Result.Status :=
        (if Misused then Status_Misuse
         elsif Found.Has_Errors then Status_Reported
         else Status_Success);
      return Result;
   end Format;

   function Starts_With (Text : String; Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

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
      Meter     : Landin.Platform.Resource_Meter'Class) return Outcome
   is
      Facts    : Landin.Targets.Target_Facts := Landin.Targets.Linux_X86_64;
      Inputs   : Landin.Platform.Path_List;
      Roots    : Landin.Platform.Path_List;
      Options  : Landin.Platform.Path_List;
      Modes    : Landin.Platform.Path_List;
      Result   : Outcome;
      Bad_Use  : Boolean := False;
      Unknowns : Landin.Platform.Path_List;
      Targets  : Landin.Platform.Path_List;
      Rejected : Landin.Platform.Path_List;
      Wants_Usage    : Boolean := False;
      Wants_Identity : Boolean := False;
      Emit      : Emit_Kind := Emit_Nothing;
      Output    : Unbounded.Unbounded_String;
      Toolchain : Unbounded.Unbounded_String;
      Linker    : Unbounded.Unbounded_String;
      Firmware_Name : Unbounded.Unbounded_String;
      Firmware_Seen : Boolean := False;
      Build_Report_Path : Unbounded.Unbounded_String;
      Stage_Report_Path : Unbounded.Unbounded_String;
      Stage_Report_Seen : Boolean := False;
      Optimization : Landin.Optimization.Options :=
        Landin.Optimization.Default_Options;
      Optimize_Seen, Specialize_Seen, Report_Seen : Boolean := False;
      Debug_Seen, Debug_Enabled : Boolean := False;
      Lines_Debug : Boolean := False;
      Panic_Map : Boolean := False;
      Emit_Seen, Output_Seen : Boolean := False;
      Index     : Positive := 1;
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
      end if;

      --  Argument classification first, so that a request is fully known
      --  before anything is acted on.  Returning from inside this loop was
      --  a real defect: `refine --wat --identify` printed the identity and
      --  exited zero, so a script checking the status read a misuse as a
      --  success.
      --
      --  An index and not a cursor, because `-o` takes the argument after
      --  it.  Every other option carries its value with an `=`, which is
      --  the shape `--target=` set and every later option kept.
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

            elsif Starts_With (Argument, "--root=") then
               Roots.Append (After (Argument, "--root="));

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
               Toolchain :=
                 Unbounded.To_Unbounded_String
                   (After (Argument, "--toolchain="));

            elsif Starts_With (Argument, "--linker=") then
               Linker :=
                 Unbounded.To_Unbounded_String
                   (After (Argument, "--linker="));

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
                  else
                     Unknowns.Append (Argument);
                     Bad_Use := True;
                  end if;
               end;

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

      --  Compilation controls do not modify informational actions, and a
      --  build report describes an emitted artifact, not a checking request.
      if ((Optimize_Seen or Specialize_Seen or Report_Seen
           or Debug_Seen or Panic_Map or Stage_Report_Seen)
          and then (Wants_Usage or Wants_Identity))
        or else ((Report_Seen or Debug_Seen or Firmware_Seen or Panic_Map)
                 and then Emit = Emit_Nothing)
        or else ((Optimize_Seen or Specialize_Seen)
                 and then Natural (Inputs.Length) = 0)
        or else (Output_Seen and then
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
         if Name = "linux-x86-64" then
            Facts := Landin.Targets.Linux_X86_64;
         elsif Name = "darwin-arm64" then
            Facts := Landin.Targets.Darwin_Arm64;
         elsif Name = "cortex-m0" then
            Facts := Landin.Targets.Cortex_M;
         elsif Name = "synthetic-32" then
            Facts := Landin.Targets.Synthetic_32;
         else
            Rejected.Append (Name);
         end if;
      end loop;

      declare
         Context : Landin.Stages.Compilation :=
           Landin.Stages.Create (Facts);
         Panic : aliased Landin.Panics.Plan;
         Panic_Problem : Unbounded.Unbounded_String;

         procedure Keep_Report;

         --  The report as data beside its rendering, sorted as it was
         --  rendered, and every source's name so a Source_Id means a path.
         procedure Keep_Report is
         begin
            Result.Found :=
              Landin.Diagnostics.Sorted (Landin.Stages.Report (Context));
            for Index in 1 .. Landin.Stages.Source_Count (Context) loop
               Result.Named.Append
                 (Landin.Source.Name
                    (Landin.Stages.Source
                       (Context,
                        Landin.Stages.Nth_Source (Context, Index))
                       .Element.all));
            end loop;
         end Keep_Report;

         procedure Note_Failure
           (Code : Landin.Diagnostics.Code_String; Text : String);

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

         --  `--stage-report`: one row per stage, each the processor time
         --  spent in it and the process's peak resident set when it ended.
         --  The peak is a high-water mark, so the stage that raised it is
         --  the one whose row first shows the new value.
         Stage_Rows : Unbounded.Unbounded_String;
         Stage_Start : Landin.Platform.Resource_Sample;

         procedure Stage_Began;
         procedure Stage_Ended (Name : String);
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
         begin
            if not Stage_Report_Seen then
               return;
            end if;
            Now := Meter.Sample;
            if Unbounded.Length (Stage_Rows) > 0 then
               Unbounded.Append (Stage_Rows, "," & LF);
            end if;
            Unbounded.Append
              (Stage_Rows,
               "    {""stage"":""" & Name & """,""processor_us"":"
               & Image (Now.Processor_Microseconds
                        - Stage_Start.Processor_Microseconds)
               & ",""peak_kib"":" & Image (Now.Peak_Resident_KiB) & "}");
         end Stage_Ended;

         procedure Watch_Stage (Name : String; Finished : Boolean) is
         begin
            if Finished then
               Stage_Ended (Name);
            else
               Stage_Began;
            end if;
         end Watch_Stage;

         --  Written whenever the request was well formed, a refused program
         --  included: where a refusal's time and storage went is exactly
         --  what a bound is measured by.  The sizes are the compilation's
         --  own counts and are the same on every run; the rows are not.
         procedure Write_Stage_Report is
            Path : constant String := Unbounded.To_String (Stage_Report_Path);
            Written : Landin.Platform.Write_Status;
            Nodes : Natural := 0;
            function Image (Value : Natural) return String is
              (Ada.Strings.Fixed.Trim
                 (Natural'Image (Value), Ada.Strings.Both));
         begin
            if not Stage_Report_Seen or else Bad_Use then
               return;
            end if;
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
               else Default_Assembly);

            Written : Landin.Platform.Write_Status;
            Map_Id : Unbounded.Unbounded_String;
            Evidence : Landin.Build_Reports.Report;
            Product_Path : constant String :=
              (if Unbounded.Length (Output) > 0
               then Unbounded.To_String (Output)
               elsif Emit = Emit_Executable then Default_Executable
               else Default_Assembly);
            Map_Path : constant String := Source_Map_Beside (Product_Path);
            Report_Path : constant String :=
              Unbounded.To_String (Build_Report_Path);
            Emit_Map : constant Boolean := Debug_Enabled or else Panic_Map
              or else Landin.IR.Caller_Source_Count
                (Landin.Stages.Code (Context).all) > 0;
            Destinations : Landin.Platform.Path_List;
            Cortex : constant Boolean :=
              Landin.Targets.Architecture_Of (Facts)
                = Landin.Targets.Cortex_M0;
            Firmware_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;

            function Conflicts_With (Path : String) return Boolean is
              (Host.Paths_Overlap (Report_Path, Path));

            procedure Write_Build_Report;

            procedure Write_Build_Report is
            begin
               if Report_Seen and then not Landin.Stages.Failed (Context) then
                  Host.Write_File
                    (Report_Path,
                     Landin.Build_Reports.Sources.JSON
                       (Evidence, Context, Optimization), Written);
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
               for Index in 1 .. Landin.Stages.Source_Count (Context) loop
                  declare
                     Path : constant String := Landin.Source.Name
                       (Landin.Stages.Source
                          (Context,
                           Landin.Stages.Nth_Source (Context, Index)));
                  begin
                     if Conflicts_With (Path) then
                        Bad_Use := True;
                        Note_Failure
                          (Code_Unknown_Option,
                           "build report collides with source: "
                           & Report_Path);
                        return;
                     end if;
                  end;
               end loop;
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
               for Source in 1 .. Landin.Stages.Source_Count (Context) loop
                  if Host.Paths_Overlap
                    (Destinations (Index), Landin.Source.Name
                       (Landin.Stages.Source
                          (Context,
                           Landin.Stages.Nth_Source (Context, Source))))
                    or else (Emit = Emit_Executable and then Debug_Enabled
                      and then Landin.Backend.Toolchain.Debug_Overwrites
                        (Product_Path, Landin.Source.Name
                           (Landin.Stages.Source (Context,
                             Landin.Stages.Nth_Source (Context, Source))),
                         Facts, Host))
                  then
                     Bad_Use := True;
                     Note_Failure
                       (Code_Unknown_Option,
                        "artifact collides with source: "
                        & Destinations (Index));
                     return;
                  end if;
               end loop;
            end loop;

            if Debug_Enabled and then
              (Landin.Targets.Capabilities.Debug_Format_Of (Facts)
                 = Landin.Targets.Capabilities.No_Debug_Format
               or else Lines_Debug /= Cortex)
            then
               Note_No_Toolchain
                 ("unsupported source debugger mode for target "
                  & Landin.Targets.Name (Facts),
                  (if Cortex then "use --debug=lines or --debug=none"
                   else "use --debug=full or --debug=none"));
               return;
            end if;

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
            if Firmware_Seen and then not Cortex then
               Bad_Use := True;
               Note_Failure
                 (Code_Unknown_Option,
                  "--firmware-entry requires --target=cortex-m0");
               return;
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
                     "only the selected private Arm runtime is linked");
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
            end if;

            Landin.Build_Reports.Clear (Evidence);
            Landin.IR.Specialization.Run
              (Landin.Stages.Code (Context).all, Facts,
               Optimization, Evidence);
            Landin.IR.Simplification.Run
              (Landin.Stages.Code (Context).all, Facts,
               Optimization.Optimize);

            --  Specialization can expose an additional atom domain. The
            --  selected source identity and source-byte spaces stay fixed;
            --  refresh physical atom codes against the final unit.
            Landin.Panics.Prepare (Context, Panic, Panic_Problem);
            if Unbounded.Length (Panic_Problem) /= 0 then
               raise Compiler_Defect with "panic plan changed after checking";
            end if;

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
                     end if;
                  end;
               end loop;

               if Refused then
                  return;
               end if;
            end;

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
                  Optimization, Emitted, Evidence,
                  Hosted_Entry => Landin.Backend.Entry_Point.Hosted_Main
                    (Landin.Stages.Code (Context).all,
                     Landin.Stages.Meanings (Context).all,
                     Landin.Stages.Modules (Context).all,
                     Landin.Stages.Identities (Context).all),
                  Debug => (if Debug_Enabled then Debug'Access else null),
                  Firmware_Entry => Firmware_Entry, Panic => Panic'Access);
               if Emit_Map then
                  declare
                     Map : constant Landin.Source_Maps.Artifact :=
                       Landin.Source_Maps.Create
                         (Context, Unbounded.To_String (Emitted),
                          All_Sources => Debug_Enabled,
                          Panic => (if Panic_Map then Panic'Access else null));
                  begin
                     Emitted := Map.Assembly;
                     Map_Id := Unbounded.To_Unbounded_String (Map.Build_Id);
                     Host.Write_File
                       (Map_Path, Unbounded.To_String (Map.JSON), Written);
                     if Written /= Landin.Platform.Write_Ok then
                        Note_Failure
                          (Code_Unwritable, "cannot write: " & Map_Path);
                        return;
                     end if;
                  end;
               end if;
               Host.Write_File
                 (Assembly_Path, Unbounded.To_String (Emitted), Written);
               if Written /= Landin.Platform.Write_Ok then
                  Note_Failure
                    (Code_Unwritable, "cannot write: " & Assembly_Path);
                  return;
               end if;
            end;

            if Emit /= Emit_Executable then
               Write_Build_Report;
               return;
            end if;

            declare
               Driver : constant String :=
                 Landin.Backend.Toolchain.Driver_For
                   (Facts, Unbounded.To_String (Toolchain));
               Target_Path : constant String :=
                 (if Unbounded.Length (Output) > 0
                  then Unbounded.To_String (Output)
                  else Default_Executable);
               Ran : Landin.Platform.Tool_Result;
               Libraries : Landin.Platform.Path_List;
               Libraries_Ready : Boolean;
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
                           Debug => Debug_Enabled),
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
                  Tools.Run
                    (Program   => Driver,
                     Arguments =>
                       Landin.Backend.Toolchain.Link_Arguments
                         (Assembly => Assembly_Path,
                          Output   => Target_Path,
                          Linker   => Unbounded.To_String (Linker),
                          Build_Id => Unbounded.To_String (Map_Id),
                          Full_Debug => Debug_Enabled,
                          Libraries => Libraries, Facts => Facts),
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
                           Note_No_Toolchain
                             ("cannot run " & Driver & " for target "
                              & Landin.Targets.Name (Facts),
                              "install a toolchain named " & Driver
                              & ", or name another with --toolchain=NAME");
                        else
                           Note_Failure
                             (Code_Toolchain_Failed,
                              Driver & " could not be run to completion: "
                              & Why);
                        end if;
                     end;
                     return;
               end;

               --  How the run ended is asked before what it returned,
               --  because a tool a signal killed has no status and the
               --  field beside it holds zero.  Reading that alone would
               --  make a dead assembler a success that wrote nothing.
               if Ran.Ended /= Landin.Platform.Exited then
                  Note_Failure
                    (Code_Toolchain_Failed,
                     Driver & " was stopped before it could finish" & LF
                     & Unbounded.To_String (Ran.Output));
               elsif Ran.Exit_Code /= 0 then
                  Note_Failure
                    (Code_Toolchain_Failed,
                     Driver & " failed with status"
                     & Integer'Image (Ran.Exit_Code) & LF
                     & Unbounded.To_String (Ran.Output));
               end if;
            end;
            Write_Build_Report;
         end Emit_Requested;

      begin
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
                  for Index in Option'First .. Separator - 1 loop
                     if Option (Index) not in 'a' .. 'z' | '_'
                       and then (Index = Option'First
                                 or else Option (Index) not in '0' .. '9')
                     then
                        Valid := False;
                     end if;
                  end loop;
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

         for Name of Rejected loop
            Note_Failure (Code_Unknown_Target, "unknown target: " & Name);
         end loop;

         for Option of Unknowns loop
            Note_Failure (Code_Unknown_Option, "unknown option: " & Option);
         end loop;

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

         if Natural (Roots.Length) > 0
           and then Natural (Inputs.Length) /= 1
         then
            Bad_Use := True;
            Note_Failure
              (Code_Unknown_Option,
               "a rooted module request needs exactly one entry directory");
         end if;

         --  Informational actions wait for every command-line validation,
         --  but do not discover or read sources, or run compiler stages.
         if Wants_Usage or else Wants_Identity then
            if Bad_Use or else Landin.Stages.Failed (Context) then
               Result.Report := Unbounded.To_Unbounded_String
                 (Landin.Stages.Rendered_Report (Context));
               Keep_Report;
               Result.Status :=
                 (if Bad_Use then Status_Misuse else Status_Reported);
            else
               Result.Output := Unbounded.To_Unbounded_String
                 (if Wants_Usage then Usage else Identity);
            end if;
            return Result;
         end if;

         Stage_Began;
         if Natural (Roots.Length) > 0 then
            if Natural (Inputs.Length) = 1 then
               Loading.Load_Reachable_Program
                 (Context, Host, Roots, Inputs.Element (1));
            end if;
         else
            Loading.Load_Files (Context, Host, Inputs);
         end if;

         --  A rooted request scans and parses each module as it is found,
         --  to read its imports, so its syntax is inside this row.
         Stage_Ended ("loading");

         --  Every source that was read is scanned and parsed together, as
         --  one compilation: the language is checked whole, and a stage
         --  that saw one file at a time could not be replaced later by one
         --  that resolves a name across two.
         if Landin.Stages.Source_Count (Context) > 0
           and then not Landin.Stages.Failed (Context)
         then
            declare
               Line : Landin.Stages.Pipeline;
               Ran  : Natural;
            begin
               Landin.Stages.Append (Line, Frontend'Access);
               Landin.Stages.Append (Line, Configurer'Access);
               Landin.Stages.Append (Line, Names'Access);
               Landin.Stages.Append (Line, Checker'Access);
               Landin.Stages.Append (Line, Lowerer'Access);
               Ran := Landin.Stages.Run
                 (Line, Context, Watch_Stage'Access);

               --  Each stage runs only when the one before it produced
               --  something worth reading: a stage stops the pipeline on
               --  its own failure, so a file with a missing `then` does not
               --  also report every name the hole swallowed, and one with
               --  an unknown name does not also report its type.  Four
               --  since the lowering joined: it is the last, and it refuses to
               --  run on a refused program itself rather than relying on
               --  being queued after the checker.
               if Ran not in 1 .. 5 then
                  raise Compiler_Defect
                    with "the frontend pipeline did not run";
               end if;
            end;

            if not Landin.Stages.Failed (Context) then
               Landin.Panics.Prepare (Context, Panic, Panic_Problem);
               if Unbounded.Length (Panic_Problem) /= 0 then
                  Note_Failure
                    (Rows.Code (Rows.Panic_Contract_Invalid),
                     Unbounded.To_String (Panic_Problem));
               end if;
            end if;

            --  The backend runs on nothing that was refused, for the same
            --  reason the lowering does: an unaccepted program has no Unit
            --  worth emitting, and a file written from one would be a
            --  plausible artefact of a failed compilation.
            if Emit /= Emit_Nothing
              and then not Landin.Stages.Failed (Context)
            then
               Stage_Began;
               Emit_Requested;
               Stage_Ended ("emission");
            end if;
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
             (Landin.Stages.Rendered_Report (Context));
         Keep_Report;

         if Bad_Use then
            Result.Status := Status_Misuse;
         elsif Landin.Stages.Failed (Context) then
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
         when others =>
            Result.Report :=
              Unbounded.To_Unbounded_String
                (Landin.Stages.Rendered_Report (Context)
                 & "refine: internal compiler defect" & LF);
            Result.Status := Status_Defect;
      end;

      return Result;
   end Execute;

end Landin.Driver;
