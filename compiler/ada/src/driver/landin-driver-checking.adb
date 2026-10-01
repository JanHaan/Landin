with Ada.Strings.Unbounded;

with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;

package body Landin.Driver.Checking is

   package Unbounded renames Ada.Strings.Unbounded;
   package Rows renames Landin.Diagnostics.Catalogue;

   --  The stages hold nothing, so one instance for the process is right,
   --  and each has to outlive the access type that names it: a
   --  Stage_Reference is a library-level access type by design, because a
   --  pipeline must not be able to outlive a stage.
   Frontend   : aliased Landin.Stages.Syntax.Instance;
   Names      : aliased Landin.Stages.Resolution.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Checker    : aliased Landin.Stages.Checking.Instance;
   Lowerer    : aliased Landin.Stages.Lowering.Instance;

   procedure Ignore (Name : String; Finished : Boolean) is null;

   procedure Run
     (Context : in out Landin.Stages.Compilation;
      Panic   : out Landin.Panics.Plan;
      Watch   : not null access procedure
        (Name : String; Finished : Boolean))
   is
      Line    : Landin.Stages.Pipeline;
      Ran     : Natural;
      Problem : Unbounded.Unbounded_String;
   begin
      Landin.Stages.Append (Line, Frontend'Access);
      Landin.Stages.Append (Line, Configurer'Access);
      Landin.Stages.Append (Line, Names'Access);
      Landin.Stages.Append (Line, Checker'Access);
      Landin.Stages.Append (Line, Lowerer'Access);
      Ran := Landin.Stages.Run (Line, Context, Watch);

      --  Each stage runs only when the one before it produced something
      --  worth reading: a stage stops the pipeline on its own failure, so
      --  a file with a missing `then` does not also report every name the
      --  hole swallowed, and one with an unknown name does not also report
      --  its type.  Five since the lowering joined: it is the last, and it
      --  refuses to run on a refused program itself rather than relying on
      --  being queued after the checker.
      if Ran not in 1 .. 5 then
         raise Compiler_Defect with "the frontend pipeline did not run";
      end if;

      if not Landin.Stages.Failed (Context) then
         Landin.Panics.Prepare (Context, Panic, Problem);
         if Unbounded.Length (Problem) /= 0 then
            Landin.Stages.Report
              (Context,
               Landin.Diagnostics.Make
                 (Code    => Rows.Code (Rows.Panic_Contract_Invalid),
                  Level   => Landin.Diagnostics.Error,
                  Source  => Landin.Source.No_Source,
                  Where   => Landin.Source.Empty_Span,
                  Message => Unbounded.To_String (Problem)));
         end if;
      end if;
   end Run;

   procedure Run
     (Context : in out Landin.Stages.Compilation;
      Panic   : out Landin.Panics.Plan) is
   begin
      Run (Context, Panic, Ignore'Access);
   end Run;

end Landin.Driver.Checking;
