package body Landin.Stages.Folding is

   package Res renames Landin.Resolution;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;

   use type Landin.Targets.Bit_Width;
   use type Landin.Checking.Nominal_Type_Id;
   use type Res.Declaration_Sort;
   use type Res.Verdict;
   use type Syn.Node_Id;
   use type Syn.Node_Kind;
   use type Ty.Folded;
   use type Ty.Type_Kind;

   --  [0300]'s wrapping arithmetic, [0330]'s bit operators and [0320]'s
   --  shifts answer at the operand type's own width, as two's-complement
   --  patterns: `u8 = 255 +% 1` is 0 and every other size wraps the same
   --  way.  These helpers keep every answer inside the type's range.
   type Pattern is mod 2 ** 64;

   function Mask
     (V : Pattern; Bits : Landin.Targets.Bit_Width) return Pattern
     is (if Bits >= 64 then V
         else V and (2 ** Natural (Bits) - 1));

   function Is_Neg_Pattern
     (V : Pattern; Bits : Landin.Targets.Bit_Width) return Boolean
     is ((V and 2 ** (Natural (Bits) - 1)) /= 0);

   function To_Pattern
     (V : Ty.Folded; Bits : Landin.Targets.Bit_Width) return Pattern
     is (if V < 0
         then Mask (0 - Pattern (-V), Bits)
         else Mask (Pattern (V), Bits));

   function As_Number
     (V : Pattern; Bits : Landin.Targets.Bit_Width;
      Signed : Boolean) return Ty.Folded
     is (if Signed and then Is_Neg_Pattern (V, Bits)
         then -Ty.Folded (Mask (0 - V, Bits))
         else Ty.Folded (V));

   function Fold_Width
     (Kind : Ty.Scalar_Name) return Landin.Targets.Bit_Width
     is (if Kind in Ty.Integer_Name
         then Ty.Width (Ty.Integer_Name (Kind), Facts)
         else 8);

   function Is_Signed_Type (Kind : Ty.Scalar_Name) return Boolean
     is (Kind in Ty.Integer_Name
         and then Ty.Is_Signed (Ty.Integer_Name (Kind)));

   function Type_At
     (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
     is (Landin.Checking.Type_Of (Types.all, Of_Tree, Node));

   --  Ordinary arithmetic, guarded rather than caught: a sum too wide is
   --  entirely in the bytes being looked at.  A zero divisor declines
   --  rather than divides -- [1950] owns that refusal -- and is not an
   --  overflow.
   procedure Combine
     (Left, Right : Ty.Folded;
      Of_Kind     : Syn.Node_Kind;
      Answer      : out Ty.Folded;
      Fits        : out Boolean;
      Overflows   : out Boolean);

   procedure Combine
     (Left, Right : Ty.Folded;
      Of_Kind     : Syn.Node_Kind;
      Answer      : out Ty.Folded;
      Fits        : out Boolean;
      Overflows   : out Boolean) is
   begin
      Answer    := 0;
      Fits      := True;
      Overflows := False;

      case Of_Kind is
         when Syn.Add =>
            Fits := (if Right > 0
                     then Left <= Ty.Folded'Last - Right
                     else Left >= Ty.Folded'First - Right);
            Overflows := not Fits;
         when Syn.Subtract =>
            Fits := (if Right > 0
                     then Left >= Ty.Folded'First + Right
                     else Left <= Ty.Folded'Last + Right);
            Overflows := not Fits;
         when Syn.Multiply =>
            Fits := Left = 0
                    or else abs Right <= Ty.Folded'Last / abs Left;
            Overflows := not Fits;
         when Syn.Divide | Syn.Remainder =>
            Fits := Right /= 0;
         when others =>
            Fits := True;
      end case;

      if not Fits then
         return;
      end if;

      case Of_Kind is
         when Syn.Add      => Answer := Left + Right;
         when Syn.Subtract => Answer := Left - Right;
         when Syn.Multiply => Answer := Left * Right;
         when Syn.Divide   => Answer := Left / Right;
         when Syn.Remainder => Answer := Left rem Right;
         when others       => Fits := False;
      end case;
   end Combine;

   procedure Fold
     (Of_Tree    : Syn.Tree;
      Node       : Syn.Node_Id;
      Depth      : Natural;
      Value      : out Ty.Folded;
      Known      : out Boolean;
      Overflowed : out Boolean)
   is
      --  One operand, folded, with its overflow carried up: the answer
      --  cannot be produced without walking through the overflowing
      --  subtree, and the outermost caller is the one that speaks.
      procedure Operand
        (Item : Syn.Node_Id; Got : out Ty.Folded; Sure : out Boolean);

      procedure Operand
        (Item : Syn.Node_Id; Got : out Ty.Folded; Sure : out Boolean)
      is
         Blew : Boolean;
      begin
         Fold (Of_Tree, Item, Depth + 1, Got, Sure, Blew);
         if Blew then
            Overflowed := True;
            Sure := False;
         end if;
      end Operand;

      Held : constant Ty.Type_Kind :=
        (if Node = Syn.No_Node then Ty.Undecided else Type_At (Of_Tree, Node));
   begin
      Value      := 0;
      Known      := False;
      Overflowed := False;

      if Node = Syn.No_Node or else not Syn.Is_Sound (Of_Tree, Node) then
         return;
      end if;

      case Syn.Kind (Of_Tree, Node) is
         when Syn.Integer_Literal =>
            declare
               Snap : constant Landin.Source.Snapshot :=
                 Snapshot_Of (Syn.Source_Of (Of_Tree));
               Text : constant String :=
                 Landin.Source.Slice (Snap, Syn.Digit_Span (Of_Tree, Node));
               Magnitude : Ty.Magnitude;
               Overflow  : Boolean;
            begin
               Ty.Evaluate
                 (Text, Syn.Base (Of_Tree, Node), Magnitude, Overflow);
               if Overflow then
                  Overflowed := True;
               else
                  Value := Ty.Folded (Magnitude);
                  Known := True;
               end if;
            end;

         when Syn.Float_Literal =>
            if Held in Ty.Float_Name then
               declare
                  Snap : constant Landin.Source.Snapshot :=
                    Snapshot_Of (Syn.Source_Of (Of_Tree));
                  Text : constant String :=
                    Landin.Source.Slice (Snap, Syn.Anchor (Of_Tree, Node));
                  Bits     : Ty.Magnitude;
                  Overflow : Boolean;
               begin
                  Ty.Evaluate_Float
                    (Text, Ty.Float_Name (Held), Bits, Overflow);
                  if Overflow then
                     Overflowed := True;
                  else
                     Value := Ty.Folded (Bits);
                     Known := True;
                  end if;
               end;
            end if;

         when Syn.Character_Literal =>
            Value := Ty.Folded (Character_Value (Of_Tree, Node));
            Known := True;

         when Syn.True_Literal =>
            Value := 1;
            Known := True;

         when Syn.False_Literal =>
            Value := 0;
            Known := True;

         when Syn.Zeroed_Literal =>
            --  D66's labelled scalar `zeroed` is its field type's zero, and
            --  a float's zero is the all-zero pattern as well.
            Value := 0;
            Known := True;

         when Syn.Member_Selection =>
            if Float_Special_Type (Of_Tree, Node) in Ty.Float_Name then
               Value := Ty.Folded (Float_Special_Bits (Of_Tree, Node));
               Known := True;
            end if;

         when Syn.Pointer_Conversion =>
            Operand (Syn.Operand_Of (Of_Tree, Node), Value, Known);

         when Syn.Negation =>
            declare
               Under : Ty.Folded;
            begin
               Operand (Syn.Operand_Of (Of_Tree, Node), Under, Known);
               if Known then
                  if Held in Ty.Float_Name then
                     Value := Ty.Folded
                       (Ty.Negated_Float
                          (Ty.Magnitude (Under), Ty.Float_Name (Held)));
                  else
                     Value := -Under;
                  end if;
               end if;
            end;

         when Syn.Call =>
            declare
               Target : constant Ty.Type_Kind :=
                 Conversion_Target (Of_Tree, Node);
            begin
               if Target in Ty.Scalar_Name then
                  declare
                     Argument : constant Syn.Node_Id :=
                       Syn.Nth_Argument (Of_Tree, Node, 1);
                     From : constant Ty.Type_Kind :=
                       Type_At (Of_Tree, Argument);
                     Given : Ty.Folded;
                     Sure  : Boolean;
                     Blew  : Boolean := False;
                  begin
                     Operand (Argument, Given, Sure);
                     if not Sure then
                        return;
                     end if;
                     if Target = Ty.Bool then
                        if From in Ty.Float_Name then
                           Ty.Convert_Float_To_Bool
                             (Ty.Magnitude (Given), Ty.Float_Name (From),
                              Value, Blew);
                        else
                           Value := Given;
                        end if;
                     elsif Target in Ty.Integer_Name then
                        if From in Ty.Float_Name then
                           Ty.Convert_Float_To_Integer
                             (Ty.Magnitude (Given), Ty.Float_Name (From),
                              Ty.Integer_Name (Target), Facts, Value, Blew);
                        else
                           Value := Given;
                        end if;
                     elsif Target in Ty.Float_Name then
                        if From = Ty.Bool then
                           Value := Ty.Folded
                             (Ty.Convert_Bool_To_Float
                                (Given, Ty.Float_Name (Target)));
                        elsif From in Ty.Integer_Name then
                           Value := Ty.Folded
                             (Ty.Convert_Integer_To_Float
                                (Given, Ty.Float_Name (Target)));
                        elsif From in Ty.Float_Name then
                           declare
                              Converted : Ty.Magnitude;
                           begin
                              Ty.Convert_Float_Width
                                (Ty.Magnitude (Given), Ty.Float_Name (From),
                                 Ty.Float_Name (Target), Converted, Blew);
                              Value := Ty.Folded (Converted);
                           end;
                        else
                           return;
                        end if;
                     else
                        return;
                     end if;
                     if Blew then
                        Overflowed := True;
                     else
                        Known := True;
                     end if;
                  end;
               end if;
            end;

         when Syn.Name_Reference =>
            --  [1940]: a name bound to a module binding whose value is
            --  known is itself known.  An omitted initializer is D10's
            --  zero image; a chain that comes back to its own binding is
            --  the stage's to speak about, through Enter.
            if Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound then
               declare
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Res.Sort_Of (Meanings.all, Means) = Res.Module_Binding
                  then
                     declare
                        Their_Tree : constant
                          not null access constant Syn.Tree :=
                            Tree_For (Res.Source_Of (Meanings.all, Means));
                        Theirs : constant Syn.Node_Id :=
                          Res.Node_Of (Meanings.all, Means);
                        Their_Value : constant Syn.Node_Id :=
                          Syn.Value_Of (Their_Tree.all, Theirs);
                     begin
                        if Their_Value = Syn.No_Node then
                           Value := 0;
                           Known := True;
                        elsif Enter (Means) then
                           Fold (Their_Tree.all, Their_Value, Depth + 1,
                                 Value, Known, Overflowed);
                           Leave (Means);
                        end if;
                     end;
                  end if;
               end;
            end if;

         when Syn.Add | Syn.Subtract | Syn.Multiply | Syn.Divide
            | Syn.Remainder =>
            declare
               Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
               Left, Right : Ty.Folded;
               Left_Known, Right_Known : Boolean;
               Fits, Overflows : Boolean;
            begin
               Operand (Syn.Left_Of (Of_Tree, Node), Left, Left_Known);
               Operand (Syn.Right_Of (Of_Tree, Node), Right, Right_Known);
               if Overflowed or else not (Left_Known and Right_Known) then
                  return;
               end if;
               if Held in Ty.Float_Name then
                  if Op = Syn.Remainder then
                     return;
                  end if;
                  Value := Ty.Folded
                    (Ty.Float_Arithmetic_Result
                       (Ty.Magnitude (Left), Ty.Magnitude (Right),
                        Ty.Float_Name (Held),
                        (case Op is
                            when Syn.Add      => Ty.Float_Add,
                            when Syn.Subtract => Ty.Float_Subtract,
                            when Syn.Multiply => Ty.Float_Multiply,
                            when others       => Ty.Float_Divide)));
                  Known := True;
               else
                  Combine (Left, Right, Op, Value, Fits, Overflows);
                  Known := Fits;
                  Overflowed := Overflows;
               end if;
            end;

         when Syn.Wrapping_Add | Syn.Wrapping_Subtract
            | Syn.Wrapping_Multiply
            | Syn.Bitwise_And | Syn.Bitwise_Xor | Syn.Bitwise_Or
            | Syn.Shift_Left | Syn.Shift_Right =>
            declare
               Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
               Left, Right : Ty.Folded;
               Left_Known, Right_Known : Boolean;
            begin
               Operand (Syn.Left_Of (Of_Tree, Node), Left, Left_Known);
               Operand (Syn.Right_Of (Of_Tree, Node), Right, Right_Known);
               --  A negative shift amount is [0320]'s refusal and is left
               --  unknown here; a negative mask operand is an ordinary
               --  two's-complement pattern.
               if Overflowed
                 or else not (Left_Known and Right_Known)
                 or else Held not in Ty.Scalar_Name
                 or else (Right < 0
                          and then Op in Syn.Shift_Left | Syn.Shift_Right)
               then
                  return;
               end if;
               declare
                  Bits : constant Landin.Targets.Bit_Width :=
                    Fold_Width (Ty.Scalar_Name (Held));
                  Signed : constant Boolean :=
                    Is_Signed_Type (Ty.Scalar_Name (Held));
                  LP : constant Pattern := To_Pattern (Left, Bits);
                  RP : constant Pattern := To_Pattern (Right, Bits);
                  Exhausted : constant Boolean :=
                    Op in Syn.Shift_Left | Syn.Shift_Right
                      and then Right >= Ty.Folded (Bits);
                  Answer : Pattern := 0;
               begin
                  case Op is
                     when Syn.Wrapping_Add =>
                        Answer := Mask (LP + RP, Bits);
                     when Syn.Wrapping_Subtract =>
                        Answer := Mask (LP - RP, Bits);
                     when Syn.Wrapping_Multiply =>
                        Answer := Mask (LP * RP, Bits);
                     when Syn.Bitwise_And =>
                        Answer := Mask (LP and RP, Bits);
                     when Syn.Bitwise_Xor =>
                        Answer := Mask (LP xor RP, Bits);
                     when Syn.Bitwise_Or =>
                        Answer := Mask (LP or RP, Bits);
                     when Syn.Shift_Left =>
                        Answer :=
                          (if Exhausted then 0
                           else Mask (LP * 2 ** Natural (Right), Bits));
                     when Syn.Shift_Right =>
                        --  [0320]: signed `>>` keeps the sign and unsigned
                        --  fills with zeros, as the backend does.
                        Answer :=
                          (if Exhausted then 0
                           elsif Signed and then Left < 0
                           then Mask
                                  (not (Mask (not LP, Bits)
                                        / 2 ** Natural (Right)),
                                   Bits)
                           else Mask (LP / 2 ** Natural (Right), Bits));
                     when others =>
                        raise Landin.Compiler_Defect
                          with "unreachable width-op fold";
                  end case;
                  Value := As_Number (Answer, Bits, Signed);
                  Known := True;
               end;
            end;

         when Syn.Complement =>
            declare
               Under : Ty.Folded;
               Sure  : Boolean;
            begin
               Operand (Syn.Operand_Of (Of_Tree, Node), Under, Sure);
               if Sure and then Held in Ty.Scalar_Name then
                  declare
                     Bits : constant Landin.Targets.Bit_Width :=
                       Fold_Width (Ty.Scalar_Name (Held));
                  begin
                     Value := As_Number
                       (Mask (not To_Pattern (Under, Bits), Bits), Bits,
                        Is_Signed_Type (Ty.Scalar_Name (Held)));
                     Known := True;
                  end;
               end if;
            end;

         when Syn.Logical_Not =>
            declare
               Under : Ty.Folded;
               Sure  : Boolean;
            begin
               Operand (Syn.Operand_Of (Of_Tree, Node), Under, Sure);
               if Sure then
                  Value := 1 - Under;
                  Known := True;
               end if;
            end;

         when Syn.Logical_And | Syn.Logical_Or =>
            declare
               Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
               Left, Right : Ty.Folded;
               Left_Known, Right_Known : Boolean;
            begin
               Operand (Syn.Left_Of (Of_Tree, Node), Left, Left_Known);
               if Overflowed or else not Left_Known then
                  return;
               end if;
               if (Op = Syn.Logical_And and then Left = 0)
                 or else (Op = Syn.Logical_Or and then Left = 1)
               then
                  Value := Left;
                  Known := True;
               else
                  Operand (Syn.Right_Of (Of_Tree, Node), Right, Right_Known);
                  if Right_Known then
                     Value := Right;
                     Known := True;
                  end if;
               end if;
            end;

         when Syn.Equal_To | Syn.Not_Equal_To
            | Syn.Less_Than | Syn.Less_Or_Equal
            | Syn.Greater_Than | Syn.Greater_Or_Equal =>
            declare
               Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
               Left_Node : constant Syn.Node_Id := Syn.Left_Of (Of_Tree, Node);
               Sides : constant Ty.Type_Kind := Type_At (Of_Tree, Left_Node);
               Left, Right : Ty.Folded;
               Left_Known, Right_Known : Boolean;
            begin
               Operand (Left_Node, Left, Left_Known);
               Operand (Syn.Right_Of (Of_Tree, Node), Right, Right_Known);
               if Overflowed or else not (Left_Known and Right_Known) then
                  return;
               end if;
               if Sides in Ty.Float_Name then
                  Value := Ty.Folded
                    (Boolean'Pos
                       (Ty.Float_Comparison_Result
                          (Ty.Magnitude (Left), Ty.Magnitude (Right),
                           Ty.Float_Name (Sides),
                           (case Op is
                               when Syn.Equal_To      => Ty.Float_Equal,
                               when Syn.Not_Equal_To  => Ty.Float_Not_Equal,
                               when Syn.Less_Than     => Ty.Float_Less,
                               when Syn.Less_Or_Equal =>
                                 Ty.Float_Less_Or_Equal,
                               when Syn.Greater_Than  => Ty.Float_Greater,
                               when others =>
                                 Ty.Float_Greater_Or_Equal))));
               else
                  Value :=
                    (case Op is
                        when Syn.Equal_To =>
                          (if Left = Right then 1 else 0),
                        when Syn.Not_Equal_To =>
                          (if Left /= Right then 1 else 0),
                        when Syn.Less_Than =>
                          (if Left < Right then 1 else 0),
                        when Syn.Less_Or_Equal =>
                          (if Left <= Right then 1 else 0),
                        when Syn.Greater_Than =>
                          (if Left > Right then 1 else 0),
                        when others =>
                          (if Left >= Right then 1 else 0));
               end if;
               Known := True;
            end;

         when Syn.Size_Of | Syn.Align_Of =>
            --  [0370]: a measurement of an enabled type folds to the
            --  target's own byte count; that it is a `usize` is the point.
            declare
               Asked : constant Syn.Node_Id :=
                 Syn.Measured_Type (Of_Tree, Node);
               Measured : constant Ty.Type_Kind := Type_At (Of_Tree, Asked);
               Sizing : constant Boolean :=
                 Syn.Kind (Of_Tree, Node) = Syn.Size_Of;
            begin
               if Measured in Ty.Scalar_Name then
                  declare
                     Size : constant Landin.Targets.Scalar_Size :=
                       Ty.Storage_Size (Ty.Scalar_Name (Measured), Facts);
                  begin
                     Value :=
                       (if Sizing
                        then Ty.Folded (Landin.Targets.Bytes (Size))
                        else Ty.Folded
                               (Landin.Targets.Alignment_Of (Facts, Size)));
                     Known := True;
                  end;
               elsif Measured = Ty.Fixed_Array then
                  declare
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Checking.Array_Type_Extent
                       (Types.all, Of_Tree, Asked, Facts, Size, Alignment);
                     Value := (if Sizing then Ty.Folded (Size)
                               else Ty.Folded (Alignment));
                     Known := True;
                  end;
               elsif Measured = Ty.Aggregate then
                  declare
                     Declared : constant Landin.Checking.Nominal_Type_Id :=
                       Landin.Checking.Nominal_Of (Types.all, Of_Tree, Asked);
                  begin
                     if Declared /= Landin.Checking.No_Nominal_Type
                       and then Landin.Checking.Has_Layout
                                  (Types.all, Declared)
                     then
                        Value := Ty.Folded
                          (if Sizing
                           then Landin.Checking.Layout_Size
                                  (Types.all, Declared)
                           else Landin.Checking.Layout_Alignment
                                  (Types.all, Declared));
                        Known := True;
                     end if;
                  end;
               end if;
            end;

         when Syn.Len_Of =>
            --  [0370]: an element count is target-neutral: D14 takes it
            --  from a named array's type, D31 from a literal's source run.
            declare
               Asked : constant Syn.Node_Id := Syn.Operand_Of (Of_Tree, Node);
            begin
               if Syn.Kind (Of_Tree, Asked) = Syn.Array_Literal then
                  Value := Ty.Folded (Syn.Element_Count (Of_Tree, Asked));
                  Known := True;
               elsif Syn.Kind (Of_Tree, Asked) = Syn.Name_Reference
                 and then Res.Verdict_Of (Meanings.all, Of_Tree, Asked)
                          = Res.Bound
               then
                  declare
                     Named : constant Res.Declaration_Id :=
                       Res.Bound_To (Meanings.all, Of_Tree, Asked);
                  begin
                     if Landin.Checking.Type_Of (Types.all, Named)
                          = Ty.Fixed_Array
                     then
                        Value := Ty.Folded
                          (Landin.Checking.Array_Length (Types.all, Named));
                        Known := True;
                     end if;
                  end;
               end if;
            end;

         when others =>
            null;
      end case;
   end Fold;

end Landin.Stages.Folding;
