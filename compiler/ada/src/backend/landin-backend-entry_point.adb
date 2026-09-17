with Landin.Machine;
with Landin.Types;

package body Landin.Backend.Entry_Point is

   use type Landin.Machine.Convention;

   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Atom_Set_Id;
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
