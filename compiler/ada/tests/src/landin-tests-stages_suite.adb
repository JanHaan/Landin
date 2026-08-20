with Landin.Diagnostics;
with Landin.Source;
with Landin.Stages;
with Landin.Targets;

package body Landin.Tests.Stages_Suite is

   use type Landin.Source.Source_Id;

   LF : constant Character := Character'Val (10);

   --  Fake stages.  They exist to prove the seam runs stages in order and
   --  stops when one says so; none of them knows anything about Landin.
   type Counting_Stage is limited new Landin.Stages.Stage with null record;

   overriding function Name (Item : Counting_Stage) return String;

   overriding procedure Run
     (Item    : Counting_Stage;
      Context : in out Landin.Stages.Compilation;
      Outcome : out Landin.Stages.Stage_Outcome);

   overriding function Name (Item : Counting_Stage) return String is
      pragma Unreferenced (Item);
   begin
      return "counting";
   end Name;

   overriding procedure Run
     (Item    : Counting_Stage;
      Context : in out Landin.Stages.Compilation;
      Outcome : out Landin.Stages.Stage_Outcome)
   is
      pragma Unreferenced (Item);
      Ignored : Landin.Source.Source_Id;
   begin
      Ignored := Landin.Stages.Add_Source (Context, "stage.ldn", "x");
      pragma Assert (Ignored /= Landin.Source.No_Source);
      Outcome := Landin.Stages.Continue;
   end Run;

   type Refusing_Stage is limited new Landin.Stages.Stage with null record;

   overriding function Name (Item : Refusing_Stage) return String;

   overriding procedure Run
     (Item    : Refusing_Stage;
      Context : in out Landin.Stages.Compilation;
      Outcome : out Landin.Stages.Stage_Outcome);

   overriding function Name (Item : Refusing_Stage) return String is
      pragma Unreferenced (Item);
   begin
      return "refusing";
   end Name;

   overriding procedure Run
     (Item    : Refusing_Stage;
      Context : in out Landin.Stages.Compilation;
      Outcome : out Landin.Stages.Stage_Outcome)
   is
      pragma Unreferenced (Item);
   begin
      Landin.Stages.Report
        (Context,
         Landin.Diagnostics.Make
           ("L0900", Landin.Diagnostics.Error, Landin.Source.No_Source,
            Landin.Source.Empty_Span, "the fake stage refused"));
      Outcome := Landin.Stages.Stop;
   end Run;

   Counter : aliased constant Counting_Stage := (null record);
   Refuser : aliased constant Refusing_Stage := (null record);

   procedure Context_Carries_Target_And_Sources
     (Item : in out Landin.Testing.Context);

   procedure Context_Carries_Target_And_Sources
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Synthetic_32);
      Id   : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "a.ldn", "abc");
   begin
      Landin.Testing.Check_Equal
        (Item,
         Landin.Targets.Name (Landin.Stages.Target (Work)),
         "synthetic-32",
         "the context keeps the target it was created for");
      Landin.Testing.Check_Equal
        (Item, Landin.Stages.Source_Count (Work), 1, "one source");
      Landin.Testing.Check_Equal
        (Item,
         Landin.Source.Text (Landin.Stages.Source (Work, Id)),
         "abc", "the source text is reachable");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a fresh context has not failed");
   end Context_Carries_Target_And_Sources;

   procedure Pipeline_Stops_At_A_Refusal
     (Item : in out Landin.Testing.Context);

   procedure Pipeline_Stops_At_A_Refusal
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
   begin
      Landin.Stages.Append (Order, Counter'Access);
      Landin.Stages.Append (Order, Refuser'Access);
      Landin.Stages.Append (Order, Counter'Access);

      Landin.Testing.Check_Equal
        (Item, Landin.Stages.Length (Order), 3, "three stages are queued");

      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal
        (Item, Ran, 2, "the stage after a refusal does not run");
      Landin.Testing.Check_Equal
        (Item, Landin.Stages.Source_Count (Work), 1,
         "only the first stage added a source");
      Landin.Testing.Check
        (Item, Landin.Stages.Failed (Work), "the refusal was reported");
   end Pipeline_Stops_At_A_Refusal;

   procedure Reports_Render_Against_Their_Sources
     (Item : in out Landin.Testing.Context);

   procedure Reports_Render_Against_Their_Sources
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Id   : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "r.ldn", "abc");
   begin
      Landin.Stages.Report
        (Work,
         Landin.Diagnostics.Make
           ("L0901", Landin.Diagnostics.Error, Id,
            (First => 1, Last => 2), "middle byte"));

      --  Exactly, and against the source the context holds: a check that
      --  only looked at the first five characters passed even when the
      --  report was rendered against no sources at all.
      declare
         Expected : constant String :=
           "error[L0901]: middle byte" & LF
           & "  --> r.ldn:1:2" & LF
           & "  |" & LF
           & "1 | abc" & LF
           & "  |  ^" & LF;
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Stages.Rendered_Report (Work), Expected,
            "a report renders against the context's own sources");
      end;
   end Reports_Render_Against_Their_Sources;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "stages", "context carries target and sources",
         Context_Carries_Target_And_Sources'Access);
      Landin.Testing.Register
        (Into, "stages", "pipeline stops at a refusal",
         Pipeline_Stops_At_A_Refusal'Access);
      Landin.Testing.Register
        (Into, "stages", "reports render against their sources",
         Reports_Render_Against_Their_Sources'Access);
   end Register;

end Landin.Tests.Stages_Suite;
