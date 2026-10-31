with Ada.Strings.Fixed;
with Landin.Targets.Capabilities;
with Landin.Types;

package body Landin.Backend.Images is

   use type Landin.IR.Item_Id;
   use type Landin.IR.Item_Kind;
   use type Landin.IR.Signature_Id;
   use type Landin.Targets.Byte_Count;
   use type Landin.Types.Type_Kind;

   function Plus
     (Left : Count; Right : Landin.Targets.Byte_Count) return Count
     is (if Left.Past
           or else Left.Bytes > Landin.Targets.Byte_Count'Last - Right
         then (Bytes => Landin.Targets.Byte_Count'Last, Past => True)
         else (Bytes => Left.Bytes + Right, Past => False));

   function Over
     (Used : Count; Limit : Landin.Targets.Byte_Count) return Boolean
     is (Used.Past or else Used.Bytes > Limit);

   function Measure
     (Of_Unit : Landin.IR.Unit;
      Facts   : Landin.Targets.Target_Facts) return Usage
   is
      Result : Usage;
      Zero_Constants_Written : constant Boolean :=
        Landin.Targets.Capabilities.Writes_Zero_Constants (Facts);
   begin
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            Bytes : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
            Written : Boolean;
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum then
               case Landin.IR.Result_Of (Of_Unit, Item) is
                  when Landin.Types.Aggregate =>
                     Bytes := Datum_Layout (Of_Unit, Item, Facts).Size;
                  when Landin.Types.Fixed_Array =>
                     Field_Extent
                       (Of_Unit, Landin.IR.Whole_Array_Shape (Of_Unit, Item),
                        Facts, Bytes, Alignment);
                  when others =>
                     Bytes := Landin.Targets.Byte_Count
                       (Landin.Targets.Bytes (Landin.Types.Storage_Size
                         (Landin.IR.Result_Of (Of_Unit, Item), Facts)));
               end case;
               --  As every backend decides between a written and a reserved
               --  image; a scalar, at most sixteen bytes, counts as written
               --  whatever it folds to.
               Written := Landin.IR.Is_Read_Only (Of_Unit, Item)
                 or else Landin.IR.Signature_Of (Of_Unit, Item)
                   /= Landin.IR.No_Signature
                 or else Landin.IR.Address_Target (Of_Unit, Item)
                   /= Landin.IR.No_Item
                 or else Landin.IR.Result_Of (Of_Unit, Item)
                   not in Landin.Types.Aggregate | Landin.Types.Fixed_Array
                 or else Landin.IR.Has_Image (Of_Unit, Item)
                 or else (Zero_Constants_Written
                   and then Landin.IR.Is_Immutable (Of_Unit, Item));
               if not Written then
                  Result.Reserved := Plus (Result.Reserved, Bytes);
               else
                  Result.Initialized := Plus (Result.Initialized, Bytes);
                  if not Landin.IR.Is_Read_Only (Of_Unit, Item)
                    and then not Landin.IR.Is_Immutable (Of_Unit, Item)
                  then
                     Result.Writable := Plus (Result.Writable, Bytes);
                  end if;
               end if;
            end if;
         end;
      end loop;
      return Result;
   end Measure;

   function Exceeded
     (Used : Usage; Budget : Landin.Targets.Image_Budget) return Excess is
   begin
      if Over (Used.Initialized, Budget.Initialized) then
         return Initialized;
      elsif Over (Used.Writable, Budget.Writable) then
         return Writable;
      elsif Over (Used.Reserved, Budget.Reserved) then
         return Reserved;
      else
         return Within;
      end if;
   end Exceeded;

   function Refusal
     (Used   : Usage;
      Budget : Landin.Targets.Image_Budget;
      Over   : Excess;
      Holder : String) return String
   is
      function Number (Value : Landin.Targets.Byte_Count) return String is
        (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));
      function Number (Value : Count) return String is
        ((if Value.Past then "more than " else "") & Number (Value.Bytes));
   begin
      case Over is
         when Initialized =>
            return "static images write " & Number (Used.Initialized)
              & " bytes before section GC, past the "
              & Number (Budget.Initialized) & " bytes that " & Holder;
         when Writable =>
            return "mutable static images write " & Number (Used.Writable)
              & " bytes before section GC, past the "
              & Number (Budget.Writable) & " bytes that " & Holder;
         when Reserved =>
            return "zero static images reserve " & Number (Used.Reserved)
              & " bytes before section GC, past the "
              & Number (Budget.Reserved) & " bytes that " & Holder;
         when Within =>
            raise Compiler_Defect with "a usage within its budget is refused";
      end case;
   end Refusal;

end Landin.Backend.Images;
