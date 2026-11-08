--  Grouped, recoverable publication. Prepare before generating any artifact;
--  retain the group through validation, then Finish to discard prior versions.
private with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Landin.Platform.Publication is
   type Transaction is limited private;

   --  Require_Absent constrains the host's actual initial snapshot. A later
   --  arrival remains a conflict; an existing unconstrained reservation cannot
   --  be upgraded by repeating Prepare with this flag.
   --  With Root empty, an absence-constrained output pins existing parent
   --  components without following user links or creating public directories.
   procedure Prepare
     (Group : in out Transaction; Files : Filesystem'Class; Path : String;
      Status : out Write_Status;
      Reason : out Ada.Strings.Unbounded.Unbounded_String;
      Delete_Only : Boolean := False; Root : String := "";
      Require_Absent : Boolean := False);
   function Stage_Path (Group : Transaction; Path : String) return String;
   procedure Protect
     (Group : in out Transaction; Files : Filesystem'Class; Path : String);
   procedure Protect
     (Group : in out Transaction; Path : String; Identity : File_Identity);
   procedure Discard
     (Group : in out Transaction; Files : Filesystem'Class; Path : String;
      Status : out Write_Status;
      Reason : out Ada.Strings.Unbounded.Unbounded_String);
   procedure Commit
     (Group : in out Transaction; Files : Filesystem'Class;
      Status : out Write_Status;
      Reason : out Ada.Strings.Unbounded.Unbounded_String);
   procedure Abort_Transaction
     (Group : in out Transaction; Files : Filesystem'Class;
      Status : out Write_Status;
      Reason : out Ada.Strings.Unbounded.Unbounded_String);
   procedure Finish
     (Group : in out Transaction; Files : Filesystem'Class;
      Status : out Write_Status;
      Reason : out Ada.Strings.Unbounded.Unbounded_String);

   --  Where a group's cleanup left it, so a refusal can say what was
   --  published and what was put back. Clean: nothing is retained.
   --  Published_Prior_Retained: the group was committed and its new
   --  outputs are installed; a replaced copy or private file of it
   --  remains. Restored_Stage_Retained: the group was not committed and
   --  every prepared output was put back as it was; private staging
   --  remains. Rollback_Incomplete: an output's rollback failed, so that
   --  output may hold the new or the previous version. The state only
   --  grows more severe over a group's life; Abort_Transaction never
   --  repeats a rollback that already succeeded.
   type Cleanup_State is
     (Clean, Published_Prior_Retained, Restored_Stage_Retained,
      Rollback_Incomplete);
   function State (Group : Transaction) return Cleanup_State;
   --  The host's reason from the cleanup that first reached State, kept
   --  when a later retry fails the same way: the first failure names the
   --  cause, and a retry only reports that it is still there.
   function Cleanup_Reason (Group : Transaction) return String;
private
   type Publication_Entry is record
      Path, Stage : Ada.Strings.Unbounded.Unbounded_String;
      Handle : Publication_Handle := No_Publication;
      Requires_Absence : Boolean := False;
      Restored : Boolean := False;
   end record;
   package Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Publication_Entry);
   type Transaction is limited record
      Entries : Entry_Vectors.Vector;
      Protected_Paths : Path_List;
      Protected_Identities : Identity_List;
      Committed : Boolean := False;
      Ended : Cleanup_State := Clean;
      Ended_Reason : Ada.Strings.Unbounded.Unbounded_String;
   end record;
end Landin.Platform.Publication;
