with Landin.Backend.Entry_Point;
with Landin.Backend.Toolchain;
with Landin.Backend.X86_64;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.IR;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Stages;
with Landin.Stages.Checking;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Targets.Capabilities;

package body Landin.Driver is

   package Unbounded renames Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   --  The codes come from the catalogue, which is the only place in this
   --  compiler where a code is written.  These four were literals here
   --  until R1.30 built it, and check.py now refuses a code written
   --  anywhere else.
   package Rows renames Landin.Diagnostics.Catalogue;

   use type Landin.IR.Item_Id;
   use type Landin.IR.Item_Kind;
   use type Landin.Platform.Termination;
   use type Landin.Platform.Write_Status;
   use type Landin.Targets.Capabilities.Backend_Kind;

   --  The syntax stage holds nothing, so one instance for the process is
   --  right, and it has to outlive the access type that names it: a
   --  Stage_Reference is a library-level access type by design, because a
   --  pipeline must not be able to outlive a stage.
   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
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
   Code_Wide_Call : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Argument_Not_In_A_Register);
   Code_Wide_Frame : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Frame_Not_Addressable);

   --  What a request asked to be left behind.  Nothing is the state every
   --  request had before R1.80 and most still have: a program is read,
   --  checked and lowered, and no file is written.
   type Emit_Kind is (Emit_Nothing, Emit_Assembly, Emit_Executable);

   function Identity return String is
     ("refine - the Landin bootstrap compiler" & LF
      & "no release version is assigned" & LF
      & "language frontend: scanner, parser, names, types" & LF
      & "target-neutral IR: lowered and verified" & LF
      & "backend: linux-x86-64, straight-line kernel only" & LF
      & "toolchain: found by GNU triplet, assembles and links" & LF
      & "targets described: linux-x86-64, synthetic-32" & LF);

   function Usage return String is
     ("usage: refine [options] [source.ldn ...]" & LF
      & LF
      & "  --help              print this text" & LF
      & "  --identify          print tool identity" & LF
      & "  --target=NAME       select a described target" & LF
      & "  --emit=asm|exe      write assembly, or assemble and link" & LF
      & "  -o PATH             where to write it" & LF
      & "  --toolchain=NAME    the assembler and linker driver to run" & LF
      & "  --linker=NAME       pass -fuse-ld=NAME to that driver" & LF
      & LF
      & "Source files are scanned, parsed, resolved and checked as one"
      & LF
      & "module.  Without --emit a program that is accepted produces no"
      & LF
      & "output.  --emit=exe requires "
      & Landin.Backend.Entry_Point.Required_Shape & "." & LF
      & LF
      & "The toolchain is found by the target's GNU triplet, so"
      & LF
      & "linux-x86-64 runs x86_64-pc-linux-gnu-gcc unless --toolchain"
      & LF
      & "names another." & LF);

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
      Facts    : Landin.Targets.Target_Facts := Landin.Targets.Linux_X86_64;
      Inputs   : Landin.Platform.Path_List;
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
      Index     : Positive := 1;
   begin
      if Natural (Arguments.Length) = 0 then
         Result.Status := Status_Misuse;
         Result.Output := Unbounded.To_Unbounded_String (Usage);
         return Result;
      end if;

      --  Argument classification first, so that a request is fully known
      --  before anything is acted on.  Returning from inside this loop was
      --  a real defect: `refine --wat --identify` printed the identity and
      --  exited zero, so a script checking the status read a misuse as a
      --  success.
      --
      --  An index and not a cursor, because `-o` takes the argument after
      --  it.  Every other option carries its value with an `=`, which is
      --  the shape `--target=` set and R1.80 kept.
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

            elsif Starts_With (Argument, "--toolchain=") then
               Toolchain :=
                 Unbounded.To_Unbounded_String
                   (After (Argument, "--toolchain="));

            elsif Starts_With (Argument, "--linker=") then
               Linker :=
                 Unbounded.To_Unbounded_String
                   (After (Argument, "--linker="));

            elsif Starts_With (Argument, "--emit=") then
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

      --  Help and identity answer immediately, but only once the whole
      --  command line has been seen and found sound.
      if not Bad_Use and then (Wants_Usage or else Wants_Identity) then
         Result.Output :=
           Unbounded.To_Unbounded_String
             (if Wants_Usage then Usage else Identity);
         return Result;
      end if;

      --  The target is resolved before the compilation exists.  Creating
      --  the context first and reassigning the local afterwards was a real
      --  defect: every compilation silently carried the default target
      --  however the command line was written.
      for Name of Targets loop
         if Name = "linux-x86-64" then
            Facts := Landin.Targets.Linux_X86_64;
         elsif Name = "synthetic-32" then
            Facts := Landin.Targets.Synthetic_32;
         else
            Rejected.Append (Name);
         end if;
      end loop;

      declare
         Context : Landin.Stages.Compilation :=
           Landin.Stages.Create (Facts);

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
         begin
            --  A target nothing emits for cannot be asked for a file.
            --  `synthetic-32` exists to keep layout arithmetic honest on a
            --  64-bit host and has no backend, which is what
            --  Landin.Targets.Capabilities already says.
            if Landin.Targets.Capabilities.Backend_For (Facts)
               /= Landin.Targets.Capabilities.Linux_X86_64_ELF
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
            if Emit = Emit_Executable
              and then Landin.Backend.Entry_Point.Hosted_Main
                         (Landin.Stages.Code (Context).all,
                          Landin.Stages.Meanings (Context).all,
                          Landin.Stages.Identities (Context).all)
                       = Landin.IR.No_Item
            then
               Note_Failure
                 (Code_No_Entry,
                  "a hosted program needs "
                  & Landin.Backend.Entry_Point.Required_Shape);
               return;
            end if;

            --  [1650] hands six integer arguments in registers and the
            --  rest on the stack, and this backend has only the first
            --  half.  Nothing in the kernel bounds a parameter list, so a
            --  seventh is a program the frontend accepts and the backend
            --  cannot emit -- and an accepted program must be told what is
            --  missing rather than meeting an internal defect.  Asked here
            --  and before anything is written, for [1970]'s reason above.
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
                       and then Landin.IR.Parameter_Count (Unit, Item)
                                > Landin.Backend.X86_64.Register_Arguments
                     then
                        Note_Failure
                          (Code_Wide_Call,
                           "`"
                           & Landin.Source.Names.Spelling
                               (Spellings,
                                Landin.Resolution.Name_Of
                                  (Known,
                                   Landin.IR.Declares (Unit, Item)))
                           & "` has more parameters than the"
                           & Natural'Image
                               (Landin.Backend.X86_64.Register_Arguments)
                           & " this backend passes in registers");
                        Refused := True;
                     end if;

                     if Landin.IR.Kind_Of (Unit, Item) = Landin.IR.Routine
                       and then not Landin.Backend.X86_64.Frame_Is_Addressable
                                      (Unit, Item, Facts)
                     then
                        Note_Failure
                          (Code_Wide_Frame,
                           "`"
                           & Landin.Source.Names.Spelling
                               (Spellings,
                                Landin.Resolution.Name_Of
                                  (Known,
                                   Landin.IR.Declares (Unit, Item)))
                           & "` needs a frame outside the signed 32-bit"
                           & " offsets this backend addresses");
                        Refused := True;
                     end if;
                  end;
               end loop;

               if Refused then
                  return;
               end if;
            end;

            Host.Write_File
              (Assembly_Path,
               Landin.Backend.X86_64.Text
                 (Landin.Stages.Code (Context).all,
                  Landin.Stages.Meanings (Context).all,
                  Landin.Stages.Identities (Context).all,
                  Landin.Stages.Target (Context)),
               Written);

            if Written /= Landin.Platform.Write_Ok then
               Note_Failure
                 (Code_Unwritable, "cannot write: " & Assembly_Path);
               return;
            end if;

            if Emit /= Emit_Executable then
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
            begin
               if Driver = "" then
                  Note_No_Toolchain
                    ("target " & Landin.Targets.Name (Facts)
                     & " names no toolchain",
                     "name one with --toolchain=NAME");
                  return;
               end if;

               --  A tool that cannot be started at all is the platform
               --  interface's own distinction, and it is exactly the one a
               --  host without this target's toolchain falls on.  Catching
               --  it here is what turns "not installed" into a sentence
               --  rather than an unhandled exception at the top of
               --  `refine`.
               begin
                  Tools.Run
                    (Program   => Driver,
                     Arguments =>
                       Landin.Backend.Toolchain.Link_Arguments
                         (Assembly => Assembly_Path,
                          Output   => Target_Path,
                          Linker   => Unbounded.To_String (Linker)),
                     Result    => Ran,
                     Capture   => Landin.Platform.Merged);
               exception
                  when Landin.External_Tool_Failed =>
                     Note_No_Toolchain
                       ("cannot run " & Driver & " for target "
                        & Landin.Targets.Name (Facts),
                        "install a toolchain named " & Driver
                        & ", or name another with --toolchain=NAME");
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
         end Emit_Requested;

      begin
         for Name of Rejected loop
            Note_Failure (Code_Unknown_Target, "unknown target: " & Name);
         end loop;

         for Option of Unknowns loop
            Note_Failure (Code_Unknown_Option, "unknown option: " & Option);
         end loop;

         for Path of Inputs loop
            declare
               Content : Unbounded.Unbounded_String;
               Status  : Landin.Platform.Read_Status;
            begin
               Host.Read_File (Path, Content, Status);

               case Status is
                  when Landin.Platform.Read_Ok =>
                     declare
                        Id : constant Landin.Source.Source_Id :=
                          Landin.Stages.Add_Source
                            (Context, Path, Unbounded.To_String (Content));
                        pragma Unreferenced (Id);
                     begin
                        null;
                     end;

                  when Landin.Platform.Not_Found =>
                     Note_Failure
                       (Code_Unreadable, "source not found: " & Path);

                  when Landin.Platform.Not_Readable =>
                     Note_Failure
                       (Code_Unreadable, "source not readable: " & Path);
               end case;
            end;
         end loop;

         --  Every source that was read is scanned and parsed together, as
         --  one compilation: the language is checked whole, and a stage
         --  that saw one file at a time could not be replaced later by one
         --  that resolves a name across two.
         if Landin.Stages.Source_Count (Context) > 0 then
            declare
               Line : Landin.Stages.Pipeline;
               Ran  : Natural;
            begin
               Landin.Stages.Append (Line, Frontend'Access);
               Landin.Stages.Append (Line, Names'Access);
               Landin.Stages.Append (Line, Checker'Access);
               Landin.Stages.Append (Line, Lowerer'Access);
               Ran := Landin.Stages.Run (Line, Context);

               --  Each stage runs only when the one before it produced
               --  something worth reading: a stage stops the pipeline on
               --  its own failure, so a file with a missing `then` does not
               --  also report every name the hole swallowed, and one with
               --  an unknown name does not also report its type.  Four
               --  since R1.70: the lowering is the last, and it refuses to
               --  run on a refused program itself rather than relying on
               --  being queued after the checker.
               if Ran not in 1 .. 4 then
                  raise Compiler_Defect
                    with "the frontend pipeline did not run";
               end if;
            end;

            --  The backend runs on nothing that was refused, for the same
            --  reason the lowering does: an unaccepted program has no Unit
            --  worth emitting, and a file written from one would be a
            --  plausible artefact of a failed compilation.
            if Emit /= Emit_Nothing
              and then not Landin.Stages.Failed (Context)
            then
               Emit_Requested;
            end if;
         end if;

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

         if Bad_Use then
            Result.Status := Status_Misuse;
         elsif Landin.Stages.Failed (Context) then
            Result.Status := Status_Reported;
         end if;

      exception
         --  A defect is the compiler finding itself wrong, and it arrives
         --  after the run has usually already decided several things about
         --  the source.  Letting it escape threw those away and left a
         --  reader with one sentence about the compiler and nothing about
         --  their program; twice in one afternoon that sentence was the
         --  only thing a refused field produced.  So the report is
         --  rendered from what the context holds, the defect is written
         --  under it, and the status says which of the two happened.
         when Landin.Compiler_Defect =>
            Result.Report :=
              Unbounded.To_Unbounded_String
                (Landin.Stages.Rendered_Report (Context)
                 & "refine: internal compiler defect" & LF);
            Result.Status := Status_Defect;
      end;

      return Result;
   end Execute;

end Landin.Driver;
