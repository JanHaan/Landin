with Landin.Diagnostics.Text;

package body Landin.Stages is

   function Create (For_Target : Landin.Targets.Target_Facts)
     return Compilation
   is
   begin
      return Result : Compilation do
         Result.Facts := For_Target;
         Landin.Modules.Initialize (Result.Grouped);
      end return;
   end Create;

   function Target (Context : Compilation) return Landin.Targets.Target_Facts
     is (Context.Facts);

   function Add_Source
     (Context : in out Compilation; Name : String; Text : String)
     return Landin.Source.Source_Id
   is
   begin
      return Add_Source
        (Context, Landin.Modules.Entry_Module, Name, Text);
   end Add_Source;

   function Add_Source
     (Context : in out Compilation;
      Module  : Landin.Modules.Module_Id;
      Name    : String;
      Text    : String) return Landin.Source.Source_Id
   is
      Added : constant Landin.Source.Source_Id :=
        Context.Held.Add (Name, Text);
   begin
      Landin.Modules.Attach_Source (Context.Grouped, Added, Module);
      return Added;
   end Add_Source;

   function Source_Count (Context : Compilation) return Natural
     is (Context.Held.Count);

   function Source
     (Context : aliased Compilation; Id : Landin.Source.Source_Id)
      return Landin.Source.Snapshot_Reference
     is (Context.Held.Get (Id));

   function Sources (Context : aliased Compilation)
     return not null access constant Landin.Source.Sets.Source_Set
     is (Context.Held'Access);

   function Nth_Source (Context : Compilation; Index : Positive)
     return Landin.Source.Source_Id
     is (Context.Held.Nth (Index));

   function Identities (Context : aliased in out Compilation)
     return not null access Landin.Source.Names.Table
     is (Context.Named'Access);

   function Modules (Context : aliased in out Compilation)
     return not null access Landin.Modules.Table
     is (Context.Grouped'Access);

   function Sites (Context : aliased in out Compilation)
     return not null access Landin.Provenance.Table
     is (Context.Written'Access);

   function Trees (Context : aliased in out Compilation)
     return not null access Landin.Syntax.Forest.Table
     is (Context.Parsed'Access);

   function Spacing (Context : aliased in out Compilation)
     return not null access Landin.Tokens.Spacing.Table
     is (Context.Spaced'Access);

   function Meanings (Context : aliased in out Compilation)
     return not null access Landin.Resolution.Table
     is (Context.Meant'Access);

   function Configurations (Context : aliased in out Compilation)
     return not null access Landin.Configuration.Table
     is (Context.Active'Access);

   function Types (Context : aliased in out Compilation)
     return not null access Landin.Checking.Table
     is (Context.Typed'Access);

   function Code (Context : aliased in out Compilation)
     return not null access Landin.IR.Unit
     is (Context.Lowered'Access);

   procedure Report
     (Context : in out Compilation; Item : Landin.Diagnostics.Diagnostic)
   is
   begin
      Context.Reports.Append (Item);
   end Report;

   function Report (Context : Compilation)
     return Landin.Diagnostics.Diagnostic_List
     is (Context.Reports);

   function Failed (Context : Compilation) return Boolean
     is (Context.Reports.Has_Errors);

   function Rendered_Report (Context : Compilation) return String
     is (Landin.Diagnostics.Text.Render (Context.Reports, Context.Held));

   procedure Append
     (Into : in out Pipeline; Item : not null Stage_Reference) is
   begin
      Into.Items.Append (Item);
   end Append;

   function Length (Of_Pipeline : Pipeline) return Natural
     is (Natural (Of_Pipeline.Items.Length));

   function Run
     (Of_Pipeline : Pipeline; Context : in out Compilation) return Natural
   is
      Ran     : Natural := 0;
      Outcome : Stage_Outcome;
   begin
      for Item of Of_Pipeline.Items loop
         Item.all.Run (Context, Outcome);
         Ran := Ran + 1;
         exit when Outcome = Stop;
      end loop;
      return Ran;
   end Run;

   function Run
     (Of_Pipeline : Pipeline;
      Context     : in out Compilation;
      Watch       : not null access procedure
        (Name : String; Finished : Boolean)) return Natural
   is
      Ran     : Natural := 0;
      Outcome : Stage_Outcome;
   begin
      for Item of Of_Pipeline.Items loop
         Watch (Item.all.Name, Finished => False);
         Item.all.Run (Context, Outcome);
         Watch (Item.all.Name, Finished => True);
         Ran := Ran + 1;
         exit when Outcome = Stop;
      end loop;
      return Ran;
   end Run;

end Landin.Stages;
