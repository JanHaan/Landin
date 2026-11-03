with Landin.Bindings.Texts;

package body Landin.Bindings.Clang is

   package T renames Landin.Bindings.Texts;

   ---------------------------------------------------------------------
   --  Reading the AST
   ---------------------------------------------------------------------

   function Field (Within : Handle; Node : J.Value; Key : String)
     return J.Value is (J.Member (Within.Ast, Node, Key));

   function Text (Within : Handle; Node : J.Value; Key : String)
     return String
   is
      Item : constant J.Value := Field (Within, Node, Key);
   begin
      return (if J.Is_Kind (Within.Ast, Item, J.String_Value)
              then J.Text (Within.Ast, Item) else "");
   end Text;

   function Truthy (Within : Handle; Node : J.Value; Key : String)
     return Boolean
   is
      Item : constant J.Value := Field (Within, Node, Key);
   begin
      if not J.Is_Present (Item) then
         return False;
      end if;
      case J.Kind (Within.Ast, Item) is
         when J.Null_Value | J.False_Value => return False;
         when J.True_Value => return True;
         when J.String_Value => return J.Text (Within.Ast, Item) /= "";
         when J.Number_Value =>
            return not (for all Char of J.Text (Within.Ast, Item) =>
                          Char in '0' | '.' | '-' | '+' | 'e' | 'E');
         when J.Array_Value | J.Object_Value =>
            return J.Length (Within.Ast, Item) > 0;
      end case;
   end Truthy;

   function Has (Within : Handle; Node : J.Value; Key : String)
     return Boolean is (J.Is_Present (Field (Within, Node, Key)));

   function Inner (Within : Handle; Node : J.Value)
     return Value_Vectors.Vector
   is
      Items : constant J.Value := Field (Within, Node, "inner");
      Result : Value_Vectors.Vector;
   begin
      if J.Is_Kind (Within.Ast, Items, J.Array_Value) then
         for Position in 1 .. J.Length (Within.Ast, Items) loop
            Result.Append (J.Element (Within.Ast, Items, Position));
         end loop;
      end if;
      return Result;
   end Inner;

   function Is_Object (Within : Handle; Node : J.Value) return Boolean is
     (J.Is_Kind (Within.Ast, Node, J.Object_Value));

   --  Clang gives a forward typedef both an ownedTagDecl for the first
   --  declaration and a nested RecordType/EnumType decl for the canonical,
   --  usually complete, redeclaration.  Prefer the latter.  A typedef owns
   --  a tag only through its direct elaborated or tag type: tags mentioned
   --  under pointers, arrays or function signatures are dependencies, not
   --  aliases of the typedef.
   procedure Owned_Tag
     (Within : Handle; Node : J.Value;
      Identity, Kind : out US.Unbounded_String);

   procedure Owned_Tag
     (Within : Handle; Node : J.Value;
      Identity, Kind : out US.Unbounded_String)
   is
      Declared_Ids, Declared_Kinds : String_Vectors.Vector;
      Owned_Ids, Owned_Kinds : String_Vectors.Vector;

      procedure Walk (Value : J.Value);

      procedure Walk (Value : J.Value) is
         Declaration : constant J.Value := Field (Within, Value, "decl");
         Owned : constant J.Value := Field (Within, Value, "ownedTagDecl");
         Kind_Text : constant String := Text (Within, Value, "kind");
      begin
         if not Is_Object (Within, Value) then
            return;
         end if;
         if Is_Object (Within, Declaration)
           and then Text (Within, Declaration, "kind")
                    in "RecordDecl" | "EnumDecl"
         then
            Declared_Ids.Append (Text (Within, Declaration, "id"));
            Declared_Kinds.Append (Text (Within, Declaration, "kind"));
         end if;
         if Is_Object (Within, Owned) then
            Owned_Ids.Append (Text (Within, Owned, "id"));
            Owned_Kinds.Append (Text (Within, Owned, "kind"));
         end if;
         if Kind_Text in "TypedefDecl" | "TypedefType" | "ElaboratedType"
             | "RecordType" | "EnumType" | "AttributedType" | "ParenType"
         then
            for Child of Inner (Within, Value) loop
               Walk (Child);
            end loop;
         end if;
      end Walk;
   begin
      Walk (Node);
      if not Declared_Ids.Is_Empty then
         Identity := US.To_Unbounded_String (Declared_Ids.Last_Element);
         Kind := US.To_Unbounded_String (Declared_Kinds.Last_Element);
      elsif not Owned_Ids.Is_Empty then
         Identity := US.To_Unbounded_String (Owned_Ids.Last_Element);
         Kind := US.To_Unbounded_String (Owned_Kinds.Last_Element);
      else
         Identity := US.Null_Unbounded_String;
         Kind := US.Null_Unbounded_String;
      end if;
   end Owned_Tag;

   procedure Build_Model (Within : Handle) is
      Nodes : Value_Vectors.Vector;
      Local_Ids : String_Sets.Set;

      procedure Walk (Node : J.Value; Inside_Function : Boolean);

      procedure Walk (Node : J.Value; Inside_Function : Boolean) is
      begin
         if not Is_Object (Within, Node) then
            return;
         end if;
         declare
            Kind_Value : constant J.Value := Field (Within, Node, "kind");
            Kind : constant String := Text (Within, Node, "kind");
            Name : constant String := Text (Within, Node, "name");
         begin
            if J.Is_Kind (Within.Ast, Kind_Value, J.String_Value) then
               Nodes.Append (Node);
               if Name /= "" then
                  Within.Identifiers.Include (Name);
               end if;
               if Inside_Function and then Truthy (Within, Node, "id") then
                  Local_Ids.Include (Text (Within, Node, "id"));
               end if;
            end if;
            for Child of Inner (Within, Node) loop
               Walk (Child, Inside_Function or else Kind = "FunctionDecl");
            end loop;
         end;
      end Walk;
   begin
      Walk (J.Root (Within.Ast), False);
      for Node of Nodes loop
         declare
            Kind : constant String := Text (Within, Node, "kind");
            Identity : constant String := Text (Within, Node, "id");
            Name : constant String := Text (Within, Node, "name");
            Implicit : constant Boolean := Truthy (Within, Node, "isImplicit");
         begin
            if Kind = "TypedefDecl" and then Identity /= ""
              and then not Implicit
            then
               Within.Typedefs_By_Id.Include (Identity, Node);
            end if;
            --  A public policy is never a selector for a body or
            --  prototype scope.
            if not Local_Ids.Contains (Identity) then
               if Kind = "RecordDecl" and then Identity /= "" then
                  if not Within.Records_By_Id.Contains (Identity) then
                     Within.Records.Append
                       (Record_Info'
                          (Node => Node,
                         Identity => US.To_Unbounded_String (Identity),
                         Tag => US.To_Unbounded_String (Name),
                         others => <>));
                     Within.Records_By_Id.Insert
                       (Identity, Within.Records.Last_Index);
                  else
                     declare
                        Index : constant Positive :=
                          Within.Records_By_Id (Identity);
                     begin
                        if not Truthy
                            (Within, Within.Records (Index).Node,
                             "completeDefinition")
                          and then Truthy (Within, Node, "completeDefinition")
                        then
                           Within.Records (Index) :=
                             (Node => Node,
                              Identity => US.To_Unbounded_String (Identity),
                              Tag => US.To_Unbounded_String (Name),
                              others => <>);
                        end if;
                     end;
                  end if;
               elsif Kind = "EnumDecl" and then Identity /= "" then
                  if not Within.Enums_By_Id.Contains (Identity) then
                     Within.Enums.Append
                       (Enum_Info'
                          (Node => Node,
                         Identity => US.To_Unbounded_String (Identity),
                         Tag => US.To_Unbounded_String (Name),
                         others => <>));
                     Within.Enums_By_Id.Insert
                       (Identity, Within.Enums.Last_Index);
                  end if;
               elsif Kind = "TypedefDecl" and then not Implicit
                 and then Name /= ""
               then
                  if not Within.Typedefs.Contains (Name) then
                     Within.Typedef_Order.Append (Name);
                  end if;
                  Within.Typedefs.Include (Name, Node);
                  if Identity /= "" then
                     Within.Typedefs_By_Id.Include (Identity, Node);
                  end if;
               elsif Kind = "FunctionDecl" and then Name /= ""
                 and then not Implicit
               then
                  if not Within.Functions.Contains (Name) then
                     Within.Functions.Insert
                       (Name, Value_Vectors.Empty_Vector);
                  end if;
                  Within.Functions (Name).Append (Node);
               elsif Kind = "VarDecl" and then Name /= "" then
                  if not Within.Variables.Contains (Name) then
                     Within.Variables.Insert
                       (Name, Value_Vectors.Empty_Vector);
                  end if;
                  Within.Variables (Name).Append (Node);
               end if;
            end if;
         end;
      end loop;

      for Name of Within.Typedef_Order loop
         declare
            Target_Id, Target_Kind : US.Unbounded_String;
         begin
            Owned_Tag (Within, Within.Typedefs (Name), Target_Id, Target_Kind);
            if US.To_String (Target_Kind) = "RecordDecl"
              and then Within.Records_By_Id.Contains
                (US.To_String (Target_Id))
            then
               Within.Records
                 (Within.Records_By_Id (US.To_String (Target_Id)))
                 .Typedef_Names.Append (Name);
            elsif US.To_String (Target_Kind) = "EnumDecl"
              and then Within.Enums_By_Id.Contains (US.To_String (Target_Id))
            then
               Within.Enums (Within.Enums_By_Id (US.To_String (Target_Id)))
                 .Typedef_Names.Append (Name);
            end if;
         end;
      end loop;

      for Index in 1 .. Within.Records.Last_Index loop
         declare
            Tag : constant String := US.To_String (Within.Records (Index).Tag);
         begin
            if Tag /= "" then
               Within.Records_By_Tag.Include (Tag, Index);
            end if;
         end;
      end loop;
      for Index in 1 .. Within.Enums.Last_Index loop
         declare
            Tag : constant String := US.To_String (Within.Enums (Index).Tag);
         begin
            if Tag /= "" then
               Within.Enums_By_Tag.Include (Tag, Index);
            end if;
         end;
      end loop;
      for Index in 1 .. Within.Records.Last_Index loop
         for Name of Within.Records (Index).Typedef_Names loop
            Within.Records_By_Typedef.Include (Name, Index);
         end loop;
      end loop;
      for Index in 1 .. Within.Enums.Last_Index loop
         for Name of Within.Enums (Index).Typedef_Names loop
            Within.Enums_By_Typedef.Include (Name, Index);
         end loop;
      end loop;
   end Build_Model;

   function Function_Node (Within : Handle; Name : String) return J.Value
   is
   begin
      if not Within.Functions.Contains (Name)
        or else Within.Functions (Name).Is_Empty
      then
         return J.No_Value;
      end if;
      return Within.Functions (Name).Last_Element;
   end Function_Node;

   function Variable_Node (Within : Handle; Name : String) return J.Value
   is
      Found : J.Value := J.No_Value;
   begin
      if not Within.Variables.Contains (Name)
        or else Within.Variables (Name).Is_Empty
      then
         return J.No_Value;
      end if;
      for Node of Within.Variables (Name) loop
         if Text (Within, Node, "storageClass") = "extern" then
            Found := Node;
         end if;
      end loop;
      return (if J.Is_Present (Found) then Found
              else Within.Variables (Name).Last_Element);
   end Variable_Node;

   function Lookup (Map : Index_Maps.Map; Key : String) return Natural is
     (if Map.Contains (Key) then Map (Key) else 0);

   function Record_Of (Within : Handle; Selector : String) return Natural is
   begin
      if T.Starts_With (Selector, "struct ") then
         return Lookup (Within.Records_By_Tag,
                        Selector (Selector'First + 7 .. Selector'Last));
      elsif T.Starts_With (Selector, "union ") then
         return Lookup (Within.Records_By_Tag,
                        Selector (Selector'First + 6 .. Selector'Last));
      end if;
      declare
         By_Typedef : constant Natural :=
           Lookup (Within.Records_By_Typedef, Selector);
      begin
         return (if By_Typedef /= 0 then By_Typedef
                 else Lookup (Within.Records_By_Tag, Selector));
      end;
   end Record_Of;

   function Enum_Of (Within : Handle; Selector : String) return Natural is
   begin
      if T.Starts_With (Selector, "enum ") then
         return Lookup (Within.Enums_By_Tag,
                        Selector (Selector'First + 5 .. Selector'Last));
      elsif T.Starts_With (Selector, "@") then
         declare
            First : constant String :=
              Selector (Selector'First + 1 .. Selector'Last);
            Found : Natural := 0;
            Matches : Natural := 0;
         begin
            for Index in 1 .. Within.Enums.Last_Index loop
               declare
                  Constants : constant Value_Vectors.Vector :=
                    Enum_Constants (Within, Index);
               begin
                  if not Constants.Is_Empty
                    and then J.Is_Kind
                      (Within.Ast,
                       Field (Within, Constants.First_Element, "name"),
                       J.String_Value)
                    and then Text (Within, Constants.First_Element, "name")
                             = First
                  then
                     Matches := Matches + 1;
                     if Found = 0 then
                        Found := Index;
                     end if;
                  end if;
               end;
            end loop;
            return (if Matches = 1 then Found else 0);
         end;
      end if;
      declare
         By_Typedef : constant Natural :=
           Lookup (Within.Enums_By_Typedef, Selector);
      begin
         return (if By_Typedef /= 0 then By_Typedef
                 else Lookup (Within.Enums_By_Tag, Selector));
      end;
   end Enum_Of;

   function Record_Complete (Within : Handle; Index : Positive)
     return Boolean is
     (Truthy (Within, Within.Records (Index).Node, "completeDefinition"));

   function Record_Union (Within : Handle; Index : Positive) return Boolean
   is (Text (Within, Within.Records (Index).Node, "tagUsed") = "union");

   function Record_Packed (Within : Handle; Index : Positive) return Boolean
   is
   begin
      for Item of Inner (Within, Within.Records (Index).Node) loop
         if Text (Within, Item, "kind") = "PackedAttr" then
            return True;
         end if;
      end loop;
      return False;
   end Record_Packed;

   function Record_C_Name (Within : Handle; Index : Positive) return String
   is
      Info : Record_Info renames Within.Records (Index);
   begin
      if not Info.Typedef_Names.Is_Empty then
         return Info.Typedef_Names.First_Element;
      elsif US.Length (Info.Tag) > 0 then
         declare
            Used : constant String := Text (Within, Info.Node, "tagUsed");
         begin
            return (if Has (Within, Info.Node, "tagUsed") then Used
                    else "struct") & " " & US.To_String (Info.Tag);
         end;
      end if;
      return "";
   end Record_C_Name;

   function Record_Display (Within : Handle; Index : Positive) return String
   is
      Info : Record_Info renames Within.Records (Index);
   begin
      return (if not Info.Typedef_Names.Is_Empty
              then Info.Typedef_Names.First_Element
              else US.To_String (Info.Tag));
   end Record_Display;

   function Record_Fields (Within : Handle; Index : Positive)
     return Value_Vectors.Vector
   is
      Result : Value_Vectors.Vector;
   begin
      for Item of Inner (Within, Within.Records (Index).Node) loop
         if Text (Within, Item, "kind") = "FieldDecl" then
            Result.Append (Item);
         end if;
      end loop;
      return Result;
   end Record_Fields;

   function Enum_C_Name (Within : Handle; Index : Positive) return String is
      Info : Enum_Info renames Within.Enums (Index);
   begin
      if not Info.Typedef_Names.Is_Empty then
         return Info.Typedef_Names.First_Element;
      elsif US.Length (Info.Tag) > 0 then
         return "enum " & US.To_String (Info.Tag);
      end if;
      return "";
   end Enum_C_Name;

   function Enum_Display (Within : Handle; Index : Positive) return String
   is
      Info : Enum_Info renames Within.Enums (Index);
   begin
      return (if not Info.Typedef_Names.Is_Empty
              then Info.Typedef_Names.First_Element
              else US.To_String (Info.Tag));
   end Enum_Display;

   function Enum_Constants (Within : Handle; Index : Positive)
     return Value_Vectors.Vector
   is
      Result : Value_Vectors.Vector;
   begin
      for Item of Inner (Within, Within.Enums (Index).Node) loop
         if Text (Within, Item, "kind") = "EnumConstantDecl" then
            Result.Append (Item);
         end if;
      end loop;
      return Result;
   end Enum_Constants;

   function Record_Index (Within : Handle; Identity : String)
     return Positive is (Within.Records_By_Id (Identity));

   function Enum_Index (Within : Handle; Identity : String) return Positive
   is (Within.Enums_By_Id (Identity));

   ---------------------------------------------------------------------
   --  Types
   ---------------------------------------------------------------------

   function Get (Within : Handle; Id : Type_Id) return C_Type is
     (Within.Types (Positive (Id)));

   function Make (Within : Handle; Item : C_Type) return Type_Id is
   begin
      Within.Types.Append (Item);
      return Type_Id (Within.Types.Last_Index);
   end Make;

   function With_Const
     (Within : Handle; Id : Type_Id; Const : Boolean)
      return Type_Id
   is
      Item : C_Type := Get (Within, Id);
   begin
      Item.Const := Const;
      return Make (Within, Item);
   end With_Const;

   function Simple
     (Kind : Type_Kind; Spelling : String; Name : String := "";
      Const : Boolean := False; Child : Type_Id := No_Type;
      Count : Long_Long_Integer := 0) return C_Type
   is ((Kind => Kind, Spelling => US.To_Unbounded_String (Spelling),
        Name => US.To_Unbounded_String (Name), Const => Const,
        Child => Child, Count => Count, others => <>));

   function Unsupported (Spelling, Why : String) return C_Type is
     (Simple (Unsupported_Type, Spelling, Why));

   type Text_Access is access constant String;

   type Builtin_Row is record
      Written, Canonical : Text_Access;
   end record;

   Builtins : constant array (Positive range <>) of Builtin_Row :=
     [(new String'("char"),
       new String'("char")),
      (new String'("signed char"),
       new String'("signed char")),
      (new String'("unsigned char"),
       new String'("unsigned char")),
      (new String'("short"),
       new String'("short")),
      (new String'("short int"),
       new String'("short")),
      (new String'("signed short"),
       new String'("short")),
      (new String'("signed short int"),
       new String'("short")),
      (new String'("unsigned short"),
       new String'("unsigned short")),
      (new String'("unsigned short int"),
       new String'("unsigned short")),
      (new String'("int"),
       new String'("int")),
      (new String'("signed"),
       new String'("int")),
      (new String'("signed int"),
       new String'("int")),
      (new String'("unsigned"),
       new String'("unsigned int")),
      (new String'("unsigned int"),
       new String'("unsigned int")),
      (new String'("long"),
       new String'("long")),
      (new String'("long int"),
       new String'("long")),
      (new String'("signed long"),
       new String'("long")),
      (new String'("signed long int"),
       new String'("long")),
      (new String'("unsigned long"),
       new String'("unsigned long")),
      (new String'("unsigned long int"),
       new String'("unsigned long")),
      (new String'("long long"),
       new String'("long long")),
      (new String'("long long int"),
       new String'("long long")),
      (new String'("signed long long"),
       new String'("long long")),
      (new String'("signed long long int"),
       new String'("long long")),
      (new String'("unsigned long long"),
       new String'("unsigned long long")),
      (new String'("unsigned long long int"),
       new String'("unsigned long long")),
      (new String'("float"),
       new String'("float")),
      (new String'("double"),
       new String'("double")),
      (new String'("_Bool"),
       new String'("_Bool")),
      (new String'("bool"),
       new String'("_Bool")),
      (new String'("void"),
       new String'("void"))];

   function Canonical_Builtin (Text : String) return String;

   function Canonical_Builtin (Text : String) return String is
   begin
      for Row of Builtins loop
         if Row.Written.all = Text then
            return Row.Canonical.all;
         end if;
      end loop;
      return "";
   end Canonical_Builtin;

   function From_Node (Within : Handle; Node : J.Value)
     return Type_Id;

   function Pointee_Type
     (Within : Handle; Child : Type_Id; Spelling : String;
      Const : Boolean := False) return Type_Id;

   function Pointee_Type
     (Within : Handle; Child : Type_Id; Spelling : String;
      Const : Boolean := False) return Type_Id
   is
      Target : Type_Id := Child;
   begin
      while Get (Within, Target).Kind = Alias_Type
        and then Get (Within, Target).Child /= No_Type
      loop
         Target := Get (Within, Target).Child;
      end loop;
      if Get (Within, Target).Kind = Function_Type then
         declare
            Item : C_Type := Get (Within, Target);
         begin
            Item.Kind := Callback_Type;
            Item.Spelling := US.To_Unbounded_String (Spelling);
            Item.Const := Const;
            return Make (Within, Item);
         end;
      end if;
      return Make (Within, Simple (Pointer_Type, Spelling, Const => Const,
                                   Child => Child));
   end Pointee_Type;

   function From_Info (Within : Handle; Info : J.Value)
     return Type_Id
   is
      Spelling_Value : constant J.Value := Field (Within, Info, "qualType");
   begin
      if not J.Is_Kind (Within.Ast, Spelling_Value, J.String_Value) then
         Fail (Within, "Clang AST type is missing qualType", Clang_Fault);
      end if;
      declare
         Spelling : constant String := J.Text (Within.Ast, Spelling_Value);
         Alias_Id : constant String :=
           Text (Within, Info, "typeAliasDeclId");
      begin
         if Alias_Id /= "" and then Within.Typedefs_By_Id.Contains (Alias_Id)
         then
            declare
               Alias_Name : constant String :=
                 Text (Within, Within.Typedefs_By_Id (Alias_Id), "name");
               Parts : constant String_Vectors.Vector := T.Words (Spelling);
               Unqualified : String_Vectors.Vector;
            begin
               for Part of Parts loop
                  if Part not in "const" | "restrict" | "volatile" then
                     Unqualified.Append (Part);
                  end if;
               end loop;
               if Natural (Unqualified.Length) = 1
                 and then Unqualified.First_Element = Alias_Name
               then
                  if Parts.Contains ("volatile") then
                     return Make
                       (Within, Unsupported
                          (Spelling, "atomic or volatile qualified type"));
                  end if;
                  return With_Const
                    (Within, Alias (Within, Alias_Name, Alias_Id),
                     Parts.Contains ("const"));
               end if;
            end;
         end if;
         if Within.Typedefs.Contains (Spelling) then
            return Alias (Within, Spelling);
         end if;
         declare
            Mark : constant US.Unbounded_String := Within.Problem;
            Mark_Kind : constant Fault_Kind := Within.Kind;
         begin
            return Parse (Within, Spelling);
         exception
            when Binding_Error =>
               declare
                  Desugared : constant String :=
                    Text (Within, Info, "desugaredQualType");
               begin
                  if Has (Within, Info, "desugaredQualType")
                    and then Desugared /= Spelling
                  then
                     Within.Problem := Mark;
                     Within.Kind := Mark_Kind;
                     return Parse (Within, Desugared);
                  end if;
                  raise;
               end;
         end;
      end;
   end From_Info;

   function Alias
     (Within : Handle; Name : String; Identity : String := "")
      return Type_Id
   is
      Node : constant J.Value :=
        (if Identity /= "" then Within.Typedefs_By_Id (Identity)
         else Within.Typedefs (Name));
      Own : constant String := Text (Within, Node, "id");
   begin
      if Within.Alias_Cache.Contains (Own) then
         return Make
           (Within,
            (Simple (Alias_Type, Name, Name,
                     Child => Type_Id (Within.Alias_Cache (Own)))
             with delta Declaration => US.To_Unbounded_String (Own)));
      end if;
      if Within.Alias_Stack.Contains (Own) then
         Fail (Within, "unsupported recursive typedef " & T.Repr (Name));
      end if;
      Within.Alias_Stack.Include (Own);
      declare
         Type_Nodes : Value_Vectors.Vector;
         Target : Type_Id;
      begin
         for Item of Inner (Within, Node) loop
            if T.Ends_With (Text (Within, Item, "kind"), "Type") then
               Type_Nodes.Append (Item);
            end if;
         end loop;
         Target :=
           (if not Type_Nodes.Is_Empty
            then From_Node (Within, Type_Nodes.First_Element)
            else From_Info (Within, Field (Within, Node, "type")));
         Within.Alias_Stack.Exclude (Own);
         Within.Alias_Cache.Include (Own, Natural (Target));
         return Make
           (Within,
            (Simple (Alias_Type, Name, Name, Child => Target)
             with delta Declaration => US.To_Unbounded_String (Own)));
      end;
   end Alias;

   function From_Node (Within : Handle; Node : J.Value)
     return Type_Id
   is
      Kind : constant String := Text (Within, Node, "kind");
      Spelling : constant String :=
        Text (Within, Field (Within, Node, "type"), "qualType");
      Children : constant Value_Vectors.Vector := Inner (Within, Node);
   begin
      if Kind in "ElaboratedType" | "ParenType" and then not Children.Is_Empty
      then
         return From_Node (Within, Children.First_Element);
      end if;
      if Kind = "TypedefType" then
         declare
            Declaration : constant J.Value := Field (Within, Node, "decl");
            Id : constant String := Text (Within, Declaration, "id");
         begin
            if not (Has (Within, Declaration, "id")
                    and then Within.Typedefs_By_Id.Contains (Id))
            then
               Fail (Within, "unsupported unavailable typedef "
                     & Texts.Value_Repr
                         (Within.Ast, Field (Within, Declaration, "name")));
            end if;
            return Alias (Within, Text (Within, Declaration, "name"), Id);
         end;
      end if;
      if Kind in "RecordType" | "EnumType" then
         return Make
           (Within,
            Simple ((if Kind = "RecordType" then Record_Type else Enum_Type),
                    Spelling,
                    Text (Within, Field (Within, Node, "decl"), "id")));
      end if;
      if Kind in "FunctionProtoType" | "FunctionNoProtoType" then
         if Has (Within, Node, "cc") and then Text (Within, Node, "cc")
           /= "cdecl"
         then
            Fail (Within, "unsupported calling convention "
                  & Texts.Value_Repr (Within.Ast, Field (Within, Node, "cc"))
                  & ": " & Spelling);
         end if;
         if Children.Is_Empty then
            Fail (Within, "Clang function type has no result: " & Spelling);
         end if;
         declare
            Item : C_Type := Simple (Function_Type, Spelling);
         begin
            Item.Result := From_Node (Within, Children.First_Element);
            for Position in 2 .. Natural (Children.Length) loop
               Item.Parameters.Append
                 (From_Node (Within, Children (Position)));
            end loop;
            Item.Variadic := Truthy (Within, Node, "variadic");
            Item.Old_Style := Kind = "FunctionNoProtoType";
            return Make (Within, Item);
         end;
      end if;
      if Kind = "PointerType" and then not Children.Is_Empty then
         return Pointee_Type
           (Within, From_Node (Within, Children.First_Element), Spelling);
      end if;
      if Kind = "ConstantArrayType" and then not Children.Is_Empty then
         declare
            Size : constant J.Value := Field (Within, Node, "size");
         begin
            if not J.Is_Integer (Within.Ast, Size) then
               Fail (Within, "Clang array type has no size: " & Spelling,
                     Clang_Fault);
            end if;
            return Make
              (Within,
               Simple (Array_Type, Spelling,
                       Child => From_Node (Within, Children.First_Element),
                       Count => Long_Long_Integer
                         (J.Integer_Of (Within.Ast, Size))));
         end;
      end if;
      if Kind = "QualType" and then not Children.Is_Empty then
         declare
            Qualifiers : constant String :=
              Text (Within, Node, "qualifiers");
         begin
            if T.Contains (Qualifiers, "volatile") then
               return Make
                 (Within, Unsupported
                    (Spelling, "atomic or volatile qualified type"));
            end if;
            return With_Const
              (Within, From_Node (Within, Children.First_Element),
               T.Contains (Qualifiers, "const"));
         end;
      end if;
      if Kind = "AttributedType" then
         return Make
           (Within, Unsupported
              (Spelling, "calling-convention or type attribute"));
      end if;
      return Parse (Within, Spelling);
   end From_Node;

   --  Text split at Delimiter outside parentheses and brackets, each
   --  piece stripped.
   function Split_Top_Level (Text : String; Delimiter : Character := ',')
     return String_Vectors.Vector;

   function Split_Top_Level (Text : String; Delimiter : Character := ',')
     return String_Vectors.Vector
   is
      Pieces : String_Vectors.Vector;
      Start : Positive := Text'First;
      Paren, Bracket : Integer := 0;
   begin
      for Index in Text'Range loop
         case Text (Index) is
            when '(' => Paren := Paren + 1;
            when ')' => Paren := Paren - 1;
            when '[' => Bracket := Bracket + 1;
            when ']' => Bracket := Bracket - 1;
            when others =>
               if Text (Index) = Delimiter and then Paren = 0
                 and then Bracket = 0
               then
                  Pieces.Append (T.Strip (Text (Start .. Index - 1)));
                  Start := Index + 1;
               end if;
         end case;
      end loop;
      Pieces.Append (T.Strip (Text (Start .. Text'Last)));
      return Pieces;
   end Split_Top_Level;

   procedure Split_Function
     (Text : String; Found : out Boolean;
      Result_Text, Parameter_Text : out US.Unbounded_String)
   is
      Start : Natural := 0;
      Depth : Integer := 0;
   begin
      Found := False;
      Result_Text := US.Null_Unbounded_String;
      Parameter_Text := US.Null_Unbounded_String;
      for Index in Text'Range loop
         if Text (Index) = '(' then
            Start := Index;
            exit;
         end if;
      end loop;
      if Start <= Text'First then
         return;
      end if;
      for Index in Start .. Text'Last loop
         if Text (Index) = '(' then
            Depth := Depth + 1;
         elsif Text (Index) = ')' then
            Depth := Depth - 1;
            if Depth = 0 then
               if Index /= Text'Last
                 or else T.Starts_With
                   (T.Strip (Text (Start + 1 .. Text'Last)), "*")
               then
                  return;
               end if;
               Found := True;
               Result_Text := US.To_Unbounded_String
                 (T.Strip (Text (Text'First .. Start - 1)));
               Parameter_Text := US.To_Unbounded_String
                 (T.Strip (Text (Start + 1 .. Index - 1)));
               return;
            end if;
         end if;
      end loop;
   end Split_Function;

   procedure Parse_Parameters
     (Within : Handle; Text : String; Item : in out C_Type);

   procedure Parse_Parameters
     (Within : Handle; Text : String; Item : in out C_Type)
   is
   begin
      if Text = "" then
         Item.Old_Style := True;
         return;
      elsif Text = "void" then
         return;
      end if;
      declare
         Parts : String_Vectors.Vector := Split_Top_Level (Text);
      begin
         if Parts.Last_Element = "..." then
            Item.Variadic := True;
            Parts.Delete_Last;
         end if;
         for Part of Parts loop
            Item.Parameters.Append (Parse (Within, Part));
         end loop;
      end;
   end Parse_Parameters;

   --  `int (*)(...)`, `int (* const)(...)`: the result's text, whether the
   --  pointer is const and the parameters' text, or Found false.
   procedure Match_Callback
     (Text : String; Found : out Boolean; Const : out Boolean;
      Result_Text, Parameter_Text : out US.Unbounded_String);

   procedure Match_Callback
     (Text : String; Found : out Boolean; Const : out Boolean;
      Result_Text, Parameter_Text : out US.Unbounded_String)
   is
      function Skip (From : Positive) return Positive;

      function Skip (From : Positive) return Positive is
         Index : Positive := From;
      begin
         while Index <= Text'Last and then T.Is_Space (Text (Index)) loop
            Index := Index + 1;
         end loop;
         return Index;
      end Skip;
   begin
      Found := False;
      Const := False;
      Result_Text := US.Null_Unbounded_String;
      Parameter_Text := US.Null_Unbounded_String;
      for Split in Text'First + 1 .. Text'Last loop
         declare
            Index : Positive := Skip (Split);
            Constant_Pointer : Boolean := False;
         begin
            if Index + 1 <= Text'Last and then Text (Index .. Index + 1) = "(*"
            then
               Index := Skip (Index + 2);
               if Index + 4 <= Text'Last
                 and then Text (Index .. Index + 4) = "const"
                 and then Skip (Index + 5) <= Text'Last
                 and then Text (Skip (Index + 5)) = ')'
               then
                  Constant_Pointer := True;
                  Index := Skip (Index + 5);
               end if;
               if Index + 1 <= Text'Last
                 and then Text (Index .. Index + 1) = ")("
                 and then Text (Text'Last) = ')'
                 and then Index + 2 <= Text'Last
               then
                  Found := True;
                  Const := Constant_Pointer;
                  Result_Text := US.To_Unbounded_String
                    (Text (Text'First .. Split - 1));
                  Parameter_Text := US.To_Unbounded_String
                    (Text (Index + 2 .. Text'Last - 1));
                  return;
               end if;
            end if;
         end;
      end loop;
   end Match_Callback;

   --  `T *`, `T * const`, `T *restrict`: the pointee's text and whether
   --  the pointer is const, or Found false.
   procedure Match_Pointer
     (Text : String; Found : out Boolean; Const : out Boolean;
      Pointee_Text : out US.Unbounded_String);

   procedure Match_Pointer
     (Text : String; Found : out Boolean; Const : out Boolean;
      Pointee_Text : out US.Unbounded_String)
   is
   begin
      Found := False;
      Const := False;
      Pointee_Text := US.Null_Unbounded_String;
      for Split in Text'First + 1 .. Text'Last - 1 loop
         if Text (Split .. Split + 1) = " *" then
            declare
               Index : Positive := Split + 2;
               Qualifiers : String_Vectors.Vector;
            begin
               while Index <= Text'Last and then T.Is_Space (Text (Index))
               loop
                  Index := Index + 1;
               end loop;
               loop
                  if Index + 4 <= Text'Last
                    and then Text (Index .. Index + 4) = "const"
                  then
                     Qualifiers.Append ("const");
                     Index := Index + 5;
                  elsif Index + 7 <= Text'Last
                    and then Text (Index .. Index + 7) = "restrict"
                  then
                     Qualifiers.Append ("restrict");
                     Index := Index + 8;
                  else
                     exit;
                  end if;
                  while Index <= Text'Last and then T.Is_Space (Text (Index))
                  loop
                     Index := Index + 1;
                  end loop;
               end loop;
               if Index > Text'Last then
                  Found := True;
                  Const := Qualifiers.Contains ("const");
                  Pointee_Text := US.To_Unbounded_String
                    (T.Strip (Text (Text'First .. Split - 1)));
                  return;
               end if;
            end;
         end if;
      end loop;
   end Match_Pointer;

   function Parse (Within : Handle; Spelling : String)
     return Type_Id
   is
      Whole : constant String := T.Collapse (Spelling);
   begin
      if Whole = "" then
         Fail (Within, "Clang AST supplied an empty type");
      end if;
      if T.Contains (Whole, "__attribute__") or else T.Contains (Whole,
        "__vector")
        or else T.Contains (Whole, "vector_size")
      then
         return Make (Within, Unsupported
                        (Whole, "vector or calling-convention attribute"));
      end if;
      if T.Contains (Whole, "_Complex") or else T.Contains (Whole, "complex")
      then
         return Make (Within, Unsupported (Whole, "complex type"));
      end if;
      if Whole in "long double" | "__float128" | "_Float16" | "__fp16" then
         return Make (Within, Unsupported
                        (Whole, "extended or x87 floating type"));
      end if;
      if T.Contains (Whole, "__int128") then
         return Make (Within, Unsupported (Whole, "128-bit integer type"));
      end if;
      if T.Contains (Whole, "va_list") then
         return Make (Within, Unsupported (Whole, "va_list forwarding"));
      end if;
      if T.Starts_With (Whole, "_Atomic")
        or else T.Contains (" " & Whole, " volatile")
      then
         return Make (Within, Unsupported
                        (Whole, "atomic or volatile qualified type"));
      end if;

      --  An array: C's first bracket is the outer array, not its last.
      declare
         First_Special : Natural := 0;
      begin
         for Index in Whole'Range loop
            if Whole (Index) in '(' | ')' | '[' | ']' then
               First_Special := Index;
               exit;
            end if;
         end loop;
         if First_Special > Whole'First and then Whole (First_Special) = '['
         then
            declare
               Extents : String_Vectors.Vector;
               Index : Positive := First_Special;
               Matched : Boolean := True;
            begin
               while Index <= Whole'Last loop
                  while Index <= Whole'Last and then T.Is_Space (Whole (Index))
                  loop
                     Index := Index + 1;
                  end loop;
                  if Index > Whole'Last or else Whole (Index) /= '[' then
                     Matched := False;
                     exit;
                  end if;
                  declare
                     Close : Natural := 0;
                  begin
                     for Next in Index + 1 .. Whole'Last loop
                        if Whole (Next) = ']' then
                           Close := Next;
                           exit;
                        end if;
                     end loop;
                     if Close = 0 then
                        Matched := False;
                        exit;
                     end if;
                     Extents.Append (Whole (Index + 1 .. Close - 1));
                     Index := Close + 1;
                  end;
               end loop;
               if Matched then
                  declare
                     Result : Type_Id :=
                       Parse (Within,
                         Whole (Whole'First .. First_Special - 1));
                  begin
                     for Position in reverse 1 .. Natural (Extents.Length) loop
                        declare
                           Extent : constant String :=
                             T.Strip (Extents (Position));
                        begin
                           if not (Extent = ""
                                   or else (T.Is_Digits (Extent)
                                            and then Extent'Length <= 18))
                           then
                              Fail (Within,
                                "unsupported nonconstant array type "
                                    & T.Repr (Whole));
                           end if;
                           Result := Make
                             (Within,
                              Simple (Array_Type, Whole, Child => Result,
                                      Count =>
                                        (if Extent = "" then -1
                                         else Long_Long_Integer'Value
                                                (Extent))));
                        end;
                     end loop;
                     return Result;
                  end;
               end if;
            end;
         end if;
      end;

      declare
         Found, Const : Boolean;
         Result_Text, Parameter_Text : US.Unbounded_String;
      begin
         Match_Callback (Whole, Found, Const, Result_Text, Parameter_Text);
         if Found then
            declare
               Item : C_Type := Simple (Callback_Type, Whole, Const => Const);
            begin
               Item.Result := Parse (Within, US.To_String (Result_Text));
               Parse_Parameters (Within, US.To_String (Parameter_Text), Item);
               return Make (Within, Item);
            end;
         end if;
      end;

      declare
         Found, Const : Boolean;
         Pointee_Text : US.Unbounded_String;
      begin
         Match_Pointer (Whole, Found, Const, Pointee_Text);
         if Found then
            return Pointee_Type
              (Within, Parse (Within, US.To_String (Pointee_Text)), Whole,
               Const);
         end if;
      end;

      declare
         Const : constant Boolean := T.Starts_With (Whole, "const ");
         Rest : constant String :=
           (if Const then T.Strip (Whole (Whole'First + 6 .. Whole'Last))
            else Whole);
         Canonical : constant String := Canonical_Builtin (Rest);
      begin
         if Canonical /= "" then
            return Make (Within, Simple (Builtin_Type, Spelling, Canonical,
                                         Const => Const));
         end if;
         if T.Starts_With (Rest, "struct ") or else T.Starts_With (Rest,
           "union ")
         then
            declare
               Index : constant Natural := Record_Of (Within, Rest);
            begin
               if Index /= 0 then
                  return Make
                    (Within, Simple (Record_Type, Spelling,
                                     US.To_String
                                       (Within.Records (Index).Identity),
                                     Const => Const));
               end if;
            end;
         end if;
         if T.Starts_With (Rest, "enum ") then
            declare
               Index : constant Natural := Enum_Of (Within, Rest);
            begin
               if Index /= 0 then
                  return Make
                    (Within, Simple (Enum_Type, Spelling,
                                     US.To_String
                                       (Within.Enums (Index).Identity),
                                     Const => Const));
               end if;
            end;
         end if;
         if Within.Typedefs.Contains (Rest) then
            return With_Const (Within, Alias (Within, Rest), Const);
         end if;
         for Opening in 1 .. 2 loop
            for Middle in 1 .. 3 loop
               if T.Contains
                 (Rest,
                  (if Opening = 1 then "(unnamed" else "(anonymous")
                  & (case Middle is
                       when 1 => "", when 2 => " struct",
                       when others => " union")
                  & " at ")
               then
                  return Make (Within, Unsupported
                                 (Spelling, "anonymous unaliased aggregate"));
               end if;
            end loop;
         end loop;
         declare
            Found : Boolean;
            Result_Text, Parameter_Text : US.Unbounded_String;
         begin
            Split_Function (Rest, Found, Result_Text, Parameter_Text);
            if Found then
               declare
                  Item : C_Type := Simple (Function_Type, Spelling);
               begin
                  Item.Result := Parse (Within, US.To_String (Result_Text));
                  Parse_Parameters
                    (Within, US.To_String (Parameter_Text), Item);
                  return Make (Within, Item);
               end;
            end if;
         end;
      end;
      return Make (Within, Unsupported (Spelling, "unrecognized Clang type"));
   end Parse;

end Landin.Bindings.Clang;
