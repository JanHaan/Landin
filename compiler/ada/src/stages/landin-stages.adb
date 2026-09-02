with Landin.Diagnostics.Text;

package body Landin.Stages is

   function Create (For_Target : Landin.Targets.Target_Facts)
     return Compilation
   is
   begin
      return Result : Compilation do
         Result.Facts   := For_Target;
         Result.Named   := new Landin.Source.Names.Table;
         Result.Grouped := new Landin.Modules.Table;
         Landin.Modules.Initialize (Result.Grouped.all);
         Result.Written := new Landin.Provenance.Table;
         Result.Parsed  := new Landin.Syntax.Forest.Table;
         Result.Meant   := new Landin.Resolution.Table;
         Result.Active  := new Landin.Configuration.Table;
         Result.Typed   := new Landin.Checking.Table;
         Result.Lowered := new Landin.IR.Unit;
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
        Context.Sources.Add (Name, Text);
   begin
      Landin.Modules.Attach_Source (Context.Grouped.all, Added, Module);
      return Added;
   end Add_Source;

   function Source_Count (Context : Compilation) return Natural
     is (Context.Sources.Count);

   function Source (Context : Compilation; Id : Landin.Source.Source_Id)
     return Landin.Source.Snapshot
     is (Context.Sources.Get (Id));

   function Nth_Source (Context : Compilation; Index : Positive)
     return Landin.Source.Source_Id
     is (Context.Sources.Nth (Index));

   function Identities (Context : in out Compilation)
     return not null access Landin.Source.Names.Table
     is (Context.Named);

   function Modules (Context : in out Compilation)
     return not null access Landin.Modules.Table
     is (Context.Grouped);

   function Sites (Context : in out Compilation)
     return not null access Landin.Provenance.Table
     is (Context.Written);

   function Trees (Context : in out Compilation)
     return not null access Landin.Syntax.Forest.Table
     is (Context.Parsed);

   function Meanings (Context : in out Compilation)
     return not null access Landin.Resolution.Table
     is (Context.Meant);

   function Configurations (Context : in out Compilation)
     return not null access Landin.Configuration.Table
     is (Context.Active);

   function Types (Context : in out Compilation)
     return not null access Landin.Checking.Table
     is (Context.Typed);

   function Code (Context : in out Compilation)
     return not null access Landin.IR.Unit
     is (Context.Lowered);

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
     is (Landin.Diagnostics.Text.Render (Context.Reports, Context.Sources));

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

end Landin.Stages;
