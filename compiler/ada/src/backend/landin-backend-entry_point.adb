with Landin.Hosted;
with Landin.Machine;
with Landin.Types;

package body Landin.Backend.Entry_Point is

   use type Landin.Machine.Convention;

   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Atom_Set_Id;
   use type Landin.IR.Item_Id;
   use type Landin.IR.Item_Kind;
   use type Landin.IR.Signature_Id;
   use type Landin.IR.Slot_Id;
   use type Landin.Modules.Module_Id;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Types.Type_Kind;

   function Hosted_Main
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Modules  : Landin.Modules.Table;
      Names    : Landin.Source.Names.Table) return Landin.IR.Item_Id
   is
      function Spelling_Of
        (Declared : Landin.Resolution.Declaration_Id) return String
        is (Landin.Source.Names.Spelling
              (Names, Landin.Resolution.Name_Of (Meanings, Declared)));
   begin
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id :=
              Landin.IR.Item_Id (Index);
            Declared : constant Landin.Resolution.Declaration_Id :=
              Landin.IR.Declares (Of_Unit, Item);
            Result : constant Landin.IR.Slot_Id :=
              (if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
               then Landin.IR.Result_Slot (Of_Unit, Item)
               else Landin.IR.No_Slot);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then Declared /= Landin.IR.No_Declaration
              and then Landin.Modules.Module_Of
                (Modules, Landin.Resolution.Source_Of (Meanings, Declared))
                  = Landin.Modules.Entry_Module
              and then Landin.Resolution.Is_Public (Meanings, Declared)
              and then Spelling_Of (Declared) = "main"
              and then Landin.IR.Parameter_Count (Of_Unit, Item) = 0
              and then Landin.IR.Result_Of (Of_Unit, Item) = Landin.Types.I32
              and then Landin.IR.Signature_Of (Of_Unit, Item)
                         /= Landin.IR.No_Signature
              and then not Landin.IR.Signature_Uses_C_ABI
                (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
              and then
                (Landin.IR.Link_Symbol (Of_Unit, Item)
                   = Landin.Source.Names.No_Name
                 or else Landin.Source.Names.Spelling
                   (Names, Landin.IR.Link_Symbol (Of_Unit, Item)) = "main")
              and then Landin.IR.Signature_Errors
                (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
                  = Landin.IR.No_Atom_Set
              and then Result /= Landin.IR.No_Slot
              and then Spelling_Of
                         (Landin.IR.Declares (Of_Unit, Item, Result))
                       = "code"
            then
               return Item;
            end if;
         end;
      end loop;

      return Landin.IR.No_Item;
   end Hosted_Main;

   function Argument_Initializer
     (Of_Unit : Landin.IR.Unit;
      Names   : Landin.Source.Names.Table) return Landin.IR.Item_Id
   is
   begin
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            Link : constant Landin.Source.Names.Name_Id :=
              Landin.IR.Link_Symbol (Of_Unit, Item);
            Signature : constant Landin.IR.Signature_Id :=
              Landin.IR.Signature_Of (Of_Unit, Item);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Landin.IR.Is_External (Of_Unit, Item)
              and then Link /= Landin.Source.Names.No_Name
              and then Landin.Source.Names.Spelling (Names, Link)
                = Landin.Hosted.Argument_Initializer
            then
               if Signature = Landin.IR.No_Signature
                 or else not Landin.IR.Signature_Uses_C_ABI
                   (Of_Unit, Signature)
                 or else Landin.IR.Signature_Parameter_Count
                   (Of_Unit, Signature) /= 3
                 or else Landin.IR.Signature_Result_Count
                   (Of_Unit, Signature) /= 0
               then
                  raise Compiler_Defect with
                    "an unchecked hosted argument initializer reached the"
                    & " backend";
               end if;
               return Item;
            end if;
         end;
      end loop;
      return Landin.IR.No_Item;
   end Argument_Initializer;

   procedure Unsatisfied_Imports
     (Of_Unit   : Landin.IR.Unit;
      Meanings  : Landin.Resolution.Table;
      Modules   : Landin.Modules.Table;
      Names     : Landin.Source.Names.Table;
      Imports   : out Landin.Platform.Path_List;
      Referrers : out Landin.Platform.Path_List)
   is
      --  The item whose references are being followed, or No_Item for a
      --  root.
      Referring : Landin.IR.Item_Id := Landin.IR.No_Item;

      --  How a refusal names the item that refers to an import.
      function Referrer_Name (Item : Landin.IR.Item_Id) return String;

      function Referrer_Name (Item : Landin.IR.Item_Id) return String is
         Declared : Landin.IR.Declaration_Id;
         Module : Landin.Modules.Module_Id;
      begin
         if Item = Landin.IR.No_Item then
            return "";
         end if;
         Declared := Landin.IR.Declares (Of_Unit, Item);
         if Declared = Landin.IR.No_Declaration then
            return "";
         end if;
         Module := Landin.Modules.Module_Of
           (Modules, Landin.Resolution.Source_Of (Meanings, Declared));
         return
           (if Module = Landin.Modules.Entry_Module
              or else Module = Landin.Modules.No_Module
            then ""
            else Landin.Modules.Logical_Path (Modules, Module) & "'s ")
           & "`" & Landin.Source.Names.Spelling
               (Names, Landin.Resolution.Name_Of (Meanings, Declared))
           & "`";
      end Referrer_Name;

      --  The name the linker sees, before any platform prefix.
      function Link_Name (Item : Landin.IR.Item_Id) return String;

      function Link_Name (Item : Landin.IR.Item_Id) return String is
         Link : constant Landin.Source.Names.Name_Id :=
           Landin.IR.Link_Symbol (Of_Unit, Item);
         Declared : constant Landin.IR.Declaration_Id :=
           Landin.IR.Declares (Of_Unit, Item);
      begin
         if Link /= Landin.Source.Names.No_Name then
            return Landin.Source.Names.Spelling (Names, Link);
         elsif Declared = Landin.IR.No_Declaration then
            return "";
         end if;
         return Landin.Source.Names.Spelling
           (Names, Landin.Resolution.Name_Of (Meanings, Declared));
      end Link_Name;

      function Defined (Name : String) return Boolean;

      function Defined (Name : String) return Boolean is
      begin
         for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            begin
               if not Landin.IR.Is_External (Of_Unit, Item)
                 and then Link_Name (Item) = Name
               then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Defined;

      Count : constant Natural := Landin.IR.Item_Count (Of_Unit);
      Reached : array (1 .. Natural'Max (1, Count)) of Boolean :=
        [others => False];
      Pending : array (1 .. Natural'Max (1, Count)) of Landin.IR.Item_Id :=
        [others => Landin.IR.No_Item];
      Waiting : Natural := 0;

      procedure Reach (Target : Landin.IR.Item_Id);
      procedure Reach_Name (Name : String);
      procedure Reach_Evidence (Id : Landin.IR.Evidence_Id);

      --  An external item is an unsatisfied import unless a program item
      --  defines its name, in which case that item is what it reaches.
      procedure Reach (Target : Landin.IR.Item_Id) is
      begin
         if Target = Landin.IR.No_Item
           or else Reached (Positive (Target))
         then
            return;
         end if;
         Reached (Positive (Target)) := True;
         if Landin.IR.Is_External (Of_Unit, Target) then
            declare
               Name : constant String := Link_Name (Target);
            begin
               if Name = "" then
                  null;
               elsif Defined (Name) then
                  Reach_Name (Name);
               elsif not Imports.Contains (Name) then
                  Imports.Append (Name);
                  Referrers.Append (Referrer_Name (Referring));
               end if;
            end;
         else
            Waiting := Waiting + 1;
            Pending (Waiting) := Target;
         end if;
      end Reach;

      procedure Reach_Name (Name : String) is
      begin
         for Index in 1 .. Count loop
            declare
               Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            begin
               if not Landin.IR.Is_External (Of_Unit, Item)
                 and then Link_Name (Item) = Name
               then
                  Reach (Item);
               end if;
            end;
         end loop;
      end Reach_Name;

      --  The panic handler the backend calls, which D374 counts as a root.
      function Handler return Landin.IR.Item_Id;

      function Handler return Landin.IR.Item_Id is
      begin
         for Index in 1 .. Count loop
            declare
               Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            begin
               if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
                 and then not Landin.IR.Is_External (Of_Unit, Item)
                 and then Link_Name (Item) = "panic_handler"
               then
                  return Item;
               end if;
            end;
         end loop;
         return Landin.IR.No_Item;
      end Handler;

      --  A table names only the entries D374 keeps; the rest are zero.
      Kept : constant Kept_Entries :=
        Kept_Evidence_Entries (Of_Unit, Handler, Meanings, Names);

      procedure Reach_Evidence (Id : Landin.IR.Evidence_Id) is
      begin
         for Position in 1 .. Landin.IR.Evidence_Entry_Count (Of_Unit, Id)
         loop
            if Is_Kept (Kept, Id, Position) then
               Reach
                 (Landin.IR.Evidence_Entry_Target (Of_Unit, Id, Position));
            end if;
         end loop;
      end Reach_Evidence;
   begin
      --  The roots: the entry, what the entry and the backend call by name,
      --  every datum, and every evidence table.
      Imports.Clear;
      Referrers.Clear;
      Reach_Name ("_landin_start");
      Reach_Name ("main");
      Reach_Name ("_landin_host_initialize_arguments");
      Reach_Name ("panic_handler");
      for Index in 1 .. Count loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum
              or else Landin.IR.Placement_Of (Of_Unit, Item).Keep
            then
               Reach (Item);
            end if;
         end;
      end loop;
      for Id in 1 .. Landin.IR.Evidence_Count (Of_Unit) loop
         Reach_Evidence (Landin.IR.Evidence_Id (Id));
      end loop;

      while Waiting > 0 loop
         declare
            Item : constant Landin.IR.Item_Id := Pending (Waiting);
         begin
            Waiting := Waiting - 1;
            Referring := Item;
            Reach (Landin.IR.Function_Target (Of_Unit, Item));
            Reach (Landin.IR.Address_Target (Of_Unit, Item));
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum then
               if Landin.IR.Result_Of (Of_Unit, Item)
                    in Landin.Types.Aggregate | Landin.Types.Fixed_Array
                 and then Landin.IR.Has_Image (Of_Unit, Item)
               then
                  for Position in 1 .. Landin.IR.Aggregate_Field_Image_Count
                    (Of_Unit, Item)
                  loop
                     Reach (Landin.IR.Nth_Image_Descriptor
                       (Of_Unit, Item, Position).Target);
                  end loop;
               end if;
            else
               for Position in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
                  declare
                     Value : constant Landin.IR.Value_Id :=
                       Landin.IR.Value_Id (Position);
                  begin
                     case Landin.IR.Op_Of (Of_Unit, Item, Value) is
                        when Landin.IR.Function_Address | Landin.IR.Call =>
                           Reach (Landin.IR.Callee_Of (Of_Unit, Item, Value));
                        when Landin.IR.Evidence_Address
                           | Landin.IR.Evidence_Function =>
                           Reach_Evidence
                             (Landin.IR.Evidence_Of (Of_Unit, Item, Value));
                        when others =>
                           null;
                     end case;
                  end;
               end loop;
            end if;
         end;
      end loop;
   end Unsatisfied_Imports;

   function Firmware_Start
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Modules  : Landin.Modules.Table;
      Names    : Landin.Source.Names.Table;
      Selected : String) return Landin.IR.Item_Id
   is
   begin
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            Declared : constant Landin.IR.Declaration_Id :=
              Landin.IR.Declares (Of_Unit, Item);
            Signature : constant Landin.IR.Signature_Id :=
              Landin.IR.Signature_Of (Of_Unit, Item);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Landin.IR.Is_External (Of_Unit, Item)
              and then Landin.IR.Generic_Template_Of (Of_Unit, Item)
                = Landin.IR.No_Declaration
              and then Declared /= Landin.IR.No_Declaration
              and then Landin.Modules.Module_Of
                (Modules, Landin.Resolution.Source_Of (Meanings, Declared))
                  = Landin.Modules.Entry_Module
              and then Landin.Source.Names.Spelling
                (Names, Landin.Resolution.Name_Of (Meanings, Declared))
                  = Selected
              and then Signature /= Landin.IR.No_Signature
              and then Landin.IR.Signature_Machine (Of_Unit, Signature)
                in Landin.Machine.Ordinary | Landin.Machine.Naked_Routine
              and then not Landin.IR.Signature_Uses_C_ABI
                (Of_Unit, Signature)
              and then Landin.IR.Signature_Parameter_Count
                (Of_Unit, Signature) = 0
              and then Landin.IR.Signature_Result_Count
                (Of_Unit, Signature) = 0
              and then Landin.IR.Signature_Errors (Of_Unit, Signature)
                = Landin.IR.No_Atom_Set
            then
               return Item;
            end if;
         end;
      end loop;
      return Landin.IR.No_Item;
   end Firmware_Start;

end Landin.Backend.Entry_Point;
