with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Source;
with Landin.Stages;
with Landin.Stages.Checking;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;

package body Landin.Driver is

   package Unbounded renames Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   --  The codes come from the catalogue, which is the only place in this
   --  compiler where a code is written.  These four were literals here
   --  until R1.30 built it, and check.py now refuses a code written
   --  anywhere else.
   package Rows renames Landin.Diagnostics.Catalogue;

   --  The syntax stage holds nothing, so one instance for the process is
   --  right, and it has to outlive the access type that names it: a
   --  Stage_Reference is a library-level access type by design, because a
   --  pipeline must not be able to outlive a stage.
   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;

   Code_Unknown_Option : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Unknown_Option);
   Code_Unreadable : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Unreadable_Source);
   Code_Unknown_Target : constant Landin.Diagnostics.Code_String :=
     Rows.Code (Rows.Unknown_Target);

   function Identity return String is
     ("refine - the Landin bootstrap compiler" & LF
      & "no release version is assigned" & LF
      & "language frontend: scanner, parser, names, types" & LF
      & "targets described: linux-x86-64, synthetic-32" & LF);

   function Usage return String is
     ("usage: refine [options] [source.ldn ...]" & LF
      & LF
      & "  --help              print this text" & LF
      & "  --identify          print tool identity" & LF
      & "  --target=NAME       select a described target" & LF
      & LF
      & "Source files are scanned, parsed, resolved and checked as one"
      & LF
      & "module.  Nothing is compiled yet, so a program that is accepted"
      & LF
      & "produces no output." & LF);

   function Starts_With (Text : String; Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   ---------------------------------------------------------------------
   --  Execute
   ---------------------------------------------------------------------

   function Execute
     (Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class) return Outcome
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
      for Argument of Arguments loop
         if Argument = "--help" then
            Wants_Usage := True;

         elsif Argument = "--identify" then
            Wants_Identity := True;

         elsif Starts_With (Argument, "--target=") then
            Targets.Append
              (Argument (Argument'First + 9 .. Argument'Last));

         elsif Starts_With (Argument, "-") then
            Unknowns.Append (Argument);
            Bad_Use := True;

         else
            Inputs.Append (Argument);
         end if;
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
               Ran := Landin.Stages.Run (Line, Context);

               --  Each stage runs only when the one before it produced
               --  something worth reading: a stage stops the pipeline on
               --  its own failure, so a file with a missing `then` does not
               --  also report every name the hole swallowed, and one with
               --  an unknown name does not also report its type.
               if Ran not in 1 .. 3 then
                  raise Compiler_Defect
                    with "the frontend pipeline did not run";
               end if;
            end;
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
      end;

      return Result;
   end Execute;

end Landin.Driver;
