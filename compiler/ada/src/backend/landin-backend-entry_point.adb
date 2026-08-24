with Landin.Types;

package body Landin.Backend.Entry_Point is

   use type Landin.IR.Item_Kind;
   use type Landin.IR.Slot_Id;
   use type Landin.Types.Type_Kind;

   function Hosted_Main
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
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
              and then Landin.Resolution.Is_Public (Meanings, Declared)
              and then Spelling_Of (Declared) = "main"
              and then Landin.IR.Parameter_Count (Of_Unit, Item) = 0
              and then Landin.IR.Result_Of (Of_Unit, Item) = Landin.Types.I32
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

end Landin.Backend.Entry_Point;
