with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Landin.Backend.Debug_Locations;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets.Layouts;
with Landin.Types;

package body Landin.Backend.X86_64.Dwarf is

   package US renames Ada.Strings.Unbounded;
   use Landin.IR;
   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Nominal_Type_Id;
   use type Landin.IR.Scope_Id;
   use type Landin.Resolution.Scope_Sort;
   use type Allocation.Location_Kind;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Targets.Byte_Count;
   use type Landin.Types.Type_Kind;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function N (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Quoted (Bytes : String) return String is
      Result : US.Unbounded_String := US.To_Unbounded_String ("""");
      Octal : constant String := "01234567";
   begin
      for Byte of Bytes loop
         if Byte in '"' | '\' then
            US.Append (Result, '\');
            US.Append (Result, Byte);
         elsif Character'Pos (Byte) in 32 .. 126 then
            US.Append (Result, Byte);
         else
            declare
               Value : constant Natural := Character'Pos (Byte);
            begin
               US.Append (Result, '\');
               US.Append (Result, Octal (Value / 64 + 1));
               US.Append (Result, Octal (Value / 8 mod 8 + 1));
               US.Append (Result, Octal (Value mod 8 + 1));
            end;
         end if;
      end loop;
      US.Append (Result, '"');
      return US.To_String (Result);
   end Quoted;

   function Label_Name
     (Prefix, Kind : String; Item : Item_Id;
      Index : Natural := 0) return String
   is (Prefix & "debug_" & Kind & "_" & N (Natural (Item)) & "_"
       & N (Index));

   function Register_Number
     (Register : Allocation.Saved_Register) return Natural
   is (case Register is
          when Allocation.RBX => 3,
          when Allocation.R12 => 12,
          when Allocation.R13 => 13,
          when Allocation.R14 => 14,
          when Allocation.R15 => 15);

   function Source_Line
     (Info : Landin.Debugging.Information;
      Site : Landin.Provenance.Origin) return String
   is
   begin
      if not Landin.Provenance.Is_Known (Site) then
         return "";
      end if;
      declare
         Pos : constant Landin.Source.Position := Landin.Source.Position_Of
           (Landin.Debugging.Source (Info, Site.Source), Site.Where.First);
      begin
         return HT & ".loc " & N (Natural (Site.Source)) & " "
           & N (Natural (Pos.Line)) & " " & N (Natural (Pos.Column));
      end;
   end Source_Line;

   function Preamble
     (Info : Landin.Debugging.Information; Prefix : String) return String
   is
      Result : US.Unbounded_String;
   begin
      US.Append (Result, HT & ".cfi_sections .debug_frame" & LF);
      US.Append (Result, HT & ".section .debug_line,"""",@progbits" & LF);
      US.Append (Result, Prefix & "debug_line:" & LF & HT & ".text" & LF);
      for Index in 1 .. Landin.Debugging.Count (Info) loop
         US.Append (Result, HT & ".file " & N (Index) & " "
           & Quoted (Landin.Source.Name (Landin.Debugging.Source
               (Info, Landin.Source.Source_Id (Index)))) & LF);
      end loop;
      return US.To_String (Result);
   end Preamble;

   function Sections
     (Of_Unit : Unit;
      Meanings : Landin.Resolution.Table;
      Names : Landin.Source.Names.Table;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Info : Landin.Debugging.Information;
      Prefix : String;
      Symbol : not null access function (Item : Item_Id) return String)
      return String
   is
      Result, Locations, Ranges : US.Unbounded_String;
      CU : constant String := Prefix & "debug_info";
      type Description is record
         Shape : Field_Shape;
         Source : Landin.Source.Source_Id := Landin.Source.No_Source;
         Node : Landin.Syntax.Node_Id := Landin.Syntax.No_Node;
         Item : Item_Id := No_Item;
         Slot : Slot_Id := No_Slot;
      end record;
      package Descriptions is new Ada.Containers.Vectors
        (Positive, Description);
      Types : Descriptions.Vector;

      procedure Put (Text : String);
      procedure Put (Text : String) is
      begin
         US.Append (Result, Text & LF);
      end Put;

      procedure U (Value : Natural);
      procedure U (Value : Natural) is
      begin
         Put (HT & ".uleb128 " & N (Value));
      end U;

      procedure Ref (Name : String);
      procedure Ref (Name : String) is
      begin
         Put (HT & ".long " & Name & "-" & CU);
      end Ref;

      procedure Str (Text : String);
      procedure Str (Text : String) is
      begin
         Put (HT & ".asciz " & Quoted (Text));
      end Str;

      function L (Kind : String; Item : Item_Id; Index : Natural := 0)
         return String is (Label_Name (Prefix, Kind, Item, Index));
      function T (Index : Positive) return String is
        (Prefix & "debug_type_" & N (Index));
      function Decl_Name (Decl : Declaration_Id) return String is
        (Landin.Source.Names.Spelling
           (Names, Landin.Resolution.Name_Of (Meanings, Decl)));

      function Intern (Input : Description) return Positive;
      function Intern (Input : Description) return Positive is
         Desc : Description := Input;
      begin
         if Desc.Shape.Kind = Aggregate_Field_Shape
           and then Desc.Shape.Nominal /= No_Nominal_Type
         then
            Desc := (Shape => (Kind => Aggregate_Field_Shape,
                              Nominal => Desc.Shape.Nominal, others => <>),
                     others => <>);
            declare
               Decl : constant Declaration_Id :=
                 Template_Of (Of_Unit, Desc.Shape.Nominal);
               Tree : constant access constant Landin.Syntax.Tree :=
                 Landin.Syntax.Forest.Tree_Of
                   (Info.Trees.all,
                    Landin.Resolution.Source_Of (Meanings, Decl));
               Node : constant Landin.Syntax.Node_Id :=
                 Landin.Resolution.Node_Of (Meanings, Decl);
            begin
               if Landin.Syntax.Kind (Tree.all, Node)
                 = Landin.Syntax.Type_Declaration
               then
                  Desc.Source := Landin.Syntax.Source_Of (Tree.all);
                  Desc.Node := Landin.Syntax.Declared_Type (Tree.all, Node);
               end if;
            end;
         elsif Desc.Shape.Kind = Scalar_Field_Shape then
            Desc.Source := Landin.Source.No_Source;
            Desc.Node := Landin.Syntax.No_Node;
         end if;
         for Index in 1 .. Natural (Types.Length) loop
            if Types (Index) = Desc then
               return Index;
            end if;
         end loop;
         Types.Append (Desc);
         return Natural (Types.Length);
      end Intern;

      function Shape_Type
        (Shape : Field_Shape;
         Source : Landin.Source.Source_Id := Landin.Source.No_Source;
         Node : Landin.Syntax.Node_Id := Landin.Syntax.No_Node)
         return Positive is
        (Intern ((Shape => Shape, Source => Source, Node => Node,
                  others => <>)));

      procedure Coordinates (Site : Landin.Provenance.Origin);
      procedure Coordinates (Site : Landin.Provenance.Origin) is
         Pos : constant Landin.Source.Position := Landin.Source.Position_Of
           (Landin.Debugging.Source (Info, Site.Source), Site.Where.First);
      begin
         U (Natural (Site.Source));
         U (Natural (Pos.Line));
         U (Natural (Pos.Column));
      end Coordinates;

      procedure Member
        (Name : String; Typ : Positive; Offset : Landin.Targets.Byte_Count);
      procedure Member
        (Name : String; Typ : Positive; Offset : Landin.Targets.Byte_Count)
      is
      begin
         U (7);
         Str (Name);
         Ref (T (Typ));
         Put (HT & ".uleb128 " & Landin.Targets.Byte_Count'Image (Offset));
      end Member;

      procedure Emit_Type (Index : Positive);
      procedure Emit_Type (Index : Positive) is
         Desc : constant Description := Types (Index);
         Shape : constant Field_Shape := Desc.Shape;
         Size : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment;
         Tree : access constant Landin.Syntax.Tree;

         function Child_Node (Position : Positive)
            return Landin.Syntax.Node_Id;
         function Child_Node (Position : Positive)
            return Landin.Syntax.Node_Id
         is
         begin
            if Tree = null or else Desc.Node = Landin.Syntax.No_Node
              or else Landin.Syntax.Kind (Tree.all, Desc.Node)
                /= Landin.Syntax.Struct_Body
              or else Position > Landin.Syntax.Field_Count
                (Tree.all, Desc.Node)
            then
               return Landin.Syntax.No_Node;
            end if;
            return Landin.Syntax.Nth_Field (Tree.all, Desc.Node, Position);
         end Child_Node;

         function Node_Name
           (Node : Landin.Syntax.Node_Id; Fallback : String) return String;
         function Node_Name
           (Node : Landin.Syntax.Node_Id; Fallback : String) return String
         is
         begin
            if Tree = null or else Node = Landin.Syntax.No_Node
              or else not Landin.Syntax.Has_Name
                (Landin.Syntax.Kind (Tree.all, Node))
            then
               return Fallback;
            end if;
            return Landin.Source.Names.Spelling
              (Names, Landin.Syntax.Name (Tree.all, Node));
         end Node_Name;
      begin
         if Desc.Source /= Landin.Source.No_Source then
            Tree := Landin.Syntax.Forest.Tree_Of
              (Info.Trees.all, Desc.Source);
         end if;
         Put (T (Index) & ":");
         if Desc.Item /= No_Item then
            Size := Slot_Layout (Of_Unit, Desc.Item, Desc.Slot, Facts).Size;
         else
            Field_Extent (Of_Unit, Shape, Facts, Size, Alignment);
         end if;
         case Shape.Kind is
            when Scalar_Field_Shape =>
               if Shape.Pointee /= No_Pointee then
                  U (5);
                  U (Natural (Size));
                  Ref (T (Shape_Type (Pointee_Shape
                    (Of_Unit, Shape.Pointee))));
               else
                  U (4);
                  Str (Landin.Types.Spelling (Shape.Element));
                  U (Natural (Size));
                  U (if Shape.Element = Landin.Types.Bool then 2
                     elsif Shape.Element in Landin.Types.Float_Name then 4
                     elsif Shape.Element in Landin.Types.I8 .. Landin.Types.I64
                       or else Shape.Element = Landin.Types.Isize then 5
                     else 7);
               end if;
            when Array_Field_Shape =>
               U (8);
               Ref (T (Shape_Type (Array_Element_Shape (Of_Unit, Shape))));
               U (9);
               Put (HT & ".uleb128 " & Element_Total'Image (Shape.Length));
               U (0);
            when Aggregate_Field_Shape =>
               declare
                  Count : constant Natural :=
                    (if Desc.Item /= No_Item then Slot_Field_Count
                       (Of_Unit, Desc.Item, Desc.Slot)
                     else Aggregate_Field_Count (Of_Unit, Shape));
                  Fields : Field_Shape_Array (1 .. Count);
               begin
                  for Field in Fields'Range loop
                     Fields (Field) :=
                       (if Desc.Item /= No_Item then Nth_Slot_Field_Shape
                          (Of_Unit, Desc.Item, Desc.Slot, Field)
                        else Nth_Aggregate_Field (Of_Unit, Shape, Field));
                  end loop;
                  U (6);
                  Str (if Shape.Nominal /= No_Nominal_Type then
                         Decl_Name (Template_Of (Of_Unit, Shape.Nominal))
                       else "aggregate");
                  Put (HT & ".uleb128 " & Landin.Targets.Byte_Count'Image
                    (Size));
                  declare
                     Placed : constant Landin.Targets.Layouts.Plan :=
                       (if Desc.Item /= No_Item then Slot_Layout
                          (Of_Unit, Desc.Item, Desc.Slot, Facts)
                        else Fields_Layout
                          (Of_Unit, Fields, Layout_Of (Of_Unit, Shape),
                           Facts));
                  begin
                     for Field in Fields'Range loop
                        declare
                           Node : constant Landin.Syntax.Node_Id :=
                             Child_Node (Field);
                           Name : constant Landin.Source.Names.Name_Id :=
                             (if Desc.Item = No_Item then
                                Landin.Source.Names.No_Name
                              else Landin.Debugging.Result_Name
                                (Info, Declares
                                   (Of_Unit, Desc.Item, Desc.Slot), Field));
                        begin
                           Member (Node_Name (Node,
                             (if Name = Landin.Source.Names.No_Name then
                                "field_" & N (Field)
                              else Landin.Source.Names.Spelling
                                (Names, Name))),
                             Shape_Type (Fields (Field), Desc.Source, Node),
                             Placed.Offsets (Field));
                        end;
                     end loop;
                  end;
                  U (0);
               end;
            when Variant_Field_Shape =>
               --  A truthful C-like tagged overlay, not a claim that GDB
               --  implements Landin's match syntax.  tag is zero-based;
               --  each named case exposes its payload at the actual offsets.
               U (6);
               Str (Node_Name (Desc.Node, "variant"));
               Put (HT & ".uleb128 " & Landin.Targets.Byte_Count'Image (Size));
               Member ("tag", Shape_Type
                 ((Element => Shape.Element, others => <>)), 0);
               for Which in 1 .. Shape.Cases loop
                  declare
                     Case_Node : constant Landin.Syntax.Node_Id :=
                       (if Tree /= null
                          and then Desc.Node /= Landin.Syntax.No_Node
                          and then Landin.Syntax.Kind (Tree.all, Desc.Node)
                            = Landin.Syntax.Variant_Part
                        then Landin.Syntax.Nth_Case
                          (Tree.all, Desc.Node, Which)
                        else Landin.Syntax.No_Node);
                     Case_Label : constant String :=
                       T (Index) & "_case_" & N (Which);
                  begin
                     U (7);
                     Str (Node_Name (Case_Node, "case_" & N (Which - 1)));
                     Ref (Case_Label);
                     U (0);
                  end;
               end loop;
               U (0);
               for Which in 1 .. Shape.Cases loop
                  declare
                     Case_Node : constant Landin.Syntax.Node_Id :=
                       (if Tree /= null
                          and then Desc.Node /= Landin.Syntax.No_Node
                          and then Landin.Syntax.Kind (Tree.all, Desc.Node)
                            = Landin.Syntax.Variant_Part
                        then Landin.Syntax.Nth_Case
                          (Tree.all, Desc.Node, Which)
                        else Landin.Syntax.No_Node);
                  begin
                     Put (T (Index) & "_case_" & N (Which) & ":");
                     U (6);
                     Str (Node_Name (Case_Node, "case_" & N (Which - 1)));
                     Put (HT & ".uleb128 "
                       & Landin.Targets.Byte_Count'Image (Size));
                     for Field in 1 .. Variant_Case_Field_Count
                       (Of_Unit, Shape, Which)
                     loop
                        declare
                           Node : constant Landin.Syntax.Node_Id :=
                             (if Case_Node /= Landin.Syntax.No_Node then
                                Landin.Syntax.Nth_Payload_Field
                                  (Tree.all, Case_Node, Field)
                              else Landin.Syntax.No_Node);
                        begin
                           Member (Node_Name (Node, "field_" & N (Field)),
                             Shape_Type (Nth_Variant_Case_Field
                               (Of_Unit, Shape, Which, Field),
                               Desc.Source, Node),
                             Variant_Payload_Field_Offset
                               (Of_Unit, Shape, Which, Field, Facts));
                        end;
                     end loop;
                     U (0);
                  end;
               end loop;
         end case;
      end Emit_Type;

      procedure Routine (Item : Item_Id);
      procedure Routine (Item : Item_Id) is
         Plan : constant Allocation.Plan :=
           Allocation.Make (Of_Unit, Item, Facts, Options);
         Frame_Plan : constant Frame :=
           Allocation.Frame_For (Of_Unit, Item, Facts, Plan, Options);
         Decl : constant Declaration_Id :=
           (if Generic_Template_Of (Of_Unit, Item) /= No_Declaration
            then Generic_Template_Of (Of_Unit, Item)
            else Declares (Of_Unit, Item));
         package Scope_Vectors is new Ada.Containers.Vectors
           (Positive, Scope_Id);
         Scopes : Scope_Vectors.Vector;

         procedure Location_List
           (Loc : String; Expr : US.Unbounded_String;
            Live : Debug_Locations.Flags.Vector);
         procedure Location_List
           (Loc : String; Expr : US.Unbounded_String;
            Live : Debug_Locations.Flags.Vector)
         is
            First, Last : Value_Id := No_Value;
            procedure Flush;
            procedure Flush is
               E : constant String := Loc & "_expr_" & N (Natural (First));
            begin
               if First /= No_Value then
                  US.Append (Locations,
                    HT & ".quad " & L ("value", Item, Natural (First)) & LF
                    & HT & ".quad " & L ("after", Item, Natural (Last)) & LF
                    & HT & ".short " & E & "_end-" & E & LF
                    & E & ":" & LF & US.To_String (Expr)
                    & E & "_end:" & LF);
                  First := No_Value;
               end if;
            end Flush;
         begin
            US.Append (Locations, Loc & ":" & LF & HT & ".quad -1,0" & LF);
            if US.Length (Expr) > 0 then
               for B in 1 .. Block_Count (Of_Unit, Item) loop
                  for P in 1 .. Length (Of_Unit, Item, Block_Id (B)) loop
                     declare
                        Value : constant Value_Id := Nth_Value
                          (Of_Unit, Item, Block_Id (B), P);
                     begin
                        if Live (Positive (Value)) then
                           if First = No_Value then
                              First := Value;
                           end if;
                           Last := Value;
                        else
                           Flush;
                        end if;
                     end;
                  end loop;
               end loop;
               Flush;
            end if;
            US.Append (Locations, HT & ".quad 0,0" & LF);
         end Location_List;

         procedure Alias_Variables (Scope : Scope_Id);
         procedure Alias_Variables (Scope : Scope_Id) is
         begin
            for Index in 1 .. Source_Alias_Count (Of_Unit, Item) loop
               declare
                  Alias : constant Source_Alias :=
                    Nth_Source_Alias (Of_Unit, Item, Index);
                  Path : constant Path_Step_Array :=
                    Source_Alias_Path (Of_Unit, Item, Index);
                  Loc : constant String := L ("alias_loc", Item, Index);
                  Shape : Field_Shape;
                  Offset : Landin.Targets.Byte_Count := 0;
                  Expr : US.Unbounded_String;

                  procedure Frame_Address (Slot : Slot_Id; Indirect : Boolean);
                  procedure Frame_Address (Slot : Slot_Id; Indirect : Boolean)
                  is
                     Place : constant Allocation.Location :=
                       Plan.Slot (Positive (Slot));
                  begin
                     if Indirect and then Place.Kind = Allocation.GP then
                        Expr := US.To_Unbounded_String
                          (HT & ".byte " & N (16#70#
                            + Register_Number (Place.Register)) & LF
                           & HT & ".sleb128 0" & LF);
                     elsif Has_Slot_Home (Frame_Plan, Slot) then
                        Expr := US.To_Unbounded_String
                          (HT & ".byte 0x91" & LF & HT & ".sleb128 -"
                           & Ada.Strings.Fixed.Trim
                             (Landin.Targets.Byte_Count'Image
                               (Slot_Offset (Frame_Plan, Slot)),
                              Ada.Strings.Both) & LF);
                        if Indirect then
                           US.Append (Expr, HT & ".byte 0x06" & LF);
                        end if;
                     end if;
                  end Frame_Address;
               begin
                  if Landin.Resolution.Scope_Of (Meanings, Alias.Binding)
                    = Scope
                  then
                     case Alias.Place.Kind is
                        when Module_Datum =>
                           Expr := US.To_Unbounded_String
                             (HT & ".byte 0x03" & LF & HT & ".quad "
                              & Symbol (Alias.Place.Datum) & LF);
                           if Result_Of (Of_Unit, Alias.Place.Datum)
                             = Landin.Types.Fixed_Array
                           then
                              Shape := Whole_Array_Shape
                                (Of_Unit, Alias.Place.Datum);
                              if Alias.Field > 0 then
                                 Offset := Landin.Backend.Path_Offset
                                   (Of_Unit, Shape,
                                    [1 => (Part_Position (Alias.Field), 0)],
                                    Facts);
                                 Shape := Array_Element_Shape
                                   (Of_Unit, Shape);
                              end if;
                           else
                              Shape := Nth_Field_Shape
                                (Of_Unit, Alias.Place.Datum, Alias.Field);
                              Offset := Datum_Layout
                                (Of_Unit, Alias.Place.Datum, Facts).Offsets
                                  (Alias.Field);
                           end if;
                        when Frame_Slot =>
                           Frame_Address (Alias.Place.Slot, False);
                           if Alias.Field > 0 then
                              Shape := (if Is_Array
                                (Of_Unit, Item, Alias.Place.Slot)
                                then Slot_Array_Element_Shape
                                  (Of_Unit, Item, Alias.Place.Slot)
                                else Nth_Slot_Field_Shape
                                  (Of_Unit, Item, Alias.Place.Slot,
                                   Alias.Field));
                              if Has_Slot_Home
                                (Frame_Plan, Alias.Place.Slot)
                              then
                                 Offset := Slot_Offset
                                   (Frame_Plan, Alias.Place.Slot)
                                   - Field_Offset
                                     (Of_Unit, Item, Frame_Plan,
                                      Alias.Place.Slot,
                                      Part_Position (Alias.Field), Facts);
                              end if;
                           else
                              Shape := Whole_Slot_Array_Shape
                                (Of_Unit, Item, Alias.Place.Slot);
                           end if;
                        when Runtime_Address =>
                           Frame_Address (Alias.Place.Address, True);
                           Shape := Address_Shape
                             (Of_Unit, Item, Alias.Place.Address);
                           if Alias.Field > 0 then
                              declare
                                 Base : constant Path_Step_Array :=
                                   [1 => (Part_Position (Alias.Field), 0)];
                              begin
                                 Offset := Landin.Backend.Path_Offset
                                   (Of_Unit, Shape, Base, Facts);
                                 Shape := Shape_At (Of_Unit, Shape, Base);
                              end;
                           end if;
                     end case;
                     Offset := Offset + Landin.Backend.Path_Offset
                       (Of_Unit, Shape, Path, Facts);
                     Shape := Shape_At (Of_Unit, Shape, Path);
                     if Offset > 0 and then US.Length (Expr) > 0 then
                        US.Append (Expr, HT & ".byte 0x23" & LF
                          & HT & ".uleb128 "
                          & Landin.Targets.Byte_Count'Image (Offset) & LF);
                     end if;
                     U (10);
                     Str (Decl_Name (Alias.Binding));
                     Ref (T (Shape_Type (Shape)));
                     Coordinates (Alias.Site);
                     Put (HT & ".long " & Loc & "-" & Prefix & "debug_loc");
                     Location_List
                       (Loc, Expr, Debug_Locations.Available_Alias
                          (Of_Unit, Meanings, Info, Item, Index));
                  end if;
               end;
            end loop;
         end Alias_Variables;

         procedure Variables (Scope : Scope_Id);
         procedure Variables (Scope : Scope_Id) is
         begin
            for Index in 1 .. Slot_Count (Of_Unit, Item) loop
               declare
                  Slot : constant Slot_Id := Slot_Id (Index);
                  Binding : constant Declaration_Id :=
                    Declares (Of_Unit, Item, Slot);
                  Parameter : constant Boolean :=
                    (for some P in 1 .. Parameter_Count (Of_Unit, Item) =>
                       Nth_Parameter (Of_Unit, Item, P) = Slot);
                  Typ : Positive;
                  Shape : Field_Shape;
                  Expr : US.Unbounded_String;
                  Place : constant Allocation.Location := Plan.Slot (Index);
                  Loc : constant String := L ("loc", Item, Index);
               begin
                  if Binding /= No_Declaration
                    and then Landin.Resolution.Scope_Of (Meanings, Binding)
                      = Scope
                  then
                     if Is_Address (Of_Unit, Item, Slot) then
                        Shape := Address_Shape (Of_Unit, Item, Slot);
                     elsif Is_Array (Of_Unit, Item, Slot) then
                        Shape := Whole_Slot_Array_Shape (Of_Unit, Item, Slot);
                     elsif Is_Aggregate (Of_Unit, Item, Slot) then
                        Shape := (Kind => Aggregate_Field_Shape,
                                  Nominal => Nominal_Of (Of_Unit, Item, Slot),
                                  others => <>);
                     else
                        Shape := (Element => Type_Of (Of_Unit, Item, Slot),
                                  Pointee => Pointee_Of (Of_Unit, Item, Slot),
                                  others => <>);
                     end if;
                     Typ := (if Shape.Kind = Aggregate_Field_Shape
                               and then Shape.Nominal = No_Nominal_Type
                               and then not Is_Address (Of_Unit, Item, Slot)
                             then Intern ((Shape => Shape, Item => Item,
                                          Slot => Slot, others => <>))
                             else Shape_Type (Shape));
                     U (if Parameter then 3 else 10);
                     Str (Decl_Name (Binding));
                     Ref (T (Typ));
                     Coordinates (Origin_Of (Of_Unit, Item, Slot));
                     Put (HT & ".long " & Loc & "-" & Prefix & "debug_loc");
                     if Place.Kind = Allocation.GP then
                        Expr := US.To_Unbounded_String
                          (HT & ".byte " & N (16#50#
                            + Register_Number (Place.Register)) & LF);
                     elsif Has_Slot_Home (Frame_Plan, Slot) then
                        Expr := US.To_Unbounded_String
                          (HT & ".byte 0x91" & LF & HT & ".sleb128 -"
                           & Ada.Strings.Fixed.Trim
                             (Landin.Targets.Byte_Count'Image
                               (Slot_Offset (Frame_Plan, Slot)),
                              Ada.Strings.Both)
                           & LF);
                        if Is_Address (Of_Unit, Item, Slot) then
                           US.Append (Expr, HT & ".byte 0x06" & LF);
                        end if;
                     end if;
                     Location_List (Loc, Expr, Debug_Locations.Available
                       (Of_Unit, Meanings, Info, Item, Slot, Parameter));
                  end if;
               end;
            end loop;
         end Variables;

         procedure Lexical_Scope (Scope : Scope_Id; Root : Boolean := False);
         procedure Lexical_Scope (Scope : Scope_Id; Root : Boolean := False)
         is
            Name : constant String := L ("scope", Item, Natural (Scope));
         begin
            if not Root then
               U (11);
               Put (HT & ".long " & Name & "-" & Prefix & "debug_ranges");
               --  Entries below contain linked addresses, not offsets
               --  from a containing routine's low PC.  Select base zero
               --  explicitly; the CU intentionally has no single low PC.
               US.Append (Ranges, Name & ":" & LF
                 & HT & ".quad -1,0" & LF);
               for B in 1 .. Block_Count (Of_Unit, Item) loop
                  declare
                     Block : constant Block_Id := Block_Id (B);
                     Count : constant Natural := Length (Of_Unit, Item, Block);
                  begin
                     if Count > 0 and then Debug_Locations.Within
                       (Meanings, Scope_Of (Of_Unit, Item, Block), Scope)
                     then
                        US.Append (Ranges, HT & ".quad "
                          & L ("value", Item, Natural (Nth_Value
                            (Of_Unit, Item, Block, 1))) & LF
                          & HT & ".quad " & L ("after", Item,
                            Natural (Nth_Value (Of_Unit, Item, Block, Count)))
                          & LF);
                     end if;
                  end;
               end loop;
               US.Append (Ranges, HT & ".quad 0,0" & LF);
            end if;
            Variables (Scope);
            Alias_Variables (Scope);
            for Child of Scopes loop
               if Landin.Resolution.Enclosing (Meanings, Child) = Scope then
                  Lexical_Scope (Child);
               end if;
            end loop;
            if not Root then
               U (0);
            end if;
         end Lexical_Scope;
      begin
         U (2);
         Str (if Decl = No_Declaration then Symbol (Item)
              else Decl_Name (Decl));
         --  The source name is the debugger lookup name.  An assembler
         --  alias (notably a discarded .L generic-instance label) is not
         --  a source-language linkage name that GDB can demangle.
         Put (HT & ".quad " & L ("begin", Item));
         Put (HT & ".quad " & L ("end", Item));
         --  DW_OP_reg6: frame base is rbp, not the CFA above it.
         Put (HT & ".uleb128 1" & LF & HT & ".byte 0x56");
         Coordinates (Origin_Of (Of_Unit, Item));
         declare
            Root : Scope_Id := Scope_Of (Of_Unit, Item, First_Block);
         begin
            while Root /= Landin.Resolution.No_Scope
              and then Landin.Resolution.Sort_Of (Meanings, Root)
                /= Landin.Resolution.Signature
            loop
               Root := Landin.Resolution.Enclosing (Meanings, Root);
            end loop;
            for Index in 1 .. Slot_Count (Of_Unit, Item) loop
               declare
                  Binding : constant Declaration_Id :=
                    Declares (Of_Unit, Item, Slot_Id (Index));
               begin
                  if Binding /= No_Declaration then
                     declare
                        Scope : Scope_Id :=
                          Landin.Resolution.Scope_Of (Meanings, Binding);
                     begin
                        while Scope /= Root
                          and then Scope /= Landin.Resolution.No_Scope
                        loop
                           exit when Scopes.Contains (Scope);
                           Scopes.Append (Scope);
                           Scope := Landin.Resolution.Enclosing
                             (Meanings, Scope);
                        end loop;
                     end;
                  end if;
               end;
            end loop;
            for Index in 1 .. Source_Alias_Count (Of_Unit, Item) loop
               declare
                  Scope : Scope_Id := Landin.Resolution.Scope_Of
                    (Meanings, Nth_Source_Alias
                       (Of_Unit, Item, Index).Binding);
               begin
                  while Scope /= Root
                    and then Scope /= Landin.Resolution.No_Scope
                  loop
                     exit when Scopes.Contains (Scope);
                     Scopes.Append (Scope);
                     Scope := Landin.Resolution.Enclosing (Meanings, Scope);
                  end loop;
               end;
            end loop;
            Lexical_Scope (Root, Root => True);
         end;
         U (0);
      end Routine;

      procedure Abbreviation
        (Code, Tag : Natural; Children : Boolean; Attributes : String);
      procedure Abbreviation
        (Code, Tag : Natural; Children : Boolean; Attributes : String)
      is
      begin
         U (Code);
         U (Tag);
         Put (HT & ".byte " & (if Children then "1" else "0"));
         Put (HT & ".uleb128 " & Attributes & ",0,0");
      end Abbreviation;
   begin
      Put (HT & ".section .debug_abbrev,"""",@progbits");
      Put (Prefix & "debug_abbrev:");
      --  Attribute/form pairs from DWARF4. Strings are inline; all DIE
      --  references are CU-relative ref4, code addresses are target addr.
      Abbreviation (1, 16#11#, True,
        "0x25,0x08,0x13,0x05,0x03,0x08,0x1b,0x08,0x10,0x17");
      Abbreviation (2, 16#2e#, True,
        "0x03,0x08,0x11,0x01,0x12,0x01,0x40,0x18,"
        & "0x3a,0x0f,0x3b,0x0f,0x39,0x0f");
      Abbreviation (3, 16#05#, False,
        "0x03,0x08,0x49,0x13,0x3a,0x0f,0x3b,0x0f,0x39,0x0f,0x02,0x17");
      Abbreviation (4, 16#24#, False, "0x03,0x08,0x0b,0x0f,0x3e,0x0f");
      Abbreviation (5, 16#0f#, False, "0x0b,0x0f,0x49,0x13");
      Abbreviation (6, 16#13#, True, "0x03,0x08,0x0b,0x0f");
      Abbreviation (7, 16#0d#, False, "0x03,0x08,0x49,0x13,0x38,0x0f");
      Abbreviation (8, 16#01#, True, "0x49,0x13");
      Abbreviation (9, 16#21#, False, "0x37,0x0f");
      Abbreviation (10, 16#34#, False,
        "0x03,0x08,0x49,0x13,0x3a,0x0f,0x3b,0x0f,0x39,0x0f,0x02,0x17");
      Abbreviation (11, 16#0b#, True, "0x55,0x17");
      U (0);
      Put (HT & ".section .debug_info,"""",@progbits");
      Put (CU & ":");
      Put (HT & ".long " & CU & "_end-" & CU & "-4");
      Put (HT & ".short 4");
      Put (HT & ".long " & Prefix & "debug_abbrev");
      Put (HT & ".byte 8");
      U (1);
      Str ("Landin refine");
      --  C's expression/display rules are a debugger presentation, not a
      --  language claim.  Landin expressions are not evaluated by GDB.
      Put (HT & ".short 0x0002");
      Str (Landin.Source.Name (Landin.Debugging.Source (Info, 1)));
      Str (Landin.Debugging.Directory (Info));
      Put (HT & ".long " & Prefix & "debug_line");
      for Index in 1 .. Item_Count (Of_Unit) loop
         declare
            Item : constant Item_Id := Item_Id (Index);
         begin
            if Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Is_External (Of_Unit, Item)
            then
               Routine (Item);
            end if;
         end;
      end loop;
      declare
         Index : Positive := 1;
      begin
         while Index <= Natural (Types.Length) loop
            Emit_Type (Index);
            Index := Index + 1;
         end loop;
      end;
      U (0);
      Put (CU & "_end:");
      Put (HT & ".section .debug_loc,"""",@progbits");
      Put (Prefix & "debug_loc:");
      US.Append (Result, Locations);
      Put (HT & ".section .debug_ranges,"""",@progbits");
      Put (Prefix & "debug_ranges:");
      US.Append (Result, Ranges);
      return US.To_String (Result);
   end Sections;

end Landin.Backend.X86_64.Dwarf;
