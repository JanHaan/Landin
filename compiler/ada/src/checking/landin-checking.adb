package body Landin.Checking is

   use type Landin.Types.Reference_View;

   package body Nominal_Identities is
      function None return Id is (0);

      function From_Position (Position : Positive) return Id
        is (Id (Position));

      function Nth (Of_Table : Table; Position : Positive) return Id
        is (if Position <= Natural (Of_Table.Nominal_Templates.Length)
            then From_Position (Position) else None);

      function Holds (Of_Table : Table; Of_Id : Id) return Boolean
        is (Of_Table.Ready
            and then Of_Id /= None
            and then Natural (Of_Id)
                       <= Natural (Of_Table.Nominal_Templates.Length));

      function Position (Of_Table : Table; Of_Id : Id) return Positive is
         pragma Unreferenced (Of_Table);
      begin
         return Positive (Of_Id);
      end Position;
   end Nominal_Identities;

   package body Routine_Identities is
      function None return Id is (0);

      function From_Position (Position : Positive) return Id
        is (Id (Position));

      function Nth (Of_Table : Table; Position : Positive) return Id
        is (if Position <= Natural (Of_Table.Routine_Instances.Length)
            then From_Position (Position) else None);

      function Holds (Of_Table : Table; Of_Id : Id) return Boolean
        is (Of_Table.Ready
            and then Of_Id /= None
            and then Natural (Of_Id)
                       <= Natural (Of_Table.Routine_Instances.Length));

      function Position (Of_Table : Table; Of_Id : Id) return Positive is
         pragma Unreferenced (Of_Table);
      begin
         return Positive (Of_Id);
      end Position;
   end Routine_Identities;

   function Holds (Of_Table : Table; Id : Routine_Instance_Id)
     return Boolean
     is (Routine_Identities.Holds (Of_Table, Id));

   package body Concept_Identities is
      function None return Id is (0);

      function From_Position (Position : Positive) return Id
        is (Id (Position));

      function Nth (Of_Table : Table; Position : Positive) return Id
        is (if Position <= Natural (Of_Table.Concepts.Length)
            then From_Position (Position) else None);

      function Holds (Of_Table : Table; Of_Id : Id) return Boolean
        is (Of_Table.Ready
            and then Of_Id /= None
            and then Natural (Of_Id) <= Natural (Of_Table.Concepts.Length));

      function Position (Of_Table : Table; Of_Id : Id) return Positive is
         pragma Unreferenced (Of_Table);
      begin
         return Positive (Of_Id);
      end Position;
   end Concept_Identities;

   function Holds (Of_Table : Table; Id : Concept_Id) return Boolean
     is (Concept_Identities.Holds (Of_Table, Id));

   package body Conformance_Identities is
      function None return Id is (0);

      function From_Position (Position : Positive) return Id
        is (Id (Position));

      function Nth (Of_Table : Table; Position : Positive) return Id
        is (if Position <= Natural (Of_Table.Conformances.Length)
            then From_Position (Position) else None);

      function Holds (Of_Table : Table; Of_Id : Id) return Boolean
        is (Of_Table.Ready
            and then Of_Id /= None
            and then Natural (Of_Id)
                       <= Natural (Of_Table.Conformances.Length));

      function Position (Of_Table : Table; Of_Id : Id) return Positive is
         pragma Unreferenced (Of_Table);
      begin
         return Positive (Of_Id);
      end Position;
   end Conformance_Identities;

   function Holds (Of_Table : Table; Id : Conformance_Id) return Boolean
     is (Conformance_Identities.Holds (Of_Table, Id));

   function Current_Routine_View (Of_Table : Table)
     return Routine_Instance_Id
     is (Of_Table.Current_Routine);

   procedure Activate_Routine_View
     (Into     : in out Table;
      Instance : Routine_Instance_Id;
      Previous : out Routine_Instance_Id) is
   begin
      Previous := Into.Current_Routine;
      Into.Current_Routine := Instance;
   end Activate_Routine_View;

   procedure Restore_Routine_View
     (Into     : in out Table;
      Previous : Routine_Instance_Id) is
   begin
      Into.Current_Routine := Previous;
   end Restore_Routine_View;

   use type Landin.Source.Names.Name_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Syntax.Parameter_Convention;
   use type Landin.Targets.Byte_Count;
   use type Landin.Types.Magnitude;
   use type System.Address;

   ------------------------------------------------------------------
   --  Nominal instance keys
   ------------------------------------------------------------------

   function Empty_Actuals return Actual_Tuple
     is (Members => Actual_Key_Vectors.Empty_Vector);

   procedure Append_Actual
     (Into : in out Actual_Tuple; Actual : Actual_Key) is
   begin
      Into.Members.Append (Actual);
   end Append_Actual;

   function Actual_Count (Actuals : Actual_Tuple) return Natural
     is (Natural (Actuals.Members.Length));

   function Nth_Actual
     (Actuals : Actual_Tuple; Position : Positive) return Actual_Key
     is (Actuals.Members (Position));

   function Scalar_Type_Actual
     (Scalar : Landin.Types.Scalar_Name) return Actual_Key
     is (Kind => Type_Actual_Kind, Type_Form => Scalar_Actual_Type,
         Scalar => Scalar, others => <>);

   function Atom_Set_Type_Actual
     (Of_Table : Table; Atoms : Atom_Set_Id) return Actual_Key
     is (Kind => Type_Actual_Kind, Type_Form => Atom_Set_Actual_Type,
         Owner => Of_Table'Address, Atoms => Atoms, others => <>);

   function Fixed_Array_Type_Actual
     (Length  : Element_Count;
      Element : Landin.Types.Scalar_Name) return Actual_Key
     is (Kind => Type_Actual_Kind, Type_Form => Fixed_Array_Actual_Type,
         Length => Length, Scalar => Element, others => <>);

   function Fixed_Array_Type_Actual
     (Of_Table : Table;
      Length   : Element_Count;
      Element  : Nominal_Type_Id) return Actual_Key
     is (Kind => Type_Actual_Kind, Type_Form => Fixed_Array_Actual_Type,
         Owner => Of_Table'Address, Length => Length, Nominal => Element,
         others => <>);

   function Nominal_Type_Actual
     (Of_Table : Table; Nominal : Nominal_Type_Id) return Actual_Key
     is (Kind => Type_Actual_Kind, Type_Form => Nominal_Actual_Type,
         Owner => Of_Table'Address, Nominal => Nominal, others => <>);

   function Function_Type_Actual
     (Of_Table : Table; Signature : Signature_Id) return Actual_Key
     is (Kind => Type_Actual_Kind, Type_Form => Function_Actual_Type,
         Owner => Of_Table'Address, Signature => Signature, others => <>);

   function Reference_Type_Actual
     (Of_Table : Table; Reference : Reference_Id) return Actual_Key
     is (Kind => Type_Actual_Kind, Type_Form => Reference_Actual_Type,
         Owner => Of_Table'Address, Reference => Reference, others => <>);

   function Any_Type_Actual
     (Of_Table : Table; Concept : Concept_Id) return Actual_Key
     is (Kind => Type_Actual_Kind, Type_Form => Any_Actual_Type,
         Owner => Of_Table'Address, Concept => Concept, others => <>);

   function Fixed_Actual (Value : Landin.Types.Magnitude) return Actual_Key
     is (Kind => Fixed_Actual_Kind, Value => Value, others => <>);

   function Actual_Kind_Of (Key : Actual_Key) return Actual_Kind
     is (Key.Kind);

   function Type_Form_Of (Key : Actual_Key) return Actual_Type_Form
     is (Key.Type_Form);

   function Scalar_Of
     (Of_Table : Table; Key : Actual_Key) return Landin.Types.Scalar_Name is
   begin
      if not Holds (Of_Table, Key) then
         raise Landin.Compiler_Defect with
           "a scalar actual key belongs to another checking table";
      end if;
      return Key.Scalar;
   end Scalar_Of;

   function Atom_Set_Of
     (Of_Table : Table; Key : Actual_Key) return Atom_Set_Id is
   begin
      if not Holds (Of_Table, Key) then
         raise Landin.Compiler_Defect with
           "an atom-set actual key belongs to another checking table";
      end if;
      return Key.Atoms;
   end Atom_Set_Of;

   function Array_Length_Of
     (Of_Table : Table; Key : Actual_Key) return Element_Count is
   begin
      if not Holds (Of_Table, Key) then
         raise Landin.Compiler_Defect with
           "an array actual key belongs to another checking table";
      end if;
      return Key.Length;
   end Array_Length_Of;

   function Array_Element_Form_Of
     (Of_Table : Table; Key : Actual_Key) return Array_Element_Form is
   begin
      if not Holds (Of_Table, Key) then
         raise Landin.Compiler_Defect with
           "an array actual key belongs to another checking table";
      end if;
      return (if Key.Nominal = No_Nominal_Type
              then Scalar_Array_Element else Nominal_Array_Element);
   end Array_Element_Form_Of;

   function Array_Scalar_Element_Of
     (Of_Table : Table; Key : Actual_Key) return Landin.Types.Scalar_Name is
   begin
      if not Holds (Of_Table, Key) then
         raise Landin.Compiler_Defect with
           "an array actual key belongs to another checking table";
      end if;
      return Key.Scalar;
   end Array_Scalar_Element_Of;

   function Array_Nominal_Element_Of
     (Of_Table : Table; Key : Actual_Key) return Nominal_Type_Id is
   begin
      if not Holds (Of_Table, Key) then
         raise Landin.Compiler_Defect with
           "an array actual key belongs to another checking table";
      end if;
      return Key.Nominal;
   end Array_Nominal_Element_Of;

   function Nominal_Of
     (Of_Table : Table; Key : Actual_Key) return Nominal_Type_Id is
   begin
      if not Holds (Of_Table, Key) then
         raise Landin.Compiler_Defect with
           "a nominal actual key belongs to another checking table";
      end if;
      return Key.Nominal;
   end Nominal_Of;

   function Function_Signature_Of
     (Of_Table : Table; Key : Actual_Key) return Signature_Id is
   begin
      if not Holds (Of_Table, Key) then
         raise Landin.Compiler_Defect with
           "a function actual key belongs to another checking table";
      end if;
      return Key.Signature;
   end Function_Signature_Of;

   function Reference_Of
     (Of_Table : Table; Key : Actual_Key) return Reference_Id is
   begin
      if not Holds (Of_Table, Key) then
         raise Landin.Compiler_Defect with
           "a reference actual key belongs to another checking table";
      end if;
      return Key.Reference;
   end Reference_Of;

   function Any_Concept_Of
     (Of_Table : Table; Key : Actual_Key) return Concept_Id is
   begin
      if not Holds (Of_Table, Key) then
         raise Landin.Compiler_Defect with
           "an any actual key belongs to another checking table";
      end if;
      return Key.Concept;
   end Any_Concept_Of;

   function Fixed_Magnitude_Of
     (Key : Actual_Key) return Landin.Types.Magnitude
     is (Key.Value);

   function Holds (Of_Table : Table; Key : Actual_Key) return Boolean is
   begin
      if not Is_Prepared (Of_Table) then
         return False;
      elsif Key.Kind = Fixed_Actual_Kind then
         return True;
      end if;

      case Key.Type_Form is
         when Scalar_Actual_Type =>
            return True;
         when Atom_Set_Actual_Type =>
            return Key.Owner = Of_Table'Address
              and then Holds (Of_Table, Key.Atoms);
         when Fixed_Array_Actual_Type =>
            return Key.Nominal = No_Nominal_Type
              or else (Key.Owner = Of_Table'Address
                       and then Holds (Of_Table, Key.Nominal));
         when Nominal_Actual_Type =>
            return Key.Owner = Of_Table'Address
              and then Holds (Of_Table, Key.Nominal);
         when Function_Actual_Type =>
            return Key.Owner = Of_Table'Address
              and then Holds (Of_Table, Key.Signature)
              and then Signature_Error_Form (Of_Table, Key.Signature)
                           /= Inferred;
         when Reference_Actual_Type =>
            return Key.Owner = Of_Table'Address
              and then Holds (Of_Table, Key.Reference);
         when Any_Actual_Type =>
            return Key.Owner = Of_Table'Address
              and then Holds (Of_Table, Key.Concept);
      end case;
   end Holds;

   function Holds (Of_Table : Table; Actuals : Actual_Tuple) return Boolean is
   begin
      for Actual of Actuals.Members loop
         if not Holds (Of_Table, Actual) then
            return False;
         end if;
      end loop;
      return Is_Prepared (Of_Table);
   end Holds;

   function Actuals_Agree
     (Of_Table : Table; Left, Right : Actual_Key) return Boolean;

   function Run_Agrees
     (Of_Table : Table;
      Members  : Run;
      Actuals  : Actual_Tuple) return Boolean;

   function Actuals_Agree
     (Of_Table : Table; Left, Right : Actual_Key) return Boolean is
   begin
      if Left.Kind /= Right.Kind then
         return False;
      elsif Left.Kind = Fixed_Actual_Kind then
         return Left.Value = Right.Value;
      elsif Left.Type_Form /= Right.Type_Form then
         return False;
      end if;

      case Left.Type_Form is
         when Scalar_Actual_Type =>
            return Left.Scalar = Right.Scalar;
         when Atom_Set_Actual_Type =>
            return Atom_Sets_Agree (Of_Table, Left.Atoms, Right.Atoms);
         when Fixed_Array_Actual_Type =>
            if Left.Length /= Right.Length
              or else (Left.Nominal = No_Nominal_Type)
                        /= (Right.Nominal = No_Nominal_Type)
            then
               return False;
            elsif Left.Nominal = No_Nominal_Type then
               return Left.Scalar = Right.Scalar;
            else
               return Left.Nominal = Right.Nominal;
            end if;
         when Nominal_Actual_Type =>
            return Left.Nominal = Right.Nominal;
         when Function_Actual_Type =>
            return Signatures_Agree
              (Of_Table, Left.Signature, Right.Signature);
         when Reference_Actual_Type =>
            return References_Agree
              (Of_Table, Left.Reference, Right.Reference);
         when Any_Actual_Type =>
            return Left.Concept = Right.Concept;
      end case;
   end Actuals_Agree;

   function Run_Agrees
     (Of_Table : Table;
      Members  : Run;
      Actuals  : Actual_Tuple) return Boolean
   is
   begin
      if Members.Count /= Natural (Actuals.Members.Length) then
         return False;
      end if;
      for Index in 1 .. Members.Count loop
         if not Actuals_Agree
           (Of_Table,
            Of_Table.Conformance_Actuals (Members.First + Index),
            Actuals.Members (Index))
         then
            return False;
         end if;
      end loop;
      return True;
   end Run_Agrees;

   function Concept_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Concepts.Length));

   function Compiler_Zeroable_Concept (Of_Table : Table) return Concept_Id
     is (Concept_Identities.Nth (Of_Table, 1));

   function Intern_Concept
     (Into : in out Table; Declaration : Declaration_Id) return Concept_Id
   is
   begin
      for Position in 1 .. Natural (Into.Concepts.Length) loop
         if Into.Concepts (Position).Declaration = Declaration then
            return Concept_Identities.Nth (Into, Position);
         end if;
      end loop;
      Into.Concepts.Append
        (Concept_Record'
           (Declaration => Declaration, Compiler_Supplied => False));
      return Concept_Identities.Nth (Into, Into.Concepts.Last_Index);
   end Intern_Concept;

   function Concept_Declaration
     (Of_Table : Table; Id : Concept_Id) return Declaration_Id
     is (Of_Table.Concepts
           (Concept_Identities.Position (Of_Table, Id)).Declaration);

   function Is_Compiler_Concept
     (Of_Table : Table; Id : Concept_Id) return Boolean
     is (Of_Table.Concepts
           (Concept_Identities.Position (Of_Table, Id)).Compiler_Supplied);

   function Conformance_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Conformances.Length));

   function Find_Conformance
     (Of_Table : Table;
      Concept  : Concept_Id;
      Target   : Actual_Key;
      Inputs   : Actual_Tuple) return Conformance_Id
   is
   begin
      for Position in 1 .. Natural (Of_Table.Conformances.Length) loop
         declare
            Held : constant Conformance_Record :=
              Of_Table.Conformances (Position);
         begin
            if Held.Concept = Concept
              and then Actuals_Agree (Of_Table, Held.Target, Target)
              and then Run_Agrees (Of_Table, Held.Inputs, Inputs)
            then
               return Conformance_Identities.Nth (Of_Table, Position);
            end if;
         end;
      end loop;
      return No_Conformance;
   end Find_Conformance;

   function Add_Conformance
     (Into       : in out Table;
      Concept    : Concept_Id;
      Target     : Actual_Key;
      Inputs     : Actual_Tuple;
      Bindings   : Actual_Tuple;
      Source     : Landin.Source.Source_Id;
      Node       : Landin.Syntax.Node_Id;
      Origin     : Conformance_Origin) return Conformance_Id
   is
      Made : Conformance_Record :=
        (Concept  => Concept,
         Target   => Target,
         Inputs   => (First => Natural (Into.Conformance_Actuals.Length),
                      Count => 0),
         Bindings => <>,
         Providers => <>,
         Source   => Source,
         Node     => Node,
         Origin   => Origin);
   begin
      if not Holds (Into, Target)
        or else not Holds (Into, Inputs)
        or else not Holds (Into, Bindings)
      then
         raise Landin.Compiler_Defect with
           "conformance actuals belong to another checking table";
      end if;

      for Actual of Inputs.Members loop
         Into.Conformance_Actuals.Append (Actual);
         Made.Inputs.Count := Made.Inputs.Count + 1;
      end loop;
      Made.Bindings :=
        (First => Natural (Into.Conformance_Actuals.Length), Count => 0);
      for Actual of Bindings.Members loop
         Into.Conformance_Actuals.Append (Actual);
         Made.Bindings.Count := Made.Bindings.Count + 1;
      end loop;
      Into.Conformances.Append (Made);
      return Conformance_Identities.Nth
        (Into, Into.Conformances.Last_Index);
   end Add_Conformance;

   function Conformance_Concept
     (Of_Table : Table; Id : Conformance_Id) return Concept_Id
     is (Of_Table.Conformances
           (Conformance_Identities.Position (Of_Table, Id)).Concept);

   function Conformance_Target
     (Of_Table : Table; Id : Conformance_Id) return Actual_Key
     is (Of_Table.Conformances
           (Conformance_Identities.Position (Of_Table, Id)).Target);

   function Conformance_Input_Count
     (Of_Table : Table; Id : Conformance_Id) return Natural
     is (Of_Table.Conformances
           (Conformance_Identities.Position (Of_Table, Id)).Inputs.Count);

   function Nth_Conformance_Input
     (Of_Table : Table; Id : Conformance_Id; Position : Positive)
      return Actual_Key
   is
      Members : constant Run := Of_Table.Conformances
        (Conformance_Identities.Position (Of_Table, Id)).Inputs;
   begin
      return Of_Table.Conformance_Actuals (Members.First + Position);
   end Nth_Conformance_Input;

   function Conformance_Binding_Count
     (Of_Table : Table; Id : Conformance_Id) return Natural
     is (Of_Table.Conformances
           (Conformance_Identities.Position (Of_Table, Id)).Bindings.Count);

   function Nth_Conformance_Binding
     (Of_Table : Table; Id : Conformance_Id; Position : Positive)
      return Actual_Key
   is
      Members : constant Run := Of_Table.Conformances
        (Conformance_Identities.Position (Of_Table, Id)).Bindings;
   begin
      return Of_Table.Conformance_Actuals (Members.First + Position);
   end Nth_Conformance_Binding;

   function Conformance_Source
     (Of_Table : Table; Id : Conformance_Id)
      return Landin.Source.Source_Id
     is (Of_Table.Conformances
           (Conformance_Identities.Position (Of_Table, Id)).Source);

   function Conformance_Node
     (Of_Table : Table; Id : Conformance_Id)
      return Landin.Syntax.Node_Id
     is (Of_Table.Conformances
           (Conformance_Identities.Position (Of_Table, Id)).Node);

   function Conformance_Origin_Of
     (Of_Table : Table; Id : Conformance_Id) return Conformance_Origin
     is (Of_Table.Conformances
           (Conformance_Identities.Position (Of_Table, Id)).Origin);

   function Conformance_Entry_Count
     (Of_Table : Table; Id : Conformance_Id) return Natural
     is (Of_Table.Conformances
           (Conformance_Identities.Position (Of_Table, Id)).Providers.Count);

   procedure Set_Conformance_Entry_Count
     (Into : in out Table; Id : Conformance_Id; Count : Natural)
   is
      Position : constant Positive :=
        Conformance_Identities.Position (Into, Id);
      Held : Conformance_Record := Into.Conformances (Position);
   begin
      Held.Providers :=
        (First => Natural (Into.Conformance_Providers.Length), Count => Count);
      for Index in 1 .. Count loop
         Into.Conformance_Providers.Append
           (Conformance_Provider'(others => <>));
      end loop;
      Into.Conformances (Position) := Held;
   end Set_Conformance_Entry_Count;

   procedure Note_Conformance_Provider
     (Into        : in out Table;
      Id          : Conformance_Id;
      Position    : Positive;
      Declaration : Declaration_Id;
      Instance    : Routine_Instance_Id := No_Routine_Instance)
   is
      Members : constant Run := Into.Conformances
        (Conformance_Identities.Position (Into, Id)).Providers;
      Where : constant Positive := Members.First + Position;
   begin
      if Into.Conformance_Providers (Where).Declaration /= No_Declaration
      then
         raise Landin.Compiler_Defect with
           "one evidence entry was assigned two providers";
      end if;
      Into.Conformance_Providers (Where) :=
        (Declaration => Declaration, Instance => Instance);
   end Note_Conformance_Provider;

   function Conformance_Provider_Declaration
     (Of_Table : Table; Id : Conformance_Id; Position : Positive)
      return Declaration_Id
   is
      Members : constant Run := Of_Table.Conformances
        (Conformance_Identities.Position (Of_Table, Id)).Providers;
   begin
      return Of_Table.Conformance_Providers
        (Members.First + Position).Declaration;
   end Conformance_Provider_Declaration;

   function Conformance_Provider_Instance
     (Of_Table : Table; Id : Conformance_Id; Position : Positive)
      return Routine_Instance_Id
   is
      Members : constant Run := Of_Table.Conformances
        (Conformance_Identities.Position (Of_Table, Id)).Providers;
   begin
      return Of_Table.Conformance_Providers
        (Members.First + Position).Instance;
   end Conformance_Provider_Instance;

   function Intern
     (Into     : in out Table;
      Template : Declaration_Id;
      Actuals  : Actual_Tuple) return Nominal_Type_Id;

   function Intern
     (Into     : in out Table;
      Template : Declaration_Id;
      Actuals  : Actual_Tuple) return Nominal_Type_Id
   is
   begin
      for Position in 1 .. Natural (Into.Nominal_Templates.Length) loop
         if Into.Nominal_Templates (Position) = Template
           and then Into.Nominal_Actual_Runs (Position).Count
                      = Natural (Actuals.Members.Length)
         then
            declare
               Members : constant Run := Into.Nominal_Actual_Runs (Position);
               Same    : Boolean := True;
            begin
               for Index in 1 .. Members.Count loop
                  if not Actuals_Agree
                    (Into,
                     Into.Nominal_Actuals (Members.First + Index),
                     Actuals.Members (Index))
                  then
                     Same := False;
                     exit;
                  end if;
               end loop;
               if Same then
                  return Nominal_Identities.Nth (Into, Position);
               end if;
            end;
         end if;
      end loop;

      declare
         Members : Run :=
           (First => Natural (Into.Nominal_Actuals.Length), Count => 0);
      begin
         for Actual of Actuals.Members loop
            Into.Nominal_Actuals.Append (Actual);
            Members.Count := Members.Count + 1;
         end loop;
         Into.Nominal_Templates.Append (Template);
         Into.Nominal_Actual_Runs.Append (Members);
         Into.Layouts.Append (Aggregate_Layout'(others => <>));
      end;

      return Nominal_Identities.Nth
        (Into, Into.Nominal_Templates.Last_Index);
   end Intern;

   function Intern_Nominal_Instance
     (Into     : in out Table;
      Template : Declaration_Id;
      Actuals  : Actual_Tuple) return Nominal_Type_Id is
   begin
      --  Table is tagged limited and therefore passed by reference and cannot
      --  be copied.  Descriptor keys retain that stable object's Address as
      --  a compilation-local provenance token; this release-build guard is
      --  the backstop behind the public contract.
      if not Holds (Into, Actuals) then
         raise Landin.Compiler_Defect with
           "nominal actuals belong to another checking table";
      end if;
      return Intern (Into, Template, Actuals);
   end Intern_Nominal_Instance;

   function Instance_Actual_Count
     (Of_Table : Table; Id : Nominal_Type_Id) return Natural
     is (Of_Table.Nominal_Actual_Runs
           (Nominal_Identities.Position (Of_Table, Id)).Count);

   function Nth_Instance_Actual
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Position : Positive) return Actual_Key
   is
      Members : constant Run := Of_Table.Nominal_Actual_Runs
        (Nominal_Identities.Position (Of_Table, Id));
   begin
      return Of_Table.Nominal_Actuals (Members.First + Position);
   end Nth_Instance_Actual;

   function Intern_Routine_Instance
     (Into     : in out Table;
      Template : Declaration_Id;
      Actuals  : Actual_Tuple) return Routine_Instance_Id
   is
   begin
      if not Holds (Into, Actuals) then
         raise Landin.Compiler_Defect with
           "routine actuals belong to another checking table";
      end if;

      for Position in 1 .. Natural (Into.Routine_Instances.Length) loop
         declare
            Held : constant Routine_Instance_Record :=
              Into.Routine_Instances (Position);
            Same : Boolean := Held.Template = Template
              and then Held.Actuals.Count = Natural (Actuals.Members.Length);
         begin
            if Same then
               for Index in 1 .. Held.Actuals.Count loop
                  if not Actuals_Agree
                    (Into,
                     Into.Routine_Actuals (Held.Actuals.First + Index),
                     Actuals.Members (Index))
                  then
                     Same := False;
                     exit;
                  end if;
               end loop;
            end if;
            if Same then
               return Routine_Identities.Nth (Into, Position);
            end if;
         end;
      end loop;

      declare
         Made : Routine_Instance_Record :=
           (Template => Template,
            Actuals  => (First => Natural (Into.Routine_Actuals.Length),
                         Count => 0),
            Evidence => (First => Natural (Into.Routine_Evidence.Length),
                         Count => 0),
            others   => <>);
      begin
         for Actual of Actuals.Members loop
            Into.Routine_Actuals.Append (Actual);
            Made.Actuals.Count := Made.Actuals.Count + 1;
         end loop;
         Into.Routine_Instances.Append (Made);
      end;
      return Routine_Identities.Nth
        (Into, Into.Routine_Instances.Last_Index);
   end Intern_Routine_Instance;

   function Routine_Instance_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Routine_Instances.Length));

   function Routine_Template_Of
     (Of_Table : Table; Id : Routine_Instance_Id) return Declaration_Id
     is (Of_Table.Routine_Instances
           (Routine_Identities.Position (Of_Table, Id)).Template);

   function Routine_Actual_Count
     (Of_Table : Table; Id : Routine_Instance_Id) return Natural
     is (Of_Table.Routine_Instances
           (Routine_Identities.Position (Of_Table, Id)).Actuals.Count);

   function Nth_Routine_Actual
     (Of_Table : Table;
      Id       : Routine_Instance_Id;
      Position : Positive) return Actual_Key
   is
      Members : constant Run := Of_Table.Routine_Instances
        (Routine_Identities.Position (Of_Table, Id)).Actuals;
   begin
      return Of_Table.Routine_Actuals (Members.First + Position);
   end Nth_Routine_Actual;

   function Routine_Evidence_Count
     (Of_Table : Table; Id : Routine_Instance_Id) return Natural
     is (Of_Table.Routine_Instances
           (Routine_Identities.Position (Of_Table, Id)).Evidence.Count);

   procedure Add_Routine_Evidence
     (Into  : in out Table;
      Id    : Routine_Instance_Id;
      Formal : Positive;
      Evidence : Conformance_Id)
   is
      Position : constant Positive := Routine_Identities.Position (Into, Id);
      Held : Routine_Instance_Record := Into.Routine_Instances (Position);
   begin
      if Held.Evidence.Count = 0 then
         Held.Evidence.First := Natural (Into.Routine_Evidence.Length);
      elsif Held.Evidence.First + Held.Evidence.Count
              /= Natural (Into.Routine_Evidence.Length)
      then
         raise Landin.Compiler_Defect with
           "routine evidence entries were appended out of order";
      end if;
      Into.Routine_Evidence.Append
        (Routine_Evidence_Record'
           (Formal => Formal, Conformance => Evidence));
      Held.Evidence.Count := Held.Evidence.Count + 1;
      Into.Routine_Instances (Position) := Held;
   end Add_Routine_Evidence;

   function Nth_Routine_Evidence
     (Of_Table : Table;
      Id       : Routine_Instance_Id;
      Position : Positive) return Conformance_Id
   is
      Members : constant Run := Of_Table.Routine_Instances
        (Routine_Identities.Position (Of_Table, Id)).Evidence;
   begin
      return Of_Table.Routine_Evidence
        (Members.First + Position).Conformance;
   end Nth_Routine_Evidence;

   function Nth_Routine_Evidence_Formal
     (Of_Table : Table;
      Id       : Routine_Instance_Id;
      Position : Positive) return Positive
   is
      Members : constant Run := Of_Table.Routine_Instances
        (Routine_Identities.Position (Of_Table, Id)).Evidence;
   begin
      return Of_Table.Routine_Evidence (Members.First + Position).Formal;
   end Nth_Routine_Evidence_Formal;

   function Routine_State_Of
     (Of_Table : Table; Id : Routine_Instance_Id)
      return Routine_Instance_State
     is (Of_Table.Routine_Instances
           (Routine_Identities.Position (Of_Table, Id)).State);

   procedure Begin_Routine_Instance
     (Into : in out Table; Id : Routine_Instance_Id) is
   begin
      Into.Routine_Instances
        (Routine_Identities.Position (Into, Id)).State := Routine_Building;
   end Begin_Routine_Instance;

   procedure Publish_Routine_Signature
     (Into      : in out Table;
      Id        : Routine_Instance_Id;
      Signature : Signature_Id) is
   begin
      Into.Routine_Instances
        (Routine_Identities.Position (Into, Id)).Signature := Signature;
   end Publish_Routine_Signature;

   function Routine_Signature_Of
     (Of_Table : Table; Id : Routine_Instance_Id) return Signature_Id
     is (Of_Table.Routine_Instances
           (Routine_Identities.Position (Of_Table, Id)).Signature);

   procedure Finish_Routine_Instance
     (Into : in out Table; Id : Routine_Instance_Id) is
   begin
      Into.Routine_Instances
        (Routine_Identities.Position (Into, Id)).State := Routine_Ready;
   end Finish_Routine_Instance;

   procedure Invalidate_Routine_Instance
     (Into : in out Table; Id : Routine_Instance_Id) is
   begin
      Into.Routine_Instances
        (Routine_Identities.Position (Into, Id)).State := Routine_Invalid;
   end Invalidate_Routine_Instance;

   ------------------------------------------------------------------
   --  Building
   ------------------------------------------------------------------

   function Is_Prepared (Of_Table : Table) return Boolean
     is (Of_Table.Ready);

   function Source_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Runs.Length));

   function Node_Limit
     (Of_Table : Table; Id : Landin.Source.Source_Id) return Natural
     is (if Id /= Landin.Source.No_Source
           and then Natural (Id) <= Source_Count (Of_Table)
         then Of_Table.Runs (Positive (Id)).Count
         else 0);

   function Declaration_Limit (Of_Table : Table) return Natural
     is (Natural (Of_Table.Declarations.Length));

   function Covers (Of_Table : Table; Of_Tree : Landin.Syntax.Tree)
     return Boolean
     is (Node_Limit (Of_Table, Landin.Syntax.Source_Of (Of_Tree))
         = Landin.Syntax.Node_Count (Of_Tree));

   procedure Prepare
     (Into      : in out Table;
      Trees     : Landin.Syntax.Forest.Table;
      Meanings  : Landin.Resolution.Table;
      Spellings : in out Landin.Source.Names.Table) is
   begin
      for Index in 1 .. Landin.Syntax.Forest.Count (Trees) loop
         declare
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees, Landin.Source.Source_Id (Index));
            Held    : constant Natural :=
              Landin.Syntax.Node_Count (Of_Tree.all);
         begin
            Into.Runs.Append
              (Run'(First => Natural (Into.Node_Types.Length),
                    Count => Held));

            for Unused in 1 .. Held loop
               Into.Node_Types.Append (Landin.Types.Undecided);
               Into.Node_Nominals.Append (No_Nominal_Type);
               Into.Node_Atom_Sets.Append (No_Atom_Set);
               Into.Node_Signatures.Append (No_Signature);
               Into.Node_References.Append (No_Reference);
               Into.Node_Concepts.Append (No_Concept);
               Into.Node_Result_Shapes.Append (No_Signature);
               Into.Node_Routine_Targets.Append (No_Routine_Instance);
               Into.Node_Evidence.Append (No_Conformance);
               Into.Node_Evidence_Entries.Append (0);
               Into.Node_Fields.Append (0);
               Into.Node_Shapes.Append (Array_Shape'(others => <>));
            end loop;
         end;
      end loop;

      for Unused in 1 .. Landin.Resolution.Declaration_Count (Meanings) loop
         Into.Declarations.Append (Settlement'(others => <>));
         Into.Declaration_Nominals.Append (No_Nominal_Type);
         Into.Empty_Nominals.Append (No_Nominal_Type);
         Into.Shapes.Append (Array_Shape'(others => <>));
         Into.Declaration_Atom_Sets.Append (No_Atom_Set);
         Into.Declaration_Signatures.Append (No_Signature);
         Into.Declaration_References.Append (No_Reference);
         Into.Declaration_Concepts.Append (No_Concept);
         Into.Declaration_Result_Shapes.Append (No_Signature);
      end loop;

      --  Allocate every enabled empty-actual nominal instance in source
      --  declaration order before checking can follow a forward reference.
      --  Thus identity is target-independent and independent of traversal.
      for Id in Landin.Provenance.Declaration_Id'(1)
                .. Landin.Provenance.Declaration_Id
                     (Landin.Resolution.Declaration_Count (Meanings))
      loop
         declare
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees, Landin.Resolution.Source_Of (Meanings, Id));
            Node : constant Landin.Syntax.Node_Id :=
              Landin.Resolution.Node_Of (Meanings, Id);
            Written : constant Landin.Syntax.Node_Id :=
              (if Landin.Syntax.Kind (Of_Tree.all, Node)
                    = Landin.Syntax.Type_Declaration
               then Landin.Syntax.Declared_Type (Of_Tree.all, Node)
               else Landin.Syntax.No_Node);
         begin
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Type_Declaration
              and then Landin.Syntax.Type_Formal_Count (Of_Tree.all, Node) = 0
              and then Written /= Landin.Syntax.No_Node
              and then Landin.Syntax.Kind (Of_Tree.all, Written)
                           = Landin.Syntax.Struct_Body
            then
               declare
                  Made : constant Nominal_Type_Id :=
                    Intern (Into, Id, Empty_Actuals);
               begin
                  Into.Empty_Nominals (Positive (Id)) := Made;
                  Into.Declaration_Nominals (Positive (Id)) := Made;
               end;
            end if;
         end;
      end loop;

      --  R2.60's compiler concept is a closed identity, not a spelling a
      --  source declaration can impersonate.  It is always position one;
      --  every source concept follows in deterministic collection order.
      Into.Concepts.Append
        (Concept_Record'
           (Declaration => No_Declaration, Compiler_Supplied => True));

      --  Interned once, so a Type_Name node costs thirteen integer
      --  comparisons and never a byte comparison.
      for Item in Landin.Types.Scalar_Name loop
         Into.Scalars (Item) :=
           Landin.Source.Names.Intern
             (Spellings, Landin.Types.Spelling (Item));
      end loop;

      for Item in Landin.Types.Text_View loop
         Into.Texts (Item) :=
           Landin.Source.Names.Intern
             (Spellings, Landin.Types.Spelling (Item));
      end loop;

      Into.Ready := True;
      for View in Landin.Types.Text_View loop
         Into.Text_References (View) :=
           Add_Reference
             (Into,
              (Kind =>
                 (if View = Landin.Types.C_String_View
                  then Landin.Types.Pointer_Value
                  else Landin.Types.Slice_Value),
               View => View,
               Mutable => False,
               Referent =>
                 (if View = Landin.Types.Utf16_View
                  then Landin.Types.U16 else Landin.Types.U8),
               others => <>));
      end loop;
   end Prepare;

   ------------------------------------------------------------------
   --  The scalar names, by identity
   ------------------------------------------------------------------

   function Named (Of_Table : Table; Id : Landin.Source.Names.Name_Id)
     return Landin.Types.Type_Kind is
   begin
      for Item in Landin.Types.Scalar_Name loop
         if Of_Table.Scalars (Item) = Id then
            return Item;
         end if;
      end loop;

      return Landin.Types.Ill_Typed;
   end Named;

   function Is_Text_Name
     (Of_Table : Table; Id : Landin.Source.Names.Name_Id) return Boolean
   is
   begin
      for Item in Landin.Types.Text_View loop
         if Of_Table.Texts (Item) = Id then
            return True;
         end if;
      end loop;
      return False;
   end Is_Text_Name;

   function Named_Text_View
     (Of_Table : Table; Id : Landin.Source.Names.Name_Id)
      return Landin.Types.Text_View
   is
   begin
      for Item in Landin.Types.Text_View loop
         if Of_Table.Texts (Item) = Id then
            return Item;
         end if;
      end loop;
      raise Landin.Compiler_Defect with "a non-text name reached text lookup";
   end Named_Text_View;

   ------------------------------------------------------------------
   --  What a node has
   ------------------------------------------------------------------

   --  Where a node's entry sits: the run of its source, plus its index.
   function Slot
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Positive
     is (Of_Table.Runs
           (Positive (Landin.Syntax.Source_Of (Of_Tree))).First
         + Positive (Node));

   function Node_Overlay_Position
     (Of_Table : Table; Where : Positive) return Natural;

   function Ensure_Node_Overlay
     (Into : in out Table; Where : Positive) return Positive;

   function Declaration_Overlay_Position
     (Of_Table : Table; Id : Declaration_Id) return Natural;

   function Ensure_Declaration_Overlay
     (Into : in out Table; Id : Declaration_Id) return Positive;

   function Node_Overlay_Position
     (Of_Table : Table; Where : Positive) return Natural is
   begin
      if Of_Table.Current_Routine = No_Routine_Instance then
         return 0;
      end if;
      for Position in reverse 1 .. Natural (Of_Table.Node_Overlays.Length) loop
         if Of_Table.Node_Overlays (Position).Instance
              = Of_Table.Current_Routine
           and then Of_Table.Node_Overlays (Position).Where = Where
         then
            return Position;
         end if;
      end loop;
      return 0;
   end Node_Overlay_Position;

   function Ensure_Node_Overlay
     (Into : in out Table; Where : Positive) return Positive
   is
      Found : constant Natural := Node_Overlay_Position (Into, Where);
   begin
      if Found /= 0 then
         return Positive (Found);
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         raise Landin.Compiler_Defect with
           "a global fact was sent to the routine overlay";
      end if;
      Into.Node_Overlays.Append
        (Node_Overlay'(Instance => Into.Current_Routine,
                       Where => Where, others => <>));
      return Into.Node_Overlays.Last_Index;
   end Ensure_Node_Overlay;

   function Declaration_Overlay_Position
     (Of_Table : Table; Id : Declaration_Id) return Natural is
   begin
      if Of_Table.Current_Routine = No_Routine_Instance then
         return 0;
      end if;
      for Position in reverse
        1 .. Natural (Of_Table.Declaration_Overlays.Length)
      loop
         if Of_Table.Declaration_Overlays (Position).Instance
              = Of_Table.Current_Routine
           and then Of_Table.Declaration_Overlays (Position).Declared = Id
         then
            return Position;
         end if;
      end loop;
      return 0;
   end Declaration_Overlay_Position;

   function Ensure_Declaration_Overlay
     (Into : in out Table; Id : Declaration_Id) return Positive
   is
      Found : constant Natural := Declaration_Overlay_Position (Into, Id);
   begin
      if Found /= 0 then
         return Positive (Found);
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         raise Landin.Compiler_Defect with
           "a global declaration fact was sent to the routine overlay";
      end if;
      Into.Declaration_Overlays.Append
        (Declaration_Overlay'(Instance => Into.Current_Routine,
                              Declared => Id, others => <>));
      return Into.Declaration_Overlays.Last_Index;
   end Ensure_Declaration_Overlay;

   function Type_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Landin.Types.Type_Kind
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0 and then Of_Table.Node_Overlays (Overlay).Has_Type then
         return Of_Table.Node_Overlays (Overlay).Answer;
      end if;
      return Of_Table.Node_Types (Where);
   end Type_Of;

   function Nominal_Type_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Nominal_Templates.Length));

   function Nth_Nominal_Type
     (Of_Table : Table; Position : Positive) return Nominal_Type_Id
     is (Nominal_Identities.Nth (Of_Table, Position));

   function Holds (Of_Table : Table; Id : Nominal_Type_Id) return Boolean
     is (Nominal_Identities.Holds (Of_Table, Id));

   function Template_Of
     (Of_Table : Table; Id : Nominal_Type_Id) return Declaration_Id
     is (Of_Table.Nominal_Templates
           (Nominal_Identities.Position (Of_Table, Id)));

   function Empty_Nominal_Instance
     (Of_Table : Table; Template : Declaration_Id) return Nominal_Type_Id
     is (if Template = No_Declaration then No_Nominal_Type
         else Of_Table.Empty_Nominals (Positive (Template)));

   function Instance_State_Of
     (Of_Table : Table; Id : Nominal_Type_Id) return Instance_State
     is (Of_Table.Layouts
           (Nominal_Identities.Position (Of_Table, Id)).State);

   procedure Begin_Instance
     (Into : in out Table; Id : Nominal_Type_Id) is
   begin
      Into.Layouts
        (Nominal_Identities.Position (Into, Id)).State := Instance_Building;
   end Begin_Instance;

   procedure Invalidate_Instance
     (Into : in out Table; Id : Nominal_Type_Id) is
   begin
      Into.Layouts
        (Nominal_Identities.Position (Into, Id)).State := Instance_Invalid;
   end Invalidate_Instance;

   procedure Retry_Instance
     (Into : in out Table; Id : Nominal_Type_Id) is
   begin
      Into.Layouts
        (Nominal_Identities.Position (Into, Id)).State := Instance_Building;
   end Retry_Instance;

   function Nominal_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Nominal_Type_Id
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0 and then Of_Table.Node_Overlays (Overlay).Has_Nominal
      then
         return Of_Table.Node_Overlays (Overlay).Nominal;
      end if;
      return Of_Table.Node_Nominals (Where);
   end Nominal_Of;

   function Nominal_Of
     (Of_Table : Table; Id : Declaration_Id) return Nominal_Type_Id
   is
      Overlay : constant Natural :=
        (if Id = No_Declaration then 0
         else Declaration_Overlay_Position (Of_Table, Id));
   begin
      if Id = No_Declaration then
         return No_Nominal_Type;
      elsif Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Nominal
      then
         return Of_Table.Declaration_Overlays (Overlay).Nominal;
      end if;
      return Of_Table.Declaration_Nominals (Positive (Id));
   end Nominal_Of;

   procedure Note_Nominal
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Nominal : Nominal_Type_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Nominal_Of (Into, Of_Tree, Node) /= No_Nominal_Type
        and then Nominal_Of (Into, Of_Tree, Node) /= Nominal
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two nominal type identities";
      end if;

      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Nominals (Where) := Nominal;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Nominal := True;
            Into.Node_Overlays (Overlay).Nominal := Nominal;
         end;
      end if;
   end Note_Nominal;

   procedure Note_Nominal
     (Into   : in out Table;
      Id     : Declaration_Id;
      Nominal : Nominal_Type_Id) is
   begin
      if Nominal_Of (Into, Id) /= No_Nominal_Type
        and then Nominal_Of (Into, Id) /= Nominal
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two nominal type identities";
      end if;

      if Into.Current_Routine = No_Routine_Instance then
         Into.Declaration_Nominals (Positive (Id)) := Nominal;
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Nominal := True;
            Into.Declaration_Overlays (Overlay).Nominal := Nominal;
         end;
      end if;
   end Note_Nominal;

   procedure Reference_Union_Extent
     (Atom_Count : Positive;
      Facts      : Landin.Targets.Target_Facts;
      Size       : out Landin.Targets.Byte_Count;
      Alignment  : out Landin.Targets.Byte_Alignment)
   is
      Pointer_Size : constant Landin.Targets.Scalar_Size :=
        Landin.Targets.Pointer_Size (Facts);
   begin
      if Atom_Count = 1 then
         Size := Landin.Targets.Byte_Count
           (Landin.Targets.Bytes (Pointer_Size));
         Alignment := Landin.Targets.Pointer_Alignment (Facts);
         return;
      end if;

      declare
         Cases : constant Natural := Atom_Count + 1;
         Tag : constant Landin.Targets.Scalar_Size :=
           (if Cases <= 2 ** 8 then Landin.Targets.Byte_1
            elsif Cases <= 2 ** 16 then Landin.Targets.Byte_2
            else Landin.Targets.Byte_4);
         Placed : Landin.Targets.Placement :=
           Landin.Targets.Empty_Placement;
         Ignored : Landin.Targets.Byte_Count;
      begin
         Landin.Targets.Place (Placed, Tag, Facts, Ignored);
         Landin.Targets.Place (Placed, Pointer_Size, Facts, Ignored);
         Size := Landin.Targets.Size_Of (Placed);
         Alignment := Landin.Targets.Alignment_Of (Placed);
      end;
   end Reference_Union_Extent;

   ------------------------------------------------------------------
   --  Atom sets
   ------------------------------------------------------------------

   function Atom_Set_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Atom_Sets.Length));

   function Add_Atom_Set
     (Into : in out Table; Atoms : Atom_Array) return Atom_Set_Id
   is
      Made : Atom_Set_Record := (Members => (First => 0, Count => 0));
   begin
      Made.Members.First := Natural (Into.Atoms.Length);
      for Atom of Atoms loop
         Into.Atoms.Append (Atom);
         Made.Members.Count := Made.Members.Count + 1;
      end loop;
      Into.Atom_Sets.Append (Made);
      return Atom_Set_Id (Into.Atom_Sets.Last_Index);
   end Add_Atom_Set;

   function Atom_Count
     (Of_Table : Table; Set_Id : Atom_Set_Id) return Natural
     is (Of_Table.Atom_Sets (Positive (Set_Id)).Members.Count);

   function Nth_Atom
     (Of_Table : Table; Set_Id : Atom_Set_Id; Index : Positive)
      return Declaration_Id
   is
      Members : constant Run :=
        Of_Table.Atom_Sets (Positive (Set_Id)).Members;
   begin
      return Of_Table.Atoms (Members.First + Index);
   end Nth_Atom;

   function Contains_Atom
     (Of_Table : Table; Set_Id : Atom_Set_Id; Atom : Declaration_Id)
      return Boolean
   is
   begin
      for Index in 1 .. Atom_Count (Of_Table, Set_Id) loop
         if Nth_Atom (Of_Table, Set_Id, Index) = Atom then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Atom;

   function Is_Subset
     (Of_Table : Table; Left, Right : Atom_Set_Id) return Boolean
   is
   begin
      for Index in 1 .. Atom_Count (Of_Table, Left) loop
         if not Contains_Atom
           (Of_Table, Right, Nth_Atom (Of_Table, Left, Index))
         then
            return False;
         end if;
      end loop;
      return True;
   end Is_Subset;

   function Atom_Sets_Agree
     (Of_Table : Table; Left, Right : Atom_Set_Id) return Boolean
     is (Atom_Count (Of_Table, Left) = Atom_Count (Of_Table, Right)
         and then Is_Subset (Of_Table, Left, Right));

   function Atom_Set_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Atom_Set_Id
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0 and then Of_Table.Node_Overlays (Overlay).Has_Atoms then
         return Of_Table.Node_Overlays (Overlay).Atoms;
      end if;
      return Of_Table.Node_Atom_Sets (Where);
   end Atom_Set_Of;

   function Atom_Set_Of
     (Of_Table : Table; Id : Declaration_Id) return Atom_Set_Id
   is
      Overlay : constant Natural :=
        (if Id = No_Declaration then 0
         else Declaration_Overlay_Position (Of_Table, Id));
   begin
      if Id = No_Declaration then
         return No_Atom_Set;
      elsif Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Atoms
      then
         return Of_Table.Declaration_Overlays (Overlay).Atoms;
      end if;
      return Of_Table.Declaration_Atom_Sets (Positive (Id));
   end Atom_Set_Of;

   procedure Note_Atom_Set
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Set_Id  : Atom_Set_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Atom_Set_Of (Into, Of_Tree, Node) /= No_Atom_Set
        and then not Atom_Sets_Agree
          (Into, Atom_Set_Of (Into, Of_Tree, Node), Set_Id)
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two atom sets";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Atom_Sets (Where) := Set_Id;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Atoms := True;
            Into.Node_Overlays (Overlay).Atoms := Set_Id;
         end;
      end if;
   end Note_Atom_Set;

   procedure Note_Atom_Set
     (Into   : in out Table;
      Id     : Declaration_Id;
      Set_Id : Atom_Set_Id) is
   begin
      if Atom_Set_Of (Into, Id) /= No_Atom_Set
        and then not Atom_Sets_Agree
          (Into, Atom_Set_Of (Into, Id), Set_Id)
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two atom sets";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Declaration_Atom_Sets (Positive (Id)) := Set_Id;
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Atoms := True;
            Into.Declaration_Overlays (Overlay).Atoms := Set_Id;
         end;
      end if;
   end Note_Atom_Set;

   ------------------------------------------------------------------
   --  References
   ------------------------------------------------------------------

   function Reference_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.References.Length));

   function Add_Reference
     (Into : in out Table; Item : Reference_Descriptor) return Reference_Id
   is
      Made : Reference_Id;
   begin
      Into.References.Append (Item);
      Made := Reference_Id (Into.References.Last_Index);
      return Made;
   end Add_Reference;

   function Descriptor_Of
     (Of_Table : Table; Id : Reference_Id) return Reference_Descriptor
     is (Of_Table.References (Positive (Id)));

   function Text_Reference_Of
     (Of_Table : Table; View : Landin.Types.Text_View) return Reference_Id
     is (Of_Table.Text_References (View));

   function Referents_Agree
     (Of_Table : Table; Left, Right : Reference_Descriptor) return Boolean;

   function Referents_Agree
     (Of_Table : Table; Left, Right : Reference_Descriptor) return Boolean
   is
   begin
      if Left.Referent /= Right.Referent then
         return False;
      end if;

      case Left.Referent is
         when Landin.Types.Scalar_Name =>
            return True;
         when Landin.Types.Pointer_Value | Landin.Types.Slice_Value =>
            return Holds (Of_Table, Left.Reference)
              and then Holds (Of_Table, Right.Reference)
              and then References_Agree
                (Of_Table, Left.Reference, Right.Reference);
         when Landin.Types.Atom_Value =>
            return Holds (Of_Table, Left.Atoms)
              and then Holds (Of_Table, Right.Atoms)
              and then Atom_Sets_Agree (Of_Table, Left.Atoms, Right.Atoms);
         when Landin.Types.Fixed_Array =>
            return Left.Length = Right.Length
              and then Left.Element = Right.Element
              and then Left.Element_Nominal = Right.Element_Nominal;
         when Landin.Types.Aggregate =>
            return Left.Nominal = Right.Nominal;
         when Landin.Types.Any_Value =>
            return Holds (Of_Table, Left.Concept)
              and then Holds (Of_Table, Right.Concept)
              and then Left.Concept = Right.Concept;
         when Landin.Types.Function_Value =>
            return Holds (Of_Table, Left.Signature)
              and then Holds (Of_Table, Right.Signature)
              and then Signatures_Agree
                (Of_Table, Left.Signature, Right.Signature);
         when others =>
            return False;
      end case;
   end Referents_Agree;

   function References_Agree
     (Of_Table : Table; Left, Right : Reference_Id) return Boolean
   is
      A : constant Reference_Descriptor := Descriptor_Of (Of_Table, Left);
      B : constant Reference_Descriptor := Descriptor_Of (Of_Table, Right);
   begin
      return A.Kind = B.Kind
        and then A.View = B.View
        and then A.Mutable = B.Mutable
        and then Referents_Agree (Of_Table, A, B);
   end References_Agree;

   function Reference_Satisfies
     (Of_Table : Table; Actual, Expected : Reference_Id) return Boolean
   is
      A : constant Reference_Descriptor := Descriptor_Of (Of_Table, Actual);
      E : constant Reference_Descriptor := Descriptor_Of (Of_Table, Expected);
   begin
      return A.Kind = E.Kind
        and then A.View = E.View
        and then (A.Mutable = E.Mutable or else not E.Mutable)
        and then Referents_Agree (Of_Table, A, E);
   end Reference_Satisfies;

   function Reference_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Reference_Id
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0
        and then Of_Table.Node_Overlays (Overlay).Has_Reference
      then
         return Of_Table.Node_Overlays (Overlay).Reference;
      end if;
      return Of_Table.Node_References (Where);
   end Reference_Of;

   function Reference_Of
     (Of_Table : Table; Id : Declaration_Id) return Reference_Id
   is
      Overlay : constant Natural :=
        (if Id = No_Declaration then 0
         else Declaration_Overlay_Position (Of_Table, Id));
   begin
      if Id = No_Declaration then
         return No_Reference;
      elsif Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Reference
      then
         return Of_Table.Declaration_Overlays (Overlay).Reference;
      end if;
      return Of_Table.Declaration_References (Positive (Id));
   end Reference_Of;

   procedure Note_Reference
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Reference : Reference_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Reference_Of (Into, Of_Tree, Node) /= No_Reference
        and then not References_Agree
          (Into, Reference_Of (Into, Of_Tree, Node), Reference)
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two reference descriptors";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_References (Where) := Reference;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Reference := True;
            Into.Node_Overlays (Overlay).Reference := Reference;
         end;
      end if;
   end Note_Reference;

   procedure Note_Reference
     (Into     : in out Table;
      Id       : Declaration_Id;
      Reference : Reference_Id) is
   begin
      if Reference_Of (Into, Id) /= No_Reference
        and then not References_Agree
          (Into, Reference_Of (Into, Id), Reference)
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two reference descriptors";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Declaration_References (Positive (Id)) := Reference;
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Reference := True;
            Into.Declaration_Overlays (Overlay).Reference := Reference;
         end;
      end if;
   end Note_Reference;

   function Any_Concept_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Concept_Id
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0 and then Of_Table.Node_Overlays (Overlay).Has_Concept
      then
         return Of_Table.Node_Overlays (Overlay).Concept;
      end if;
      return Of_Table.Node_Concepts (Where);
   end Any_Concept_Of;

   function Any_Concept_Of
     (Of_Table : Table; Id : Declaration_Id) return Concept_Id
   is
      Overlay : constant Natural :=
        (if Id = No_Declaration then 0
         else Declaration_Overlay_Position (Of_Table, Id));
   begin
      if Id = No_Declaration then
         return No_Concept;
      elsif Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Concept
      then
         return Of_Table.Declaration_Overlays (Overlay).Concept;
      end if;
      return Of_Table.Declaration_Concepts (Positive (Id));
   end Any_Concept_Of;

   procedure Note_Any_Concept
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Concept : Concept_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Any_Concept_Of (Into, Of_Tree, Node) /= No_Concept
        and then Any_Concept_Of (Into, Of_Tree, Node) /= Concept
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two any concepts";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Concepts (Where) := Concept;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Concept := True;
            Into.Node_Overlays (Overlay).Concept := Concept;
         end;
      end if;
   end Note_Any_Concept;

   procedure Note_Any_Concept
     (Into : in out Table; Id : Declaration_Id; Concept : Concept_Id) is
   begin
      if Any_Concept_Of (Into, Id) /= No_Concept
        and then Any_Concept_Of (Into, Id) /= Concept
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two any concepts";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Declaration_Concepts (Positive (Id)) := Concept;
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Concept := True;
            Into.Declaration_Overlays (Overlay).Concept := Concept;
         end;
      end if;
   end Note_Any_Concept;

   ------------------------------------------------------------------
   --  Function signatures
   ------------------------------------------------------------------

   function Holds (Of_Table : Table; Part : Signature_Part) return Boolean is
      Descriptor_Free : constant Boolean :=
        Part.Nominal = No_Nominal_Type
        and then Part.Signature = No_Signature
        and then Part.Reference = No_Reference
        and then Part.Concept = No_Concept
        and then Part.Atoms = No_Atom_Set;
   begin
      if not Is_Prepared (Of_Table)
        or else not Landin.Provenance.Is_Known (Part.Site)
      then
         return False;
      end if;

      case Part.Kind is
         when Landin.Types.Scalar_Name =>
            return Descriptor_Free;
         when Landin.Types.Pointer_Value | Landin.Types.Slice_Value =>
            return Part.Nominal = No_Nominal_Type
              and then Part.Signature = No_Signature
              and then Part.Atoms = No_Atom_Set
              and then Holds (Of_Table, Part.Reference);
         when Landin.Types.Atom_Value =>
            return Part.Nominal = No_Nominal_Type
              and then Part.Signature = No_Signature
              and then Part.Reference = No_Reference
              and then Holds (Of_Table, Part.Atoms);
         when Landin.Types.Fixed_Array =>
            return Part.Signature = No_Signature
              and then Part.Reference = No_Reference
              and then Part.Atoms = No_Atom_Set
              and then
                (Part.Nominal = No_Nominal_Type
                 or else Holds (Of_Table, Part.Nominal));
         when Landin.Types.Aggregate =>
            return Holds (Of_Table, Part.Nominal)
              and then Part.Signature = No_Signature
              and then Part.Reference = No_Reference
              and then Part.Atoms = No_Atom_Set;
         when Landin.Types.Any_Value =>
            return Part.Nominal = No_Nominal_Type
              and then Part.Signature = No_Signature
              and then Part.Reference = No_Reference
              and then Holds (Of_Table, Part.Concept)
              and then Part.Atoms = No_Atom_Set;
         when Landin.Types.Function_Value =>
            return Part.Nominal = No_Nominal_Type
              and then Holds (Of_Table, Part.Signature)
              and then Part.Reference = No_Reference
              and then Part.Concept = No_Concept
              and then Part.Atoms = No_Atom_Set;
         when others =>
            return False;
      end case;
   end Holds;

   function Contains_References
     (Of_Table : Table; Nominal : Nominal_Type_Id) return Boolean
   is
      Seen : array
        (1 .. Positive'Max (1, Nominal_Type_Count (Of_Table))) of Boolean :=
          [others => False];

      function Visit (Id : Nominal_Type_Id) return Boolean;

      function Visit (Id : Nominal_Type_Id) return Boolean is
         Position : constant Positive :=
           Nominal_Identities.Position (Of_Table, Id);
      begin
         if Seen (Position) or else not Has_Layout (Of_Table, Id) then
            return False;
         end if;
         Seen (Position) := True;
         for Field in 1 .. Layout_Field_Count (Of_Table, Id) loop
            declare
               Shape : constant Field_Shape :=
                 Field_Shape_Of (Of_Table, Id, Field);
            begin
               case Shape.Kind is
                  when Reference_Field =>
                     return True;
                  when Aggregate_Field =>
                     if Visit (Shape.Nominal) then
                        return True;
                     end if;
                  when Fixed_Array_Field =>
                     if Shape.Nominal /= No_Nominal_Type
                       and then Visit (Shape.Nominal)
                     then
                        return True;
                     end if;
                  when Variant_Field =>
                     for Which in 1 .. Shape.Cases loop
                        for Part in 1 .. Variant_Case_Field_Count
                          (Of_Table, Id, Field, Which)
                        loop
                           declare
                              Payload : constant Field_Shape :=
                                Nth_Variant_Case_Field
                                  (Of_Table, Id, Field, Which, Part);
                           begin
                              if Payload.Kind = Reference_Field
                                or else
                                  (Payload.Kind = Aggregate_Field
                                   and then Visit (Payload.Nominal))
                                or else
                                  (Payload.Kind = Fixed_Array_Field
                                   and then Payload.Nominal
                                     /= No_Nominal_Type
                                   and then Visit (Payload.Nominal))
                              then
                                 return True;
                              end if;
                           end;
                        end loop;
                     end loop;
                  when Scalar_Field =>
                     null;
               end case;
            end;
         end loop;
         return False;
      end Visit;
   begin
      return Visit (Nominal);
   end Contains_References;

   function Contains_References
     (Of_Table : Table; Part : Signature_Part) return Boolean
   is
   begin
      case Part.Kind is
         when Landin.Types.Pointer_Value | Landin.Types.Slice_Value
            | Landin.Types.Any_Value =>
            return True;
         when Landin.Types.Aggregate =>
            return Contains_References (Of_Table, Part.Nominal);
         when Landin.Types.Fixed_Array =>
            return Part.Length > 0
              and then Part.Nominal /= No_Nominal_Type
              and then Contains_References (Of_Table, Part.Nominal);
         when others =>
            return False;
      end case;
   end Contains_References;

   function Holds
     (Of_Table : Table; Parts : Signature_Part_Array) return Boolean is
   begin
      for Part of Parts loop
         if not Holds (Of_Table, Part) then
            return False;
         end if;
      end loop;
      return Is_Prepared (Of_Table);
   end Holds;

   function Signature_Count (Of_Table : Table) return Natural
     is (Natural (Of_Table.Signatures.Length));

   function Add_Signature
     (Into       : in out Table;
      Parameters : Signature_Part_Array;
      Results    : Signature_Part_Array;
      Site       : Landin.Provenance.Origin;
      Errors     : Atom_Set_Id := No_Atom_Set;
      Error_Form : Error_Set_Form := Infallible;
      Sources    : Return_Source_Array := No_Return_Sources)
      return Signature_Id
   is
      Made : Signature_Record :=
        (Parameters => (First => 0, Count => 0),
         Results    => (First => 0, Count => 0),
         Sources    => (First => 0, Count => 0),
         Site       => Site,
         Errors     => Errors,
         Error_Form => Error_Form);

      procedure Append
        (Parts : Signature_Part_Array; To_Run : in out Run);

      procedure Append
        (Parts : Signature_Part_Array; To_Run : in out Run) is
      begin
         if Parts'Length > 0 then
            To_Run.First := Natural (Into.Signature_Parts.Length);
            for Part of Parts loop
               Into.Signature_Parts.Append (Part);
               To_Run.Count := To_Run.Count + 1;
            end loop;
         end if;
      end Append;
   begin
      if not Holds (Into, Parameters) or else not Holds (Into, Results) then
         raise Landin.Compiler_Defect with "a signature part is malformed";
      end if;
      Append (Parameters, Made.Parameters);
      Append (Results, Made.Results);
      if Sources'Length > 0 then
         Made.Sources.First := Natural (Into.Return_Sources.Length);
         for Source of Sources loop
            Into.Return_Sources.Append (Source);
            Made.Sources.Count := Made.Sources.Count + 1;
         end loop;
      end if;
      Into.Signatures.Append (Made);
      return Signature_Id (Into.Signatures.Last_Index);
   end Add_Signature;

   function Add_Signature
     (Into       : in out Table;
      Parameters : Signature_Part_Array;
      Result     : Signature_Part;
      Site       : Landin.Provenance.Origin;
      Errors     : Atom_Set_Id := No_Atom_Set;
      Error_Form : Error_Set_Form := Infallible;
      Sources    : Return_Source_Array := No_Return_Sources)
      return Signature_Id
   is
   begin
      if Result.Kind = Landin.Types.No_Value then
         return Add_Signature
           (Into, Parameters, No_Signature_Parts, Site,
            Errors, Error_Form, Sources);
      end if;
      return Add_Signature
        (Into, Parameters, Signature_Part_Array'[1 => Result], Site,
         Errors, Error_Form, Sources);
   end Add_Signature;

   function Signature_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Signature_Id
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0
        and then Of_Table.Node_Overlays (Overlay).Has_Signature
      then
         return Of_Table.Node_Overlays (Overlay).Signature;
      end if;
      return Of_Table.Node_Signatures (Where);
   end Signature_Of;

   function Signature_Of
     (Of_Table : Table; Id : Declaration_Id) return Signature_Id
   is
      Overlay : constant Natural :=
        (if Id = No_Declaration then 0
         else Declaration_Overlay_Position (Of_Table, Id));
   begin
      if Id = No_Declaration then
         return No_Signature;
      elsif Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Signature
      then
         return Of_Table.Declaration_Overlays (Overlay).Signature;
      end if;
      return Of_Table.Declaration_Signatures (Positive (Id));
   end Signature_Of;

   procedure Note_Signature
     (Into      : in out Table;
      Of_Tree   : Landin.Syntax.Tree;
      Node      : Landin.Syntax.Node_Id;
      Signature : Signature_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Signature_Of (Into, Of_Tree, Node) /= No_Signature
        and then Signature_Of (Into, Of_Tree, Node) /= Signature
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two function signatures";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Signatures (Where) := Signature;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Signature := True;
            Into.Node_Overlays (Overlay).Signature := Signature;
         end;
      end if;
   end Note_Signature;

   procedure Note_Signature
     (Into      : in out Table;
      Id        : Declaration_Id;
      Signature : Signature_Id) is
   begin
      if Signature_Of (Into, Id) /= No_Signature
        and then Signature_Of (Into, Id) /= Signature
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two function signatures";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Declaration_Signatures (Positive (Id)) := Signature;
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Signature := True;
            Into.Declaration_Overlays (Overlay).Signature := Signature;
         end;
      end if;
   end Note_Signature;

   function Signature_Parameter_Count
     (Of_Table : Table; Signature : Signature_Id) return Natural
     is (Of_Table.Signatures (Positive (Signature)).Parameters.Count);

   function Nth_Signature_Parameter
     (Of_Table : Table; Signature : Signature_Id; Index : Positive)
      return Signature_Part
   is
      Parameters : constant Run :=
        Of_Table.Signatures (Positive (Signature)).Parameters;
   begin
      return Of_Table.Signature_Parts (Parameters.First + Index);
   end Nth_Signature_Parameter;

   function Signature_Result_Count
     (Of_Table : Table; Signature : Signature_Id) return Natural
     is (Of_Table.Signatures (Positive (Signature)).Results.Count);

   function Nth_Signature_Result
     (Of_Table : Table; Signature : Signature_Id; Index : Positive)
      return Signature_Part
   is
      Results : constant Run :=
        Of_Table.Signatures (Positive (Signature)).Results;
   begin
      return Of_Table.Signature_Parts (Results.First + Index);
   end Nth_Signature_Result;

   function Signature_Return_Source_Count
     (Of_Table : Table; Signature : Signature_Id; Result : Positive)
      return Natural
   is
      Sources : constant Run :=
        Of_Table.Signatures (Positive (Signature)).Sources;
      Count : Natural := 0;
   begin
      for Index in 1 .. Sources.Count loop
         if Of_Table.Return_Sources (Sources.First + Index).Result = Result
         then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Signature_Return_Source_Count;

   function Nth_Signature_Return_Source
     (Of_Table : Table;
      Signature : Signature_Id;
      Result    : Positive;
      Index     : Positive) return Positive
   is
      Sources : constant Run :=
        Of_Table.Signatures (Positive (Signature)).Sources;
      Seen : Natural := 0;
   begin
      for Position in 1 .. Sources.Count loop
         declare
            Source : constant Return_Source_Association :=
              Of_Table.Return_Sources (Sources.First + Position);
         begin
            if Source.Result = Result then
               Seen := Seen + 1;
               if Seen = Index then
                  return Source.Parameter;
               end if;
            end if;
         end;
      end loop;
      raise Landin.Compiler_Defect with
        "a return source index escaped its checked bound";
   end Nth_Signature_Return_Source;

   function Signature_Result
     (Of_Table : Table; Signature : Signature_Id) return Signature_Part
   is
   begin
      if Signature_Result_Count (Of_Table, Signature) = 0 then
         return
           (Kind => Landin.Types.No_Value,
            Site => Signature_Origin (Of_Table, Signature),
            others => <>);
      end if;
      return Nth_Signature_Result (Of_Table, Signature, 1);
   end Signature_Result;

   function Signature_Origin
     (Of_Table : Table; Signature : Signature_Id)
      return Landin.Provenance.Origin
     is (Of_Table.Signatures (Positive (Signature)).Site);

   function Signature_Error_Form
     (Of_Table : Table; Signature : Signature_Id) return Error_Set_Form
     is (Of_Table.Signatures (Positive (Signature)).Error_Form);

   function Signature_Errors
     (Of_Table : Table; Signature : Signature_Id) return Atom_Set_Id
     is (Of_Table.Signatures (Positive (Signature)).Errors);

   procedure Finalize_Inferred_Errors
     (Into      : in out Table;
      Signature : Signature_Id;
      Errors    : Atom_Set_Id)
   is
      Held : Signature_Record := Into.Signatures (Positive (Signature));
   begin
      Held.Errors := Errors;
      Held.Error_Form := (if Errors = No_Atom_Set then Infallible
                          else Concrete);
      Into.Signatures (Positive (Signature)) := Held;
   end Finalize_Inferred_Errors;

   function Parts_Agree
     (Of_Table : Table; A, B : Signature_Part) return Boolean;

   function Parts_Agree
     (Of_Table : Table; A, B : Signature_Part) return Boolean
   is
   begin
      if A.Kind /= B.Kind
        or else A.Convention /= B.Convention
        or else A.Escaping /= B.Escaping
        or else A.Caller /= B.Caller
      then
         return False;
      end if;
      case A.Kind is
         when Landin.Types.No_Value =>
            return True;
         when Landin.Types.Scalar_Name =>
            return True;
         when Landin.Types.Pointer_Value | Landin.Types.Slice_Value =>
            return Holds (Of_Table, A.Reference)
              and then Holds (Of_Table, B.Reference)
              and then References_Agree
                (Of_Table, A.Reference, B.Reference);
         when Landin.Types.Atom_Value =>
            return Holds (Of_Table, A.Atoms)
              and then Holds (Of_Table, B.Atoms)
              and then Atom_Sets_Agree (Of_Table, A.Atoms, B.Atoms);
         when Landin.Types.Aggregate =>
            return A.Nominal = B.Nominal;
         when Landin.Types.Fixed_Array =>
            return A.Length = B.Length
              and then A.Element = B.Element
              and then A.Nominal = B.Nominal;
         when Landin.Types.Any_Value =>
            return A.Concept = B.Concept;
         when Landin.Types.Function_Value =>
            return Holds (Of_Table, A.Signature)
              and then Holds (Of_Table, B.Signature)
              and then Signatures_Agree
                (Of_Table, A.Signature, B.Signature);
         when others =>
            return False;
      end case;
   end Parts_Agree;

   function Signatures_Agree
     (Of_Table : Table; Left, Right : Signature_Id) return Boolean
   is
   begin
      if Left = Right then
         return True;
      end if;

      if Signature_Error_Form (Of_Table, Left) = Inferred
        or else Signature_Error_Form (Of_Table, Right) = Inferred
        or else Signature_Error_Form (Of_Table, Left)
                  /= Signature_Error_Form (Of_Table, Right)
        or else
          (Signature_Error_Form (Of_Table, Left) = Concrete
           and then not Atom_Sets_Agree
             (Of_Table, Signature_Errors (Of_Table, Left),
              Signature_Errors (Of_Table, Right)))
        or else Signature_Parameter_Count (Of_Table, Left)
           /= Signature_Parameter_Count (Of_Table, Right)
        or else Signature_Result_Count (Of_Table, Left)
           /= Signature_Result_Count (Of_Table, Right)
      then
         return False;
      end if;

      for Index in 1 .. Signature_Parameter_Count (Of_Table, Left) loop
         if not Parts_Agree
           (Of_Table,
            Nth_Signature_Parameter (Of_Table, Left, Index),
            Nth_Signature_Parameter (Of_Table, Right, Index))
         then
            return False;
         end if;
      end loop;

      for Index in 1 .. Signature_Result_Count (Of_Table, Left) loop
         if not Parts_Agree
           (Of_Table,
            Nth_Signature_Result (Of_Table, Left, Index),
            Nth_Signature_Result (Of_Table, Right, Index))
           or else Signature_Return_Source_Count (Of_Table, Left, Index)
             /= Signature_Return_Source_Count (Of_Table, Right, Index)
         then
            return False;
         end if;
         for Source in
           1 .. Signature_Return_Source_Count (Of_Table, Left, Index)
         loop
            if Nth_Signature_Return_Source
                 (Of_Table, Left, Index, Source)
              /= Nth_Signature_Return_Source
                   (Of_Table, Right, Index, Source)
            then
               return False;
            end if;
         end loop;
      end loop;
      return True;
   end Signatures_Agree;

   function Result_Shape_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Signature_Id
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0
        and then Of_Table.Node_Overlays (Overlay).Has_Result_Shape
      then
         return Of_Table.Node_Overlays (Overlay).Result_Shape;
      end if;
      return Of_Table.Node_Result_Shapes (Where);
   end Result_Shape_Of;

   function Result_Shape_Of
     (Of_Table : Table; Id : Declaration_Id) return Signature_Id
   is
      Overlay : constant Natural :=
        (if Id = No_Declaration then 0
         else Declaration_Overlay_Position (Of_Table, Id));
   begin
      if Id = No_Declaration then
         return No_Signature;
      elsif Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Result_Shape
      then
         return Of_Table.Declaration_Overlays (Overlay).Result_Shape;
      end if;
      return Of_Table.Declaration_Result_Shapes (Positive (Id));
   end Result_Shape_Of;

   procedure Note_Result_Shape
     (Into      : in out Table;
      Of_Tree   : Landin.Syntax.Tree;
      Node      : Landin.Syntax.Node_Id;
      Signature : Signature_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Result_Shape_Of (Into, Of_Tree, Node) /= No_Signature
        and then Result_Shape_Of (Into, Of_Tree, Node) /= Signature
      then
         raise Landin.Compiler_Defect with
           "one node was assigned two anonymous result shapes";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Result_Shapes (Where) := Signature;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Result_Shape := True;
            Into.Node_Overlays (Overlay).Result_Shape := Signature;
         end;
      end if;
   end Note_Result_Shape;

   procedure Note_Result_Shape
     (Into      : in out Table;
      Id        : Declaration_Id;
      Signature : Signature_Id) is
   begin
      if Result_Shape_Of (Into, Id) /= No_Signature
        and then Result_Shape_Of (Into, Id) /= Signature
      then
         raise Landin.Compiler_Defect with
           "one declaration was assigned two anonymous result shapes";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Declaration_Result_Shapes (Positive (Id)) := Signature;
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Result_Shape := True;
            Into.Declaration_Overlays (Overlay).Result_Shape := Signature;
         end;
      end if;
   end Note_Result_Shape;

   function Routine_Target_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Call     : Landin.Syntax.Node_Id) return Routine_Instance_Id
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Call);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0
        and then Of_Table.Node_Overlays (Overlay).Has_Routine_Target
      then
         return Of_Table.Node_Overlays (Overlay).Routine_Target;
      end if;
      return Of_Table.Node_Routine_Targets (Where);
   end Routine_Target_Of;

   procedure Note_Routine_Target
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Call    : Landin.Syntax.Node_Id;
      Target  : Routine_Instance_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Call);
      Existing : constant Routine_Instance_Id :=
        Routine_Target_Of (Into, Of_Tree, Call);
   begin
      if Existing /= No_Routine_Instance and then Existing /= Target then
         raise Landin.Compiler_Defect with
           "one call selected two routine instances in one fact view";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Routine_Targets (Where) := Target;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Routine_Target := True;
            Into.Node_Overlays (Overlay).Routine_Target := Target;
         end;
      end if;
   end Note_Routine_Target;

   function Evidence_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Conformance_Id
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0 and then Of_Table.Node_Overlays (Overlay).Has_Evidence
      then
         return Of_Table.Node_Overlays (Overlay).Evidence;
      end if;
      return Of_Table.Node_Evidence (Where);
   end Evidence_Of;

   function Evidence_Entry_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Natural
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0 and then Of_Table.Node_Overlays (Overlay).Has_Evidence
      then
         return Of_Table.Node_Overlays (Overlay).Evidence_Entry;
      end if;
      return Of_Table.Node_Evidence_Entries (Where);
   end Evidence_Entry_Of;

   function Traversal_Evidence_Of
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Conformance_Id
     is (Evidence_Of (Of_Table, Of_Tree, Node));

   procedure Note_Traversal_Evidence
     (Into       : in out Table;
      Of_Tree    : Landin.Syntax.Tree;
      Node       : Landin.Syntax.Node_Id;
      Conformance : Conformance_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Traversal_Evidence_Of (Into, Of_Tree, Node) /= No_Conformance then
         raise Landin.Compiler_Defect with
           "one traversal was assigned two iterable conformances";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Evidence (Where) := Conformance;
         Into.Node_Evidence_Entries (Where) := 0;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Evidence := True;
            Into.Node_Overlays (Overlay).Evidence := Conformance;
            Into.Node_Overlays (Overlay).Evidence_Entry := 0;
         end;
      end if;
   end Note_Traversal_Evidence;

   procedure Note_Any_Construction
     (Into       : in out Table;
      Of_Tree    : Landin.Syntax.Tree;
      Node       : Landin.Syntax.Node_Id;
      Conformance : Conformance_Id)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Evidence_Of (Into, Of_Tree, Node) /= No_Conformance then
         raise Landin.Compiler_Defect with
           "one any construction was assigned two conformances";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Evidence (Where) := Conformance;
         Into.Node_Evidence_Entries (Where) := 0;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Evidence := True;
            Into.Node_Overlays (Overlay).Evidence := Conformance;
            Into.Node_Overlays (Overlay).Evidence_Entry := 0;
         end;
      end if;
   end Note_Any_Construction;

   procedure Note_Any_Dispatch
     (Into      : in out Table;
      Of_Tree   : Landin.Syntax.Tree;
      Node      : Landin.Syntax.Node_Id;
      Evidence  : Conformance_Id;
      Which     : Positive)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Evidence_Of (Into, Of_Tree, Node) /= No_Conformance then
         raise Landin.Compiler_Defect with
           "one any selection was assigned two evidence entries";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Evidence (Where) := Evidence;
         Into.Node_Evidence_Entries (Where) := Which;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Evidence := True;
            Into.Node_Overlays (Overlay).Evidence := Evidence;
            Into.Node_Overlays (Overlay).Evidence_Entry := Which;
         end;
      end if;
   end Note_Any_Dispatch;

   procedure Note_Evidence_Selection
     (Into      : in out Table;
      Of_Tree   : Landin.Syntax.Tree;
      Node      : Landin.Syntax.Node_Id;
      Evidence  : Conformance_Id;
      Which     : Positive)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Evidence_Of (Into, Of_Tree, Node) /= No_Conformance then
         raise Landin.Compiler_Defect with
           "one selection was assigned two evidence entries";
      end if;
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Evidence (Where) := Evidence;
         Into.Node_Evidence_Entries (Where) := Which;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Evidence := True;
            Into.Node_Overlays (Overlay).Evidence := Evidence;
            Into.Node_Overlays (Overlay).Evidence_Entry := Which;
         end;
      end if;
   end Note_Evidence_Selection;

   function Result_Shapes_Agree
     (Of_Table : Table; Left, Right : Signature_Id) return Boolean
   is
   begin
      if Signature_Result_Count (Of_Table, Left)
           /= Signature_Result_Count (Of_Table, Right)
      then
         return False;
      end if;
      for Index in 1 .. Signature_Result_Count (Of_Table, Left) loop
         declare
            A : constant Signature_Part :=
              Nth_Signature_Result (Of_Table, Left, Index);
            B : constant Signature_Part :=
              Nth_Signature_Result (Of_Table, Right, Index);
         begin
            if A.Name /= B.Name or else not Parts_Agree (Of_Table, A, B) then
               return False;
            end if;
         end;
      end loop;
      return True;
   end Result_Shapes_Agree;

   ------------------------------------------------------------------
   --  How an aggregate is laid out
   ------------------------------------------------------------------

   function Has_Layout (Of_Table : Table; Id : Nominal_Type_Id)
     return Boolean
     is (Holds (Of_Table, Id)
         and then Of_Table.Layouts
           (Nominal_Identities.Position (Of_Table, Id)).State
                     = Instance_Ready);

   function Layout_Field_Count (Of_Table : Table; Id : Nominal_Type_Id)
     return Natural
     is (Of_Table.Layouts
           (Nominal_Identities.Position (Of_Table, Id)).Count);

   procedure Lay_Out
     (Into  : in out Table;
      Id    : Nominal_Type_Id;
      Fields : Field_Shape_Array;
      Facts : Landin.Targets.Target_Facts;
      Fits  : out Boolean;
      Cases : Case_Run_Array := No_Case_Runs;
      Payloads : Field_Shape_Array := No_Field_Shapes)
   is
      Built : Aggregate_Layout :=
        (State => Instance_Building, others => <>);
      Layout_Possible : Boolean := True;

      procedure Reject;

      procedure Reject is
      begin
         if Instance_State_Of (Into, Id) = Instance_Unseen then
            Begin_Instance (Into, Id);
         end if;
         Invalidate_Instance (Into, Id);
         Fits := False;
      end Reject;

      procedure Extent_Of
        (Field     : Field_Shape;
         Size      : out Landin.Targets.Byte_Count;
         Alignment : out Landin.Targets.Byte_Alignment);

      procedure Extent_Of
        (Field     : Field_Shape;
         Size      : out Landin.Targets.Byte_Count;
         Alignment : out Landin.Targets.Byte_Alignment)
      is
         Held : constant Landin.Targets.Scalar_Size :=
           Landin.Types.Storage_Size (Field.Element, Facts);
      begin
         if Field.Kind = Scalar_Field then
            Size := Landin.Targets.Byte_Count (Landin.Targets.Bytes (Held));
            Alignment := Landin.Targets.Alignment_Of (Facts, Held);
         elsif Field.Kind = Reference_Field then
            declare
               Descriptor : constant Reference_Descriptor :=
                 Descriptor_Of (Into, Field.Reference);
               Pointer_Bytes : constant Landin.Targets.Byte_Count :=
                 Landin.Targets.Byte_Count
                   (Landin.Targets.Bytes
                      (Landin.Targets.Pointer_Size (Facts)));
            begin
               if Descriptor.Kind = Landin.Types.Any_Value then
                  Size := Landin.Targets.Any_Value_Size (Facts);
                  Alignment := Landin.Targets.Any_Value_Alignment (Facts);
               else
                  Size :=
                    (if Descriptor.Kind = Landin.Types.Slice_Value
                     then 2 * Pointer_Bytes else Pointer_Bytes);
                  Alignment := Landin.Targets.Pointer_Alignment (Facts);
               end if;
            end;
         elsif Field.Kind = Fixed_Array_Field then
            if Field.Nominal /= No_Nominal_Type then
               if not Holds (Into, Field.Nominal)
                 or else not Has_Layout (Into, Field.Nominal)
               then
                  raise Landin.Compiler_Defect with
                    "an aggregate array element has no laid-out body";
               end if;
               Array_Extent
                 (Into, Field.Length, Field.Nominal, Size, Alignment);
            else
               Array_Extent
                 (Field.Length, Field.Element, Facts, Size, Alignment);
            end if;
         elsif Field.Kind = Aggregate_Field then
            if Field.Nominal = No_Nominal_Type
              or else not Holds (Into, Field.Nominal)
              or else not Has_Layout (Into, Field.Nominal)
            then
               raise Landin.Compiler_Defect with
                 "an aggregate field has no laid-out body";
            end if;
            Size := Layout_Size (Into, Field.Nominal);
            Alignment := Layout_Alignment (Into, Field.Nominal);
         else
            if Field.Cases = 0
              or else Field.Payloads_First = 0
              or else Field.Payloads_First > Cases'Length
              or else Field.Cases
                        > Cases'Length - Field.Payloads_First + 1
            then
               raise Landin.Compiler_Defect with
                 "a variant field has a malformed case run";
            end if;

            declare
               Payload_Size : Landin.Targets.Byte_Count := 0;
               Payload_Alignment : Landin.Targets.Byte_Alignment := 1;
               Tag_Size : constant Landin.Targets.Scalar_Size := Held;
               Tag_Bytes : constant Landin.Targets.Byte_Count :=
                 Landin.Targets.Byte_Count
                   (Landin.Targets.Bytes (Tag_Size));
               Part : Landin.Targets.Placement :=
                 Landin.Targets.Empty_Placement;
               Ignored : Landin.Targets.Byte_Count;
            begin
               for Which in 1 .. Field.Cases loop
                  declare
                     Run : constant Case_Run :=
                       Cases (Field.Payloads_First + Which - 1);
                     Placed : Landin.Targets.Placement :=
                       Landin.Targets.Empty_Placement;
                  begin
                     if Run.Count > 0
                       and then (Run.First = 0
                                 or else Run.First > Payloads'Length
                                 or else Run.Count
                                           > Payloads'Length - Run.First + 1)
                     then
                        raise Landin.Compiler_Defect with
                          "a variant payload has a malformed field run";
                     end if;

                     for Position in 1 .. Run.Count loop
                        declare
                           Part_Size : Landin.Targets.Byte_Count;
                           Part_Alignment : Landin.Targets.Byte_Alignment;
                        begin
                           if Payloads (Run.First + Position - 1).Kind
                                = Variant_Field
                           then
                              raise Landin.Compiler_Defect with
                                "a nested variant payload reached layout";
                           end if;
                           Extent_Of
                             (Payloads (Run.First + Position - 1),
                              Part_Size, Part_Alignment);
                           if not Landin.Targets.Can_Place
                             (Placed, Part_Size, Part_Alignment,
                              Landin.Targets.Maximum_Object_Size (Facts))
                           then
                              Layout_Possible := False;
                              Size := 0;
                              Alignment := 1;
                              return;
                           end if;
                           Landin.Targets.Place
                             (Placed, Part_Size, Part_Alignment, Ignored);
                        end;
                     end loop;

                     Payload_Size := Landin.Targets.Byte_Count'Max
                       (Payload_Size, Landin.Targets.Size_Of (Placed));
                     Payload_Alignment :=
                       Landin.Targets.Byte_Alignment'Max
                         (Payload_Alignment,
                          Landin.Targets.Alignment_Of (Placed));
                  end;
               end loop;

               Landin.Targets.Place (Part, Tag_Size, Facts, Ignored);
               if not Landin.Targets.Can_Place
                 (Part, Payload_Size, Payload_Alignment,
                  Landin.Targets.Maximum_Object_Size (Facts))
               then
                  Layout_Possible := False;
                  Size := 0;
                  Alignment := 1;
                  return;
               end if;
               Landin.Targets.Place
                 (Part, Payload_Size, Payload_Alignment, Ignored);
               Size := Landin.Targets.Size_Of (Part);
               Alignment := Landin.Targets.Alignment_Of (Part);

               pragma Assert (Size >= Tag_Bytes);
            end;
         end if;
      end Extent_Of;
   begin
      if Instance_State_Of (Into, Id) = Instance_Unseen then
         Begin_Instance (Into, Id);
      end if;

      --  First prove the complete padded value fits this target.  D18 proves
      --  each array leaf fits alone; the containing struct still may not.
      for Field in Fields'Range loop
         declare
            Size      : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
            Ignored   : Landin.Targets.Byte_Count;
         begin
            Extent_Of (Fields (Field), Size, Alignment);
            if not Layout_Possible then
               Reject;
               return;
            end if;
            if not Landin.Targets.Can_Place
                     (Built.Placed, Size, Alignment,
                      Landin.Targets.Maximum_Object_Size (Facts))
            then
               Reject;
               return;
            end if;
            Landin.Targets.Place
              (Built.Placed, Size, Alignment, Ignored);
         end;
      end loop;

      --  Payload shapes and their case runs precede the containing
      --  struct's top-level field run.  Rebase the source-local indexes
      --  while retaining the same target-neutral shape.
      declare
         Payload_Base : constant Natural :=
           Natural (Into.Field_Shapes.Length);
         Case_Base : constant Natural := Natural (Into.Case_Runs.Length);
      begin
         for Payload of Payloads loop
            Into.Field_Shapes.Append (Payload);
         end loop;

         for Run of Cases loop
            Into.Case_Runs.Append
              (Case_Run'(First =>
                  (if Run.Count = 0 then 0 else Payload_Base + Run.First),
                Count => Run.Count));
         end loop;

         Built.First := Natural (Into.Field_Offsets.Length) + 1;
         Built.Shape_First := Natural (Into.Field_Shapes.Length) + 1;
         Built.Count := Fields'Length;
         Built.Placed := Landin.Targets.Empty_Placement;

         for Field in Fields'Range loop
            declare
               Size      : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
               At_Offset : Landin.Targets.Byte_Count;
               Stored    : Field_Shape := Fields (Field);
            begin
               Extent_Of (Fields (Field), Size, Alignment);
               if not Layout_Possible then
                  Reject;
                  return;
               end if;
               Landin.Targets.Place
                 (Built.Placed, Size, Alignment, At_Offset);
               Into.Field_Offsets.Append (At_Offset);
               if Stored.Kind = Variant_Field then
                  Stored.Payloads_First :=
                    Case_Base + Stored.Payloads_First;
               end if;
               Into.Field_Shapes.Append (Stored);
            end;
         end loop;
      end;

      Built.State := Instance_Ready;
      Into.Layouts (Nominal_Identities.Position (Into, Id)) := Built;
      Fits := True;
   end Lay_Out;

   function Has_Variant_Part (Of_Table : Table; Id : Nominal_Type_Id)
     return Boolean
   is
   begin
      for Field in 1 .. Layout_Field_Count (Of_Table, Id) loop
         if Field_Kind_Of (Of_Table, Id, Field) = Variant_Field then
            return True;
         end if;
      end loop;
      return False;
   end Has_Variant_Part;

   function Has_Aggregate_Field (Of_Table : Table; Id : Nominal_Type_Id)
     return Boolean
   is
   begin
      for Field in 1 .. Layout_Field_Count (Of_Table, Id) loop
         if Field_Kind_Of (Of_Table, Id, Field) = Aggregate_Field then
            return True;
         end if;
      end loop;
      return False;
   end Has_Aggregate_Field;

   function Field_Shape_Of
     (Of_Table : Table; Id : Nominal_Type_Id; Field : Positive)
      return Field_Shape
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Of_Table, Id));
   begin
      return Of_Table.Field_Shapes (Layout.Shape_First + Field - 1);
   end Field_Shape_Of;

   function Variant_Case_Field_Count
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive;
      Which    : Positive) return Natural
   is
      Shape : constant Field_Shape := Field_Shape_Of
        (Of_Table, Id, Field);
   begin
      return Of_Table.Case_Runs
        (Shape.Payloads_First + Which - 1).Count;
   end Variant_Case_Field_Count;

   function Nth_Variant_Case_Field
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive;
      Which    : Positive;
      Payload_Field : Positive) return Field_Shape
   is
      Shape : constant Field_Shape := Field_Shape_Of
        (Of_Table, Id, Field);
      Run : constant Case_Run := Of_Table.Case_Runs
        (Shape.Payloads_First + Which - 1);
   begin
      return Of_Table.Field_Shapes (Run.First + Payload_Field - 1);
   end Nth_Variant_Case_Field;

   function Field_Offset
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Landin.Targets.Byte_Count
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Of_Table, Id));
   begin
      return Of_Table.Field_Offsets (Layout.First + Field - 1);
   end Field_Offset;

   function Field_Type
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Of_Table, Id));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Element;
   end Field_Type;

   function Field_Kind_Of
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Field_Kind
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Of_Table, Id));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Kind;
   end Field_Kind_Of;

   function Field_Array_Length
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Element_Count
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Of_Table, Id));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Length;
   end Field_Array_Length;

   function Field_Array_Element
     (Of_Table : Table;
      Id       : Nominal_Type_Id;
      Field    : Positive) return Landin.Types.Scalar_Name
   is
      Layout : Aggregate_Layout renames
        Of_Table.Layouts (Nominal_Identities.Position (Of_Table, Id));
   begin
      return Of_Table.Field_Shapes
        (Layout.Shape_First + Field - 1).Element;
   end Field_Array_Element;

   function Layout_Extent (Of_Table : Table; Id : Nominal_Type_Id)
     return Landin.Targets.Byte_Count
     is (Landin.Targets.Extent_Of
           (Of_Table.Layouts
              (Nominal_Identities.Position (Of_Table, Id)).Placed));

   function Layout_Alignment (Of_Table : Table; Id : Nominal_Type_Id)
     return Landin.Targets.Byte_Alignment
     is (Landin.Targets.Alignment_Of
           (Of_Table.Layouts
              (Nominal_Identities.Position (Of_Table, Id)).Placed));

   function Layout_Size (Of_Table : Table; Id : Nominal_Type_Id)
     return Landin.Targets.Byte_Count
     is (Landin.Targets.Size_Of
           (Of_Table.Layouts
              (Nominal_Identities.Position (Of_Table, Id)).Placed));

   function Field_Index
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Natural
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0 and then Of_Table.Node_Overlays (Overlay).Has_Field then
         return Of_Table.Node_Overlays (Overlay).Field;
      end if;
      return Of_Table.Node_Fields (Where);
   end Field_Index;

   procedure Note_Field
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Which   : Positive)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Fields (Where) := Which;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Field := True;
            Into.Node_Overlays (Overlay).Field := Which;
         end;
      end if;
   end Note_Field;

   function Array_Length
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Element_Count
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0 and then Of_Table.Node_Overlays (Overlay).Has_Array then
         return Of_Table.Node_Overlays (Overlay).Shape.Length;
      end if;
      return Of_Table.Node_Shapes (Where).Length;
   end Array_Length;

   function Array_Element
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Landin.Types.Scalar_Name
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0 and then Of_Table.Node_Overlays (Overlay).Has_Array then
         return Of_Table.Node_Overlays (Overlay).Shape.Element;
      end if;
      return Of_Table.Node_Shapes (Where).Element;
   end Array_Element;

   procedure Note_Array
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Length  : Element_Count;
      Element : Landin.Types.Scalar_Name) is
   begin
      declare
         Where : constant Positive := Slot (Into, Of_Tree, Node);
      begin
         if Into.Current_Routine = No_Routine_Instance then
            Into.Node_Shapes (Where) :=
              Array_Shape'(Length => Length, Element => Element, others => <>);
         else
            declare
               Overlay : constant Positive :=
                 Ensure_Node_Overlay (Into, Where);
            begin
               Into.Node_Overlays (Overlay).Has_Array := True;
               Into.Node_Overlays (Overlay).Shape :=
                 Array_Shape'(Length => Length, Element => Element,
                              others => <>);
            end;
         end if;
      end;
   end Note_Array;

   function Array_Element_Nominal
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Nominal_Type_Id
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
   begin
      if Overlay /= 0
        and then Of_Table.Node_Overlays (Overlay).Has_Array_Nominal
      then
         return Of_Table.Node_Overlays (Overlay).Array_Nominal;
      end if;
      return Of_Table.Node_Shapes (Where).Element_Nominal;
   end Array_Element_Nominal;

   procedure Note_Array_Element_Nominal
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Nominal : Nominal_Type_Id) is
   begin
      declare
         Where : constant Positive := Slot (Into, Of_Tree, Node);
      begin
         if Into.Current_Routine = No_Routine_Instance then
            Into.Node_Shapes (Where).Element_Nominal := Nominal;
         else
            declare
               Overlay : constant Positive :=
                 Ensure_Node_Overlay (Into, Where);
            begin
               Into.Node_Overlays (Overlay).Has_Array_Nominal := True;
               Into.Node_Overlays (Overlay).Array_Nominal := Nominal;
            end;
         end if;
      end;
   end Note_Array_Element_Nominal;

   function Array_Element_Shape
     (Of_Table : Table;
      Of_Tree  : Landin.Syntax.Tree;
      Node     : Landin.Syntax.Node_Id) return Field_Shape
   is
      Where : constant Positive := Slot (Of_Table, Of_Tree, Node);
      Overlay : constant Natural := Node_Overlay_Position (Of_Table, Where);
      Shape : constant Array_Shape :=
        (if Overlay /= 0 and then Of_Table.Node_Overlays (Overlay).Has_Array
         then Of_Table.Node_Overlays (Overlay).Shape
         else Of_Table.Node_Shapes (Where));
      Nominal : constant Nominal_Type_Id :=
        Array_Element_Nominal (Of_Table, Of_Tree, Node);
   begin
      if Shape.Has_Complex_Element then
         return Shape.Complex_Element;
      elsif Nominal /= No_Nominal_Type then
         return (Kind => Aggregate_Field, Nominal => Nominal, others => <>);
      end if;
      return (Kind => Scalar_Field, Element => Shape.Element, others => <>);
   end Array_Element_Shape;

   procedure Note_Array_Element_Shape
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Shape   : Field_Shape)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Shapes (Where).Has_Complex_Element := True;
         Into.Node_Shapes (Where).Complex_Element := Shape;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Array := True;
            Into.Node_Overlays (Overlay).Shape.Has_Complex_Element := True;
            Into.Node_Overlays (Overlay).Shape.Complex_Element := Shape;
         end;
      end if;
   end Note_Array_Element_Shape;

   function Array_Length
     (Of_Table : Table; Id : Declaration_Id) return Element_Count
   is
      Overlay : constant Natural :=
        Declaration_Overlay_Position (Of_Table, Id);
   begin
      if Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Array
      then
         return Of_Table.Declaration_Overlays (Overlay).Shape.Length;
      end if;
      return Of_Table.Shapes (Natural (Id)).Length;
   end Array_Length;

   function Array_Element
     (Of_Table : Table; Id : Declaration_Id)
     return Landin.Types.Scalar_Name
   is
      Overlay : constant Natural :=
        Declaration_Overlay_Position (Of_Table, Id);
   begin
      if Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Array
      then
         return Of_Table.Declaration_Overlays (Overlay).Shape.Element;
      end if;
      return Of_Table.Shapes (Natural (Id)).Element;
   end Array_Element;

   procedure Note_Array
     (Into    : in out Table;
      Id      : Declaration_Id;
      Length  : Element_Count;
      Element : Landin.Types.Scalar_Name) is
   begin
      if Into.Current_Routine = No_Routine_Instance then
         Into.Shapes (Natural (Id)) :=
           Array_Shape'(Length => Length, Element => Element, others => <>);
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Array := True;
            Into.Declaration_Overlays (Overlay).Shape :=
              Array_Shape'(Length => Length, Element => Element,
                           others => <>);
         end;
      end if;
   end Note_Array;

   function Array_Element_Nominal
     (Of_Table : Table; Id : Declaration_Id) return Nominal_Type_Id
   is
      Overlay : constant Natural :=
        Declaration_Overlay_Position (Of_Table, Id);
   begin
      if Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Array_Nominal
      then
         return Of_Table.Declaration_Overlays (Overlay).Array_Nominal;
      end if;
      return Of_Table.Shapes (Natural (Id)).Element_Nominal;
   end Array_Element_Nominal;

   procedure Note_Array_Element_Nominal
     (Into  : in out Table;
      Id      : Declaration_Id;
      Nominal : Nominal_Type_Id) is
   begin
      if Into.Current_Routine = No_Routine_Instance then
         Into.Shapes (Natural (Id)).Element_Nominal := Nominal;
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Array_Nominal := True;
            Into.Declaration_Overlays (Overlay).Array_Nominal := Nominal;
         end;
      end if;
   end Note_Array_Element_Nominal;

   function Array_Element_Shape
     (Of_Table : Table; Id : Declaration_Id) return Field_Shape
   is
      Overlay : constant Natural :=
        Declaration_Overlay_Position (Of_Table, Id);
      Shape : constant Array_Shape :=
        (if Overlay /= 0
              and then Of_Table.Declaration_Overlays (Overlay).Has_Array
         then Of_Table.Declaration_Overlays (Overlay).Shape
         else Of_Table.Shapes (Natural (Id)));
      Nominal : constant Nominal_Type_Id :=
        Array_Element_Nominal (Of_Table, Id);
   begin
      if Shape.Has_Complex_Element then
         return Shape.Complex_Element;
      elsif Nominal /= No_Nominal_Type then
         return (Kind => Aggregate_Field, Nominal => Nominal, others => <>);
      end if;
      return (Kind => Scalar_Field, Element => Shape.Element, others => <>);
   end Array_Element_Shape;

   procedure Note_Array_Element_Shape
     (Into  : in out Table;
      Id    : Declaration_Id;
      Shape : Field_Shape)
   is
   begin
      if Into.Current_Routine = No_Routine_Instance then
         Into.Shapes (Natural (Id)).Has_Complex_Element := True;
         Into.Shapes (Natural (Id)).Complex_Element := Shape;
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Array := True;
            Into.Declaration_Overlays (Overlay).Shape.Has_Complex_Element :=
              True;
            Into.Declaration_Overlays (Overlay).Shape.Complex_Element := Shape;
         end;
      end if;
   end Note_Array_Element_Shape;

   procedure Array_Extent
     (Length    : Element_Count;
      Element   : Landin.Types.Scalar_Name;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
      Held : constant Landin.Targets.Scalar_Size :=
        Landin.Types.Storage_Size (Element, Facts);
   begin
      Alignment :=
        (if Length = 0 then 1
         else Landin.Targets.Alignment_Of (Facts, Held));
      Size :=
        Landin.Targets.Byte_Count (Length)
        * Landin.Targets.Byte_Count (Landin.Targets.Bytes (Held));
   end Array_Extent;

   procedure Array_Extent
     (Of_Table  : Table;
      Length    : Element_Count;
      Element   : Nominal_Type_Id;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
      Held : constant Landin.Targets.Byte_Count :=
        Layout_Size (Of_Table, Element);
   begin
      Alignment :=
        (if Length = 0 then 1
         else Layout_Alignment (Of_Table, Element));
      Size := Landin.Targets.Byte_Count (Length) * Held;
   end Array_Extent;

   procedure Set_Node_Type
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Item    : Landin.Types.Type_Kind);

   procedure Set_Node_Type
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Item    : Landin.Types.Type_Kind)
   is
      Where : constant Positive := Slot (Into, Of_Tree, Node);
   begin
      if Into.Current_Routine = No_Routine_Instance then
         Into.Node_Types (Where) := Item;
      else
         declare
            Overlay : constant Positive := Ensure_Node_Overlay (Into, Where);
         begin
            Into.Node_Overlays (Overlay).Has_Type := True;
            Into.Node_Overlays (Overlay).Answer := Item;
         end;
      end if;
   end Set_Node_Type;

   procedure Note
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      Item    : Landin.Types.Type_Kind) is
   begin
      Set_Node_Type (Into, Of_Tree, Node, Item);
   end Note;

   procedure Commit
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id;
      To      : Landin.Types.Scalar_Name) is
   begin
      Set_Node_Type (Into, Of_Tree, Node, To);
   end Commit;

   procedure Refuse
     (Into    : in out Table;
      Of_Tree : Landin.Syntax.Tree;
      Node    : Landin.Syntax.Node_Id) is
   begin
      Set_Node_Type (Into, Of_Tree, Node, Landin.Types.Ill_Typed);
   end Refuse;

   ------------------------------------------------------------------
   --  What a declaration has
   ------------------------------------------------------------------

   function State_Of (Of_Table : Table; Id : Declaration_Id)
     return Progress
   is
      Overlay : constant Natural :=
        Declaration_Overlay_Position (Of_Table, Id);
   begin
      if Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Settlement
      then
         return Of_Table.Declaration_Overlays (Overlay).Settlement_Fact.State;
      end if;
      return Of_Table.Declarations (Positive (Id)).State;
   end State_Of;

   function Type_Of (Of_Table : Table; Id : Declaration_Id)
     return Landin.Types.Type_Kind
   is
      Overlay : constant Natural :=
        Declaration_Overlay_Position (Of_Table, Id);
   begin
      if Overlay /= 0
        and then Of_Table.Declaration_Overlays (Overlay).Has_Settlement
      then
         return Of_Table.Declaration_Overlays (Overlay).Settlement_Fact.Answer;
      end if;
      return Of_Table.Declarations (Positive (Id)).Answer;
   end Type_Of;

   procedure Begin_Inference
     (Into : in out Table; Id : Declaration_Id) is
   begin
      if Into.Current_Routine = No_Routine_Instance then
         Into.Declarations (Positive (Id)).State := Underway;
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Settlement := True;
            Into.Declaration_Overlays (Overlay).Settlement_Fact :=
              (State => Underway, Answer => Landin.Types.Undecided);
         end;
      end if;
   end Begin_Inference;

   procedure Settle
     (Into : in out Table;
      Id   : Declaration_Id;
      Item : Landin.Types.Type_Kind) is
   begin
      if Into.Current_Routine = No_Routine_Instance then
         Into.Declarations (Positive (Id)) :=
           Settlement'(State => Settled, Answer => Item);
      else
         declare
            Overlay : constant Positive :=
              Ensure_Declaration_Overlay (Into, Id);
         begin
            Into.Declaration_Overlays (Overlay).Has_Settlement := True;
            Into.Declaration_Overlays (Overlay).Settlement_Fact :=
              (State => Settled, Answer => Item);
         end;
      end if;
   end Settle;

end Landin.Checking;
