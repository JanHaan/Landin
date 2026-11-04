with Ada.Strings.Unbounded;

with Landin.Backend.Dispatch;
with Landin.Backend.Entry_Point;
with Landin.Backend.Images;
with Landin.Build_Reports;
with Landin.Build_Reports.Stacks;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.IR;
with Landin.IR.Pipeline;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Targets.Capabilities;
with Landin.Targets.Firmware;

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

   procedure Fit_Handler
     (Context  : in out Landin.Stages.Compilation;
      Panic    : Landin.Panics.Plan;
      Options  : Landin.Optimization.Options;
      Firmware : String)
   is
      use type Landin.IR.Item_Id;
      use type Landin.IR.Item_Kind;
      use type Landin.Backend.Images.Excess;
      Facts : constant Landin.Targets.Target_Facts :=
        Landin.Stages.Target (Context);
      Firmware_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;
      Hosted_Entry : Landin.IR.Item_Id;
      Problem : Unbounded.Unbounded_String;
      Emitted : Unbounded.Unbounded_String;
      Evidence : Landin.Build_Reports.Report;
      Measured : aliased Landin.Panics.Plan;
   begin
      if Landin.Stages.Failed (Context)
        or else Landin.Panics.Handler (Panic) = Landin.IR.No_Item
        or else not Landin.Targets.Capabilities.Emits (Facts)
        or else not Landin.Backend.Dispatch.Prepares_Stacks
          (Landin.Stages.Code (Context).all)
      then
         return;
      end if;
      declare
         Unit : Landin.IR.Unit renames Landin.Stages.Code (Context).all;
      begin
         if Firmware /= ""
           and then Landin.Targets.Is_Firmware (Facts)
         then
            Firmware_Entry := Landin.Backend.Entry_Point.Firmware_Start
              (Unit, Landin.Stages.Meanings (Context).all,
               Landin.Stages.Modules (Context).all,
               Landin.Stages.Identities (Context).all, Firmware);
            if Firmware_Entry = Landin.IR.No_Item then
               return;
            end if;
         end if;
         --  What compiling refuses before it emits is its own refusal,
         --  which a check does not raise; the handler is not judged on a
         --  program that does not reach emission.
         if Landin.Backend.Images.Exceeded
           (Landin.Backend.Images.Measure (Unit, Facts),
            (if Firmware_Entry /= Landin.IR.No_Item
             then Landin.Targets.Firmware.Budget
               (Landin.IR.Firmware_Profile (Unit))
             else Landin.Targets.Capabilities.Image_Budget_Of (Facts)))
           /= Landin.Backend.Images.Within
         then
            return;
         end if;
         for Index in 1 .. Landin.IR.Item_Count (Unit) loop
            declare
               Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            begin
               if Firmware_Entry = Landin.IR.No_Item
                 and then (Landin.IR.Placement_Of (Unit, Item).Vector /= 0
                   or else Landin.IR.Placement_Of (Unit, Item).Vector_Present)
               then
                  return;
               elsif Landin.IR.Kind_Of (Unit, Item) = Landin.IR.Routine
                 and then
                   (not Landin.Backend.Dispatch.Frame_Is_Addressable
                      (Unit, Item, Facts, Options)
                    or else
                      (Firmware_Entry /= Landin.IR.No_Item
                       and then not Landin.Backend.Dispatch
                         .Frame_Fits_Firmware_Stack (Unit, Item, Facts)))
               then
                  return;
               end if;
            end;
         end loop;
         Landin.IR.Pipeline.Run_On_Verified (Unit, Facts, Options, Evidence);
         Landin.Panics.Prepare (Context, Measured, Problem);
         if Unbounded.Length (Problem) /= 0 then
            raise Compiler_Defect with "panic plan changed after checking";
         end if;
         Hosted_Entry := Landin.Backend.Entry_Point.Hosted_Main
           (Unit, Landin.Stages.Meanings (Context).all,
            Landin.Stages.Modules (Context).all,
            Landin.Stages.Identities (Context).all);
         Landin.Backend.Dispatch.Emit
           (Unit, Landin.Stages.Meanings (Context).all,
            Landin.Stages.Identities (Context).all, Facts,
            Landin.Stages.Level (Context), Options, Emitted, Evidence,
            Hosted_Entry => Hosted_Entry, Firmware_Entry => Firmware_Entry,
            Panic => Measured'Access);
      end;
      declare
         Fit : constant Landin.Build_Reports.Stacks.Handler_Fit :=
           Landin.Build_Reports.Stacks.Fit_Handler
             (Evidence, Context, Options, Measured,
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
                 (Code    => Rows.Code (Rows.Handler_Exceeds_Stack_Margin),
                  Level   => Landin.Diagnostics.Error,
                  Source  => Fit.Site.Source,
                  Where   => Fit.Site.Where,
                  Message => Unbounded.To_String (Fit.Message)));
         end if;
      end;
   end Fit_Handler;

end Landin.Driver.Checking;
