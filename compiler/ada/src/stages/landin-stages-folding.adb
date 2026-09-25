with Ada.Containers.Ordered_Maps;
with Ada.Containers.Vectors;

package body Landin.Stages.Folding is

   package Res renames Landin.Resolution;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;

   use type Landin.Targets.Bit_Width;
   use type Landin.Checking.Nominal_Type_Id;
   use type Res.Declaration_Sort;
   use type Res.Declaration_Id;
   use type Res.Verdict;
   use type Syn.Node_Id;
   use type Syn.Node_Kind;
   use type Ty.Folded;
   use type Ty.Type_Kind;

   package Known_Values is new Ada.Containers.Ordered_Maps
     (Key_Type => Res.Declaration_Id, Element_Type => Ty.Folded);

   procedure Fold
     (Cache      : in out Known_Values.Map;
      Of_Tree    : Syn.Tree;
      Node       : Syn.Node_Id;
      Depth      : Natural;
      Value      : out Ty.Folded;
      Known      : out Boolean;
      Overflowed : out Boolean);

   --  Values of final bindings, kept across queries.  Only a value whose
   --  whole fold read final bindings is entered; Read_Unfinished records,
   --  for the walk in progress, whether it has read one that is not.
   Final_Values    : Known_Values.Map;
   Read_Unfinished : Boolean := False;
   Global_View     : Boolean := True;

   --  Within one request, the whole outcome of each binding the dependency
   --  walk proved acyclic, unknown and overflowing ones included.  Such a
   --  fold meets no cycle and so reports nothing: walking it again would
   --  only find the same outcome, one nested call per link.
   type Outcome is record
      Value      : Ty.Folded := 0;
      Known      : Boolean := False;
      Overflowed : Boolean := False;
      Unfinished : Boolean := False;
   end record;

   package Outcome_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type => Res.Declaration_Id, Element_Type => Outcome);

   Outcomes : Outcome_Maps.Map;

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
     (Cache      : in out Known_Values.Map;
      Of_Tree    : Syn.Tree;
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
         Fold (Cache, Of_Tree, Item, Depth + 1, Got, Sure, Blew);
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

      --  D213 changes only nominal identity.  A checked representation
      --  conversion preserves the complete scalar image, including float
      --  bits, and follows the ordinary guarded module-name fold.
      if Landin.Checking.Distinct_Conversion_Of
        (Types.all, Of_Tree, Node) /= Landin.Checking.No_Nominal_Type
      then
         Operand (Syn.Nth_Argument (Of_Tree, Node, 1), Value, Known);
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
                  if Res.Sort_Of (Meanings.all, Means) = Res.Module_Atom then
                     --  Static images retain a neutral declaration identity;
                     --  the target backend alone assigns its runtime code.
                     Value := (if Held = Ty.Pointer_Value then 0
                               else Ty.Folded (Means));
                     Known := True;
                  elsif Res.Sort_Of (Meanings.all, Means) = Res.Module_Binding
                  then
                     if Global_View and then Final_Values.Contains (Means)
                     then
                        Value := Final_Values.Element (Means);
                        Known := True;
                     elsif Cache.Contains (Means) then
                        --  Not kept, so it read something unfinished.
                        Value := Cache.Element (Means);
                        Known := True;
                        Read_Unfinished := True;
                     elsif Outcomes.Contains (Means) then
                        declare
                           Found : constant Outcome := Outcomes (Means);
                        begin
                           Value := Found.Value;
                           Known := Found.Known;
                           Overflowed := Found.Overflowed;
                           Read_Unfinished :=
                             Read_Unfinished or else Found.Unfinished;
                        end;
                     else
                        declare
                           Their_Tree : constant
                             not null access constant Syn.Tree :=
                               Tree_For (Res.Source_Of (Meanings.all, Means));
                           Theirs : constant Syn.Node_Id :=
                             Res.Node_Of (Meanings.all, Means);
                           Their_Value : constant Syn.Node_Id :=
                             Syn.Value_Of (Their_Tree.all, Theirs);
                           Outer_Unfinished : constant Boolean :=
                             Read_Unfinished;
                           Final : constant Boolean :=
                             Global_View and then Is_Final (Means);
                        begin
                           Read_Unfinished := False;
                           if Their_Value = Syn.No_Node then
                              Value := 0;
                              Known := True;
                           elsif Enter (Means) then
                              Fold (Cache, Their_Tree.all, Their_Value,
                                    Depth + 1, Value, Known, Overflowed);
                              Leave (Means);
                           end if;
                           --  Unknown and overflowing folds retain the
                           --  stage's ordinary cycle/diagnostic behavior.
                           if Known and then not Overflowed then
                              if Final and then not Read_Unfinished then
                                 Final_Values.Include (Means, Value);
                              else
                                 Cache.Include (Means, Value);
                              end if;
                           end if;
                           Read_Unfinished :=
                             Outer_Unfinished or else Read_Unfinished
                             or else not Final;
                        end;
                     end if;
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
               if Measured in Ty.Scalar_Name | Ty.Atom_Value
                 | Ty.Function_Value | Ty.Pointer_Value
                 | Ty.Slice_Value | Ty.Any_Value
               then
                  declare
                     Carrier : constant Ty.Scalar_Name :=
                       (if Measured in Ty.Scalar_Name
                        then Ty.Scalar_Name (Measured)
                        elsif Measured = Ty.Atom_Value then Ty.U32
                        else Ty.Usize);
                     Words : constant Ty.Folded :=
                       (if Measured in Ty.Slice_Value | Ty.Any_Value
                        then 2 else 1);
                     Size : constant Landin.Targets.Scalar_Size :=
                       Ty.Storage_Size (Carrier, Facts);
                  begin
                     Value :=
                       (if Sizing
                        then Ty.Folded (Landin.Targets.Bytes (Size)) * Words
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


   --  The module bindings a subtree names, deepest first: a chain of
   --  bindings each named by the one after it would otherwise be folded by
   --  one nested call per link, and a long enough chain is deeper than any
   --  host stack.  The walk here holds its own stacks on the heap.
   package Node_Stacks is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Syn.Node_Id);

   type Visit_State is (On_Path, Acyclic, Cyclic);

   package Visit_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type => Res.Declaration_Id, Element_Type => Visit_State);

   type Frame is record
      Means   : Res.Declaration_Id;
      Pending : Node_Stacks.Vector;
      Tainted : Boolean := False;
   end record;

   package Frame_Stacks is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Frame);

   procedure Fold_Dependencies
     (Cache   : in out Known_Values.Map;
      Of_Tree : Syn.Tree;
      Node    : Syn.Node_Id);

   procedure Fold_Dependencies
     (Cache   : in out Known_Values.Map;
      Of_Tree : Syn.Tree;
      Node    : Syn.Node_Id)
   is
      Seen : Visit_Maps.Map;
      Path : Frame_Stacks.Vector;

      --  The initializer of a binding the walk may expand, or No_Node.
      function Expandable (Means : Res.Declaration_Id) return Syn.Node_Id;

      function Expandable (Means : Res.Declaration_Id) return Syn.Node_Id
      is
      begin
         if Res.Sort_Of (Meanings.all, Means) /= Res.Module_Binding
           or else Cache.Contains (Means)
           or else Outcomes.Contains (Means)
           or else (Global_View and then Final_Values.Contains (Means))
         then
            return Syn.No_Node;
         end if;
         return Syn.Value_Of
           (Tree_For (Res.Source_Of (Meanings.all, Means)).all,
            Res.Node_Of (Meanings.all, Means));
      end Expandable;

      --  Push a subtree's nodes onto a frame's pending run.
      procedure Push_Subtree
        (Into : in out Node_Stacks.Vector; Root : Syn.Node_Id);

      procedure Push_Subtree
        (Into : in out Node_Stacks.Vector; Root : Syn.Node_Id) is
      begin
         if Root /= Syn.No_Node then
            Into.Append (Root);
         end if;
      end Push_Subtree;

      Root_Frame : Frame;
   begin
      Root_Frame.Means := Res.No_Declaration;
      Push_Subtree (Root_Frame.Pending, Node);
      Path.Append (Root_Frame);
      while not Path.Is_Empty loop
         declare
            Top : constant Positive := Path.Last_Index;
            Tree_Of_Top : constant not null access constant Syn.Tree :=
              (if Path (Top).Means = Res.No_Declaration
               then Tree_For (Syn.Source_Of (Of_Tree))
               else Tree_For (Res.Source_Of (Meanings.all, Path (Top).Means)));
         begin
            if Path (Top).Pending.Is_Empty then
               --  Every name below this binding has been seen.  An acyclic
               --  one is folded now, with everything it reads already in
               --  the cache.
               declare
                  Done : constant Frame := Path (Top);
               begin
                  Path.Delete_Last;
                  if Done.Means /= Res.No_Declaration then
                     if Done.Tainted then
                        Seen.Replace (Done.Means, Cyclic);
                        Path (Path.Last_Index).Tainted := True;
                     else
                        Seen.Replace (Done.Means, Acyclic);
                        declare
                           Their_Tree : constant
                             not null access constant Syn.Tree :=
                               Tree_For
                                 (Res.Source_Of (Meanings.all, Done.Means));
                           Their_Value : constant Syn.Node_Id :=
                             Syn.Value_Of
                               (Their_Tree.all,
                                Res.Node_Of (Meanings.all, Done.Means));
                           Final : constant Boolean :=
                             Global_View and then Is_Final (Done.Means);
                           Value : Ty.Folded;
                           Known, Overflowed : Boolean;
                        begin
                           if Their_Value = Syn.No_Node then
                              null;
                           elsif Enter (Done.Means) then
                              Read_Unfinished := False;
                              Fold (Cache, Their_Tree.all, Their_Value, 1,
                                    Value, Known, Overflowed);
                              Leave (Done.Means);
                              if Known and then not Overflowed then
                                 if Final and then not Read_Unfinished then
                                    Final_Values.Include (Done.Means, Value);
                                 else
                                    Cache.Include (Done.Means, Value);
                                 end if;
                              else
                                 Outcomes.Include
                                   (Done.Means,
                                    (Value, Known, Overflowed,
                                     Read_Unfinished or else not Final));
                              end if;
                           end if;
                        end;
                     end if;
                  end if;
               end;
            else
               declare
                  Next : constant Syn.Node_Id :=
                    Path (Top).Pending.Last_Element;
               begin
                  Path (Top).Pending.Delete_Last;
                  if Syn.Kind (Tree_Of_Top.all, Next) = Syn.Name_Reference
                    and then Res.Verdict_Of (Meanings.all, Tree_Of_Top.all,
                                             Next) = Res.Bound
                  then
                     declare
                        Means : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Tree_Of_Top.all, Next);
                        Value_Node : constant Syn.Node_Id :=
                          Expandable (Means);
                     begin
                        if Seen.Contains (Means) then
                           if Seen (Means) /= Acyclic then
                              Path (Top).Tainted := True;
                           end if;
                        elsif Value_Node /= Syn.No_Node then
                           Seen.Insert (Means, On_Path);
                           declare
                              Child : Frame;
                           begin
                              Child.Means := Means;
                              Push_Subtree (Child.Pending, Value_Node);
                              Path.Append (Child);
                           end;
                        end if;
                     end;
                  else
                     for Slot in 1 .. Syn.Slot_Count (Tree_Of_Top.all, Next)
                     loop
                        Push_Subtree
                          (Path (Top).Pending,
                           Syn.Slot (Tree_Of_Top.all, Next, Slot));
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Fold_Dependencies;

   procedure Fold
     (Of_Tree    : Syn.Tree;
      Node       : Syn.Node_Id;
      Depth      : Natural;
      Value      : out Ty.Folded;
      Known      : out Boolean;
      Overflowed : out Boolean)
   is
      use type Landin.Checking.Routine_Instance_Id;
      --  Semantic tables can gain facts between top-level queries, so an
      --  unfinished binding's value is shared only within this request.
      Cache : Known_Values.Map;
   begin
      Global_View := Landin.Checking.Current_Routine_View (Types.all)
        = Landin.Checking.No_Routine_Instance;
      Read_Unfinished := False;
      Outcomes.Clear;
      Fold_Dependencies (Cache, Of_Tree, Node);
      Read_Unfinished := False;
      Fold (Cache, Of_Tree, Node, Depth, Value, Known, Overflowed);
   end Fold;

end Landin.Stages.Folding;
