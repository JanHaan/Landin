with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Landin.Platform.Publication is
   procedure Protect
     (Group : in out Transaction; Path : String; Identity : File_Identity) is
   begin
      if Path /= "" and then not Group.Protected_Paths.Contains (Path) then
         Group.Protected_Paths.Append (Path);
      end if;
      if Identity.Valid then
         Group.Protected_Identities.Append (Identity);
      end if;
   end Protect;

   procedure Protect
     (Group : in out Transaction; Files : Filesystem'Class; Path : String) is
      Content : Unbounded_String;
      Identity : File_Identity;
      Status : Read_Status;
   begin
      Read_Snapshot (Files, Path, Content, Identity, Status);
      Protect (Group, Path, Identity);
   end Protect;

   procedure Prepare
     (Group : in out Transaction; Files : Filesystem'Class; Path : String;
      Status : out Write_Status; Reason : out Unbounded_String;
      Delete_Only : Boolean := False; Root : String := "";
      Require_Absent : Boolean := False)
   is
      Item : Publication_Entry;
   begin
      Status := Not_Writable;
      Reason := Null_Unbounded_String;
      if Group.Committed then
         Reason := To_Unbounded_String ("publication already committed");
         return;
      end if;
      for Previous of Group.Entries loop
         if To_String (Previous.Path) = Path then
            if Require_Absent and then not Previous.Requires_Absence then
               Reason := To_Unbounded_String
                 ("output already prepared without an absence constraint;"
                  & " abort and prepare a new transaction");
               return;
            end if;
            Status := Write_Ok;
            return;
         end if;
      end loop;
      Item.Path := To_Unbounded_String (Path);
      Item.Requires_Absence := Require_Absent;
      Open_Publication
        (Files, Path, Delete_Only, Root, Item.Handle, Item.Stage, Status,
         Reason, Require_Absent);
      if Status = Write_Ok then
         Group.Entries.Append (Item);
         if Paths_Overlap_Any (Files, Path, Group.Protected_Paths) then
            declare
               Cleanup_Status : Write_Status;
               Cleanup_Reason : Unbounded_String;
            begin
               Discard (Group, Files, Path, Cleanup_Status, Cleanup_Reason);
               Status := Not_Writable;
               Reason := To_Unbounded_String
                 ("output " & Path
                  & " aliases or cannot be proved separate from a protected"
                  & " input; check input/output paths and access before"
                  & " retrying");
               if Cleanup_Status /= Write_Ok then
                  Append (Reason, "; " & To_String (Cleanup_Reason));
               end if;
            end;
         end if;
      end if;
   end Prepare;

   function Stage_Path (Group : Transaction; Path : String) return String is
   begin
      for Item of Group.Entries loop
         if To_String (Item.Path) = Path then
            return To_String (Item.Stage);
         end if;
      end loop;
      return "";
   end Stage_Path;

   function State (Group : Transaction) return Cleanup_State is
     (Group.Ended);

   function Cleanup_Reason (Group : Transaction) return String is
     (To_String (Group.Ended_Reason));

   procedure Reach
     (Group : in out Transaction; Ended : Cleanup_State;
      Reason : Unbounded_String);
   procedure Reach
     (Group : in out Transaction; Ended : Cleanup_State;
      Reason : Unbounded_String) is
   begin
      if Group.Entries.Is_Empty then
         return;
      elsif Ended = Clean then
         Group.Ended_Reason := Null_Unbounded_String;
      elsif Ended /= Group.Ended then
         Group.Ended_Reason := Reason;
      end if;
      Group.Ended := Ended;
   end Reach;

   --  Each call reconsiders every entry it still holds, so a retried step
   --  that now succeeds no longer counts against the group; a group with
   --  no entries left keeps the state its last cleanup reached.
   procedure Abort_Transaction
     (Group : in out Transaction; Files : Filesystem'Class;
      Status : out Write_Status; Reason : out Unbounded_String)
   is
      Part_Status : Write_Status;
      Part_Reason : Unbounded_String;
      Ended : Cleanup_State := Clean;
   begin
      Status := Write_Ok;
      Reason := Null_Unbounded_String;
      for Item of reverse Group.Entries loop
         Part_Status := Write_Ok;
         --  A rollback that succeeded is never repeated: the entry now
         --  holds what it held before, and a second restore could only
         --  misreport retained staging as an incomplete rollback.
         if not Item.Restored then
            Advance_Publication
              (Files, Item.Handle, Restore_Previous, Group.Protected_Paths,
               Group.Protected_Identities, Part_Status, Part_Reason);
            Item.Restored := Part_Status = Write_Ok;
            if not Item.Restored then
               Ended := Rollback_Incomplete;
            end if;
         end if;
         if Item.Restored then
            Advance_Publication
              (Files, Item.Handle, Finish_Publication, Group.Protected_Paths,
               Group.Protected_Identities, Part_Status, Part_Reason);
            if Part_Status /= Write_Ok and then Ended = Clean then
               Ended := Restored_Stage_Retained;
            end if;
         end if;
         if Part_Status /= Write_Ok then
            Status := Not_Writable;
            Append (Reason, (if Length (Reason) = 0 then "" else "; ")
                    & To_String (Part_Reason));
         end if;
      end loop;
      Reach (Group, Ended, Reason);
      Group.Committed := False;
      if Status = Write_Ok then
         Group.Entries.Clear;
      end if;
   end Abort_Transaction;

   procedure Discard
     (Group : in out Transaction; Files : Filesystem'Class; Path : String;
      Status : out Write_Status; Reason : out Unbounded_String) is
   begin
      Status := Write_Ok;
      Reason := Null_Unbounded_String;
      for Index in 1 .. Natural (Group.Entries.Length) loop
         if To_String (Group.Entries (Index).Path) = Path then
            Advance_Publication
              (Files, Group.Entries (Index).Handle, Restore_Previous,
               Group.Protected_Paths, Group.Protected_Identities,
               Status, Reason);
            if Status = Write_Ok then
               Advance_Publication
                 (Files, Group.Entries (Index).Handle, Finish_Publication,
                  Group.Protected_Paths, Group.Protected_Identities,
                  Status, Reason);
            end if;
            if Status = Write_Ok then
               Group.Entries.Delete (Index);
            end if;
            return;
         end if;
      end loop;
   end Discard;

   procedure Commit
     (Group : in out Transaction; Files : Filesystem'Class;
      Status : out Write_Status; Reason : out Unbounded_String)
   is
      Rollback_Status : Write_Status;
      Rollback_Reason : Unbounded_String;
   begin
      Status := Write_Ok;
      Reason := Null_Unbounded_String;
      if Group.Committed then
         return;
      end if;
      for Action in Validate_Stage .. Install_Stage loop
         for Index in 1 .. Natural (Group.Entries.Length) loop
            declare
               Handle : constant Publication_Handle :=
                 Group.Entries (Index).Handle;
            begin
               Advance_Publication
                 (Files, Handle, Action, Group.Protected_Paths,
                  Group.Protected_Identities, Status, Reason);
               if Status /= Write_Ok then
                  Abort_Transaction
                    (Group, Files, Rollback_Status, Rollback_Reason);
                  if Rollback_Status /= Write_Ok then
                     Append (Reason, "; " & To_String (Rollback_Reason));
                  end if;
                  return;
               end if;
            end;
         end loop;
      end loop;
      Group.Committed := True;
   end Commit;

   procedure Finish
     (Group : in out Transaction; Files : Filesystem'Class;
      Status : out Write_Status; Reason : out Unbounded_String)
   is
      Part_Status : Write_Status;
      Part_Reason : Unbounded_String;
   begin
      if not Group.Committed then
         Abort_Transaction (Group, Files, Status, Reason);
         return;
      end if;
      Status := Write_Ok;
      Reason := Null_Unbounded_String;
      for Item of Group.Entries loop
         Advance_Publication
           (Files, Item.Handle, Finish_Publication, Group.Protected_Paths,
            Group.Protected_Identities, Part_Status, Part_Reason);
         if Part_Status /= Write_Ok then
            Status := Not_Writable;
            Append (Reason, (if Length (Reason) = 0 then "" else "; ")
                    & To_String (Part_Reason));
         end if;
      end loop;
      Reach
        (Group,
         (if Status = Write_Ok then Clean else Published_Prior_Retained),
         Reason);
      Group.Entries.Clear;
   end Finish;
end Landin.Platform.Publication;
