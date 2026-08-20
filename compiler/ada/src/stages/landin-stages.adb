with Landin.Diagnostics.Text;

package body Landin.Stages is

   function Create (For_Target : Landin.Targets.Target_Facts)
     return Compilation
   is
   begin
      return Result : Compilation do
         Result.Facts := For_Target;
      end return;
   end Create;

   function Target (Context : Compilation) return Landin.Targets.Target_Facts
     is (Context.Facts);

   function Add_Source
     (Context : in out Compilation; Name : String; Text : String)
     return Landin.Source.Source_Id
     is (Context.Sources.Add (Name, Text));

   function Source_Count (Context : Compilation) return Natural
     is (Context.Sources.Count);

   function Source (Context : Compilation; Id : Landin.Source.Source_Id)
     return Landin.Source.Snapshot
     is (Context.Sources.Get (Id));

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
