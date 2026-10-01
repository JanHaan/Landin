with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Text;

package body Landin.Stages is

   function Create (For_Target : Landin.Targets.Target_Facts)
     return Compilation
   is
   begin
      return Create
        (For_Target, Landin.Targets.Levels.Default_Level (For_Target));
   end Create;

   function Create
     (For_Target : Landin.Targets.Target_Facts;
      At_Level   : Landin.Targets.Levels.Feature_Level)
     return Compilation
   is
   begin
      if not Landin.Targets.Levels.Belongs_To (At_Level, For_Target) then
         raise Compiler_Defect with "a level of another target's family";
      end if;
      return Result : Compilation do
         Result.Facts := For_Target;
         Result.Assumed := At_Level;
         Landin.Modules.Initialize (Result.Grouped);
      end return;
   end Create;

   function Target (Context : Compilation) return Landin.Targets.Target_Facts
     is (Context.Facts);

   function Level
     (Context : Compilation) return Landin.Targets.Levels.Feature_Level
     is (Context.Assumed);

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

   --  A fix is checked where it joins the report and not where it is built,
   --  because only here are the sources it edits in hand: every edit must
   --  lie inside the snapshot the compilation read and begin and end
   --  between two characters, so an editor applying it can never split a
   --  UTF-8 sequence.  And the catalogue row says whether the code may carry
   --  one at all.
   procedure Report
     (Context : in out Compilation; Item : Landin.Diagnostics.Diagnostic)
   is
      package Rows renames Landin.Diagnostics.Catalogue;

      use type Landin.Source.Byte_Offset;
      use type Rows.Fix_Admission;

      Code : constant Landin.Diagnostics.Code_String :=
        Landin.Diagnostics.Code (Item);
      Admits : constant Rows.Fix_Admission :=
        (if Rows.Holds (Code) then Rows.Fixes (Rows.Named (Code))
         else Rows.May_Fix);
      Fixed  : constant Natural := Landin.Diagnostics.Fix_Count (Item);

      function Between_Characters
        (Snap : Landin.Source.Snapshot; Offset : Landin.Source.Byte_Offset)
         return Boolean;

      function Between_Characters
        (Snap : Landin.Source.Snapshot; Offset : Landin.Source.Byte_Offset)
         return Boolean
      is
      begin
         if Offset = Landin.Source.Length (Snap) then
            return True;
         end if;

         declare
            Byte : constant String :=
              Landin.Source.Slice (Snap, (Offset, Offset + 1));
         begin
            return Character'Pos (Byte (Byte'First)) not in 128 .. 191;
         end;
      end Between_Characters;
   begin
      if Admits = Rows.No_Fix and then Fixed > 0 then
         raise Compiler_Defect with Code & " may not carry a fix";
      elsif Admits = Rows.Must_Fix and then Fixed = 0 then
         raise Compiler_Defect with Code & " must carry a fix";
      end if;

      for Index in 1 .. Fixed loop
         declare
            One : constant Landin.Diagnostics.Fix :=
              Landin.Diagnostics.Nth_Fix (Item, Index);
         begin
            for Position in 1 .. Landin.Diagnostics.Edit_Count (One) loop
               declare
                  Change : constant Landin.Diagnostics.Edit :=
                    Landin.Diagnostics.Nth_Edit (One, Position);
                  Where : constant Landin.Source.Span :=
                    Landin.Diagnostics.Span_Of (Change);
               begin
                  if not Context.Held.Contains
                           (Landin.Diagnostics.Source_Of (Change))
                  then
                     raise Compiler_Defect
                       with Code & " edits a source this compilation"
                            & " does not hold";
                  end if;

                  declare
                     Snap : Landin.Source.Snapshot renames Context.Held.Get
                       (Landin.Diagnostics.Source_Of (Change)).Element.all;
                  begin
                     if not Landin.Source.Is_Valid (Snap, Where)
                       or else not Between_Characters (Snap, Where.First)
                       or else not Between_Characters (Snap, Where.Last)
                     then
                        raise Compiler_Defect
                          with Code & " edits bytes that are not whole"
                               & " characters of its source";
                     end if;
                  end;
               end;
            end loop;
         end;
      end loop;

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
