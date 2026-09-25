with Landin.Backend;
with Landin.Checking;
with Landin.Machine;
with Landin.Modules;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Types;

package body Landin.Panics is
   package US renames Ada.Strings.Unbounded;
   package IR renames Landin.IR;
   package R renames Landin.Resolution;
   use type IR.Item_Id;
   use type IR.Item_Kind;
   use type IR.Declaration_Id;
   use type IR.Atom_Set_Id;
   use type IR.Signature_Id;
   use type IR.Parameter_Convention;
   use type IR.Pointee_Id;
   use type IR.Nominal_Type_Id;
   use type Landin.Checking.Constraint_Id;
   use type Landin.Machine.Convention;
   use type Landin.Modules.Module_Id;
   use type R.Declaration_Sort;
   use type R.Scope_Sort;
   use type Landin.Source.Byte_Offset;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Types.Type_Kind;

   function Handler (Of_Plan : Plan) return IR.Item_Id is (Of_Plan.Selected);
   function Code (Of_Plan : Plan; Reason : Kind) return Positive
     is (Of_Plan.Codes (Reason));

   function For_Value
     (Of_Unit : IR.Unit; Item : IR.Item_Id; Value : IR.Value_Id) return Kind
   is
   begin
      if IR.Checks_Representation (Of_Unit, Item, Value) then
         return Bad_Conversion;
      end if;
      case IR.Op_Of (Of_Unit, Item, Value) is
         when IR.Negation | IR.Add | IR.Subtract | IR.Multiply |
           IR.Divide | IR.Remainder => return Overflow;
         when IR.Range_Check | IR.Slice_Address | IR.Storage_Address |
           IR.Load_Element |
           IR.Store_Element | IR.Shift_Left | IR.Shift_Right =>
            return Out_Of_Range;
         when IR.Conversion | IR.Pointer_Address | IR.Memory_Access |
           IR.Load_Field |
           IR.Store_Field => return Bad_Conversion;
         when IR.Halt => return Unreachable;
         when others =>
            raise Compiler_Defect with "unclassified compiler check";
      end case;
   end For_Value;

   function Base
     (Of_Plan : Plan; Source : Landin.Source.Source_Id) return Site_Number
   is
   begin
      if Source = Landin.Source.No_Source
        or else Natural (Source) > Natural (Of_Plan.Sources.Length)
      then
         raise Compiler_Defect with "panic site has no source range";
      end if;
      return Of_Plan.Sources (Positive (Source)).First;
   end Base;

   function Site
     (Of_Plan : Plan; Origin : Landin.Provenance.Origin;
      Reason : Kind) return Site_Number
   is
      First : Site_Number;
   begin
      if not Landin.Provenance.Is_Known (Origin) then
         return 0;
      end if;
      First := Base (Of_Plan, Origin.Source);
      if Origin.Where.Last > Of_Plan.Sources
        (Positive (Origin.Source)).Length
      then
         raise Compiler_Defect with "panic site is outside its source";
      end if;
      return First + 4 * Site_Number (Origin.Where.First)
        + Site_Number (Kind'Pos (Reason));
   end Site;

   procedure Prepare
     (Context : in out Landin.Stages.Compilation;
      Into : out Plan; Problem : out US.Unbounded_String)
   is
      Unit : IR.Unit renames Landin.Stages.Code (Context).all;
      Meanings : R.Table renames Landin.Stages.Meanings (Context).all;
      Modules : Landin.Modules.Table renames
        Landin.Stages.Modules (Context).all;
      Types : Landin.Checking.Table renames Landin.Stages.Types (Context).all;
      Names : Landin.Source.Names.Table renames
        Landin.Stages.Identities (Context).all;
      Next : Site_Number := 1;
      Selected : IR.Declaration_Id := IR.No_Declaration;
      Atoms : array (Kind) of IR.Declaration_Id :=
        [others => IR.No_Declaration];
      Core : constant Landin.Modules.Module_Id :=
        Landin.Modules.Find_Logical (Modules, "core/panic");

      function Spelling (Id : IR.Declaration_Id) return String is
        (Landin.Source.Names.Spelling (Names, R.Name_Of (Meanings, Id)));

      function Kind_Name (Reason : Kind) return String is
        (case Reason is
            when Out_Of_Range => "out_of_range",
            when Overflow => "overflow",
            when Bad_Conversion => "bad_conversion",
            when Unreachable => "unreachable");

      function Valid return Boolean;
      function Valid return Boolean is
         Item : constant IR.Item_Id := IR.Item_For (Unit, Selected);
         Sig : IR.Signature_Id;
      begin
         if Item = IR.No_Item or else IR.Kind_Of (Unit, Item) /= IR.Routine
           or else not R.Is_Public (Meanings, Selected)
           or else IR.Is_External (Unit, Item)
           or else IR.Generic_Template_Of (Unit, Item) /= IR.No_Declaration
           or else IR.Link_Symbol (Unit, Item) /= Landin.Source.Names.No_Name
         then
            return False;
         end if;
         Sig := IR.Signature_Of (Unit, Item);
         if Sig = IR.No_Signature
           or else IR.Signature_Machine (Unit, Sig) /= Landin.Machine.Ordinary
           or else IR.Signature_Uses_C_ABI (Unit, Sig)
           or else not IR.Signature_Never_Returns (Unit, Sig)
           or else IR.Signature_Errors (Unit, Sig) /= IR.No_Atom_Set
           or else IR.Signature_Parameter_Count (Unit, Sig) /= 2
         then
            return False;
         end if;
         for Index in 1 .. 2 loop
            declare
               Part : constant IR.Signature_Part :=
                 IR.Nth_Signature_Parameter (Unit, Sig, Index);
            begin
               if Part.Kind /= Landin.Types.U32
                 or else Part.Nominal /= IR.No_Nominal_Type
                 or else Part.Convention /= IR.In_Value
                 or else Part.Pointee /= IR.No_Pointee
                 or else Part.Escaping
               then
                  return False;
               end if;
               if Index = 2 then
                  if Part.Atoms /= IR.No_Atom_Set then
                     return False;
                  end if;
               elsif Part.Atoms = IR.No_Atom_Set
                 or else IR.Atom_Count (Unit, Part.Atoms) /= 4
               then
                  return False;
               else
                  for Reason in Kind loop
                     declare
                        Found : Boolean := False;
                     begin
                        for Position in 1 .. 4 loop
                           Found := Found or else IR.Nth_Atom
                             (Unit, Part.Atoms, Position) = Atoms (Reason);
                        end loop;
                        if not Found then
                           return False;
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
         --  Range constraints and caller insertion are source signature
         --  facts; the physical u32 carrier must not hide either contract.
         declare
            Source_Sig : constant Landin.Checking.Signature_Id :=
              Landin.Checking.Signature_Of (Types, Selected);
         begin
            for Index in 1 .. 2 loop
               declare
                  Part : constant Landin.Checking.Signature_Part :=
                    Landin.Checking.Nth_Signature_Parameter
                      (Types, Source_Sig, Index);
               begin
                  if Part.Constraint /= Landin.Checking.No_Constraint
                    or else Part.Caller
                  then
                     return False;
                  end if;
               end;
            end loop;
         end;
         Into.Selected := Item;
         return True;
      end Valid;
   begin
      Into := (others => <>);
      Problem := US.Null_Unbounded_String;
      for Index in 1 .. Landin.Stages.Source_Count (Context) loop
         declare
            Length : constant Landin.Source.Byte_Offset := Landin.Source.Length
              (Landin.Stages.Source
                 (Context, Landin.Stages.Nth_Source (Context, Index)));
         begin
            if Site_Number (Length) >= (Site_Number'Last - Next) / 4 then
               Problem := US.To_Unbounded_String
                 ("source snapshots exceed the u32 panic-site space");
               return;
            end if;
            Into.Sources.Append (Source_Range'(Next, Length));
            Next := Next + 4 * (Site_Number (Length) + 1);
         end;
      end loop;
      for Index in 1 .. R.Declaration_Count (Meanings) loop
         declare
            Id : constant IR.Declaration_Id := IR.Declaration_Id (Index);
            Module : constant Landin.Modules.Module_Id :=
              Landin.Modules.Module_Of (Modules, R.Source_Of (Meanings, Id));
         begin
            if R.Sort_Of (Meanings, R.Scope_Of (Meanings, Id))
              in R.Program | R.Module_Scope
            then
               if Module = Landin.Modules.Entry_Module
                 and then Spelling (Id) = "panic_handler"
               then
                  Selected := Id;
               elsif Core /= Landin.Modules.No_Module and then Module = Core
                 and then R.Sort_Of (Meanings, Id) = R.Module_Atom
                 and then R.Is_Public (Meanings, Id)
               then
                  for Reason in Kind loop
                     if Spelling (Id) = Kind_Name (Reason) then
                        Atoms (Reason) := Id;
                     end if;
                  end loop;
               end if;
            end if;
         end;
      end loop;
      if Selected = IR.No_Declaration then
         return;
      end if;
      if not Valid then
         Problem := US.To_Unbounded_String
           ("panic_handler must be public, ordinary, non-generic and "
            & "infallible: (core/panic.panic_kind, u32) -> noreturn");
         return;
      end if;
      --  The ordinary atom ABI is dense declaration order, excluding zero;
      --  Valid has required every reason's atom to be in the handler's set.
      declare
         Codes : constant Landin.Backend.Atom_Codes :=
           Landin.Backend.Ranked (Unit);
      begin
         for Reason in Kind loop
            Into.Codes (Reason) :=
              Landin.Backend.Atom_Code (Codes, Atoms (Reason));
         end loop;
      end;
   end Prepare;
end Landin.Panics;
