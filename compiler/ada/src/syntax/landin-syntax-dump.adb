with Ada.Strings.Unbounded;

package body Landin.Syntax.Dump is

   package Strings renames Ada.Strings.Unbounded;

   use type Landin.Source.Names.Name_Id;

   function Text
     (Of_Tree : Tree; Names : Landin.Source.Names.Table) return String
   is
      Out_Text : Strings.Unbounded_String;

      function Offset (Item : Landin.Source.Byte_Offset) return String;
      function Span_Text (Item : Landin.Source.Span) return String;

      --  Trimmed by hand rather than through Ada.Strings.Fixed, because a
      --  golden file is bytes and 'Image's leading blank is a byte.
      function Offset (Item : Landin.Source.Byte_Offset) return String is
         Shown : constant String := Landin.Source.Byte_Offset'Image (Item);
      begin
         return Shown (Shown'First + 1 .. Shown'Last);
      end Offset;

      function Span_Text (Item : Landin.Source.Span) return String
        is ("[" & Offset (Item.First) & "," & Offset (Item.Last) & ")");
   begin
      for Id in Node_Id'(1) .. Last_Node (Of_Tree) loop
         declare
            Of_Kind : constant Node_Kind := Kind (Of_Tree, Id);
            Line    : Strings.Unbounded_String;
         begin
            Strings.Append (Line, Offset (Landin.Source.Byte_Offset (Id)));
            Strings.Append (Line, " " & Node_Kind'Image (Of_Kind));
            Strings.Append (Line, " " & Span_Text (Where (Of_Tree, Id)));
            Strings.Append (Line, " @" & Span_Text (Anchor (Of_Tree, Id)));

            if Has_Name (Of_Kind)
              and then Name (Of_Tree, Id) /= Landin.Source.Names.No_Name
            then
               Strings.Append
                 (Line,
                  " " & Landin.Source.Names.Spelling
                          (Names, Name (Of_Tree, Id)));
            end if;

            if not Is_Sound (Of_Tree, Id) then
               Strings.Append (Line, " unsound");
            end if;

            if Of_Kind = Function_Declaration
              and then Is_External (Of_Tree, Id)
            then
               Strings.Append (Line, " extern(c)");
            end if;

            for Position in 1 .. Slot_Count (Of_Tree, Id) loop
               declare
                  Child : constant Node_Id :=
                    Slot (Of_Tree, Id, Position);
               begin
                  Strings.Append
                    (Line,
                     (if Position = 1 then " <- " else " ")
                     & (if Child = No_Node then "-"
                        else Offset (Landin.Source.Byte_Offset (Child))));
               end;
            end loop;

            if Of_Kind = Call
              and then Recovery_Of (Of_Tree, Id) /= No_Node
            then
               Strings.Append
                 (Line, " recovery "
                  & Offset
                      (Landin.Source.Byte_Offset
                         (Recovery_Of (Of_Tree, Id))));
            end if;

            Strings.Append (Out_Text, Strings.To_String (Line));
            Strings.Append (Out_Text, ASCII.LF);
         end;
      end loop;

      return Strings.To_String (Out_Text);
   end Text;

end Landin.Syntax.Dump;
