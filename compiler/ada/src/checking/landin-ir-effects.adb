package body Landin.IR.Effects is
   function Of_Code (Op : Opcode) return Effect_Set is
   begin
      case Op is
         when Number | Truth | Atom | Empty_Slice_Base | Measure_Size
            | Measure_Align | Complement | Logical_Not | Wrapping_Multiply
            | Wrapping_Add | Wrapping_Subtract | Bitwise_And | Bitwise_Xor
            | Bitwise_Or | Equal_To | Not_Equal_To | Less_Than | Less_Or_Equal
            | Greater_Than | Greater_Or_Equal | Failure_Test
            | Function_Address | Evidence_Address =>
            return (others => False);
         when Load =>
            return (Reads => True, others => False);
         when Store =>
            return (Writes => True, others => False);
         when Storage_Address | Place_Address | Slice_Address | Conversion
            | Range_Check | Pointer_Address | Negation | Multiply | Divide
            | Remainder | Add | Subtract | Shift_Left | Shift_Right =>
            return (Traps => True, others => False);
         when Load_Indirect | Load_Datum | Load_Field | Load_Element
            | Load_Variant_Tag | Load_Variant_Field | Evidence_Function =>
            return (Reads => True, Traps => True, others => False);
         when Store_Indirect | Store_Datum | Store_Field | Store_Element
            | Clear_Array | Fill_Array | Select_Variant
            | Store_Variant_Field =>
            return (Writes => True, Traps => True, others => False);
         when Copy_Array | Copy_Variant =>
            return (Reads => True, Writes => True, Traps => True,
                    others => False);
         when Evidence_Self =>
            return (Reads => True, Traps => True, Adjacency => True,
                    others => False);
         when Call | Indirect_Call =>
            return (Reads => True, Writes => True, Calls => True,
                    Traps => True, others => False);
         when Jump | Branch | Leave | Fail =>
            return (Control => True, others => False);
      end case;
   end Of_Code;

   function Weight (Op : Opcode) return Positive is
      Effect : constant Effect_Set := Of_Code (Op);
   begin
      if Effect.Calls then
         return 6;
      elsif Effect.Reads or else Effect.Writes or else Effect.Control then
         return 2;
      else
         return 1;
      end if;
   end Weight;
end Landin.IR.Effects;
