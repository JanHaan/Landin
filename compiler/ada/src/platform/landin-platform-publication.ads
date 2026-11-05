--  Grouped, recoverable publication. Prepare before generating any artifact;
--  retain the group through validation, then Finish to discard prior versions.
private with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Landin.Platform.Publication is
   type Transaction is limited private;

   procedure Prepare
     (Group : in out Transaction; Files : Filesystem'Class; Path : String;
      Status : out Write_Status;
      Reason : out Ada.Strings.Unbounded.Unbounded_String;
      Delete_Only : Boolean := False; Root : String := "");
   function Stage_Path (Group : Transaction; Path : String) return String;
   procedure Protect
     (Group : in out Transaction; Files : Filesystem'Class; Path : String);
   procedure Protect
     (Group : in out Transaction; Path : String; Identity : File_Identity);
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
private
   type Publication_Entry is record
      Path, Stage : Ada.Strings.Unbounded.Unbounded_String;
      Handle : Publication_Handle := No_Publication;
   end record;
   package Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Publication_Entry);
   type Transaction is limited record
      Entries : Entry_Vectors.Vector;
      Protected_Paths : Path_List;
      Protected_Identities : Identity_List;
      Committed : Boolean := False;
   end record;
end Landin.Platform.Publication;
