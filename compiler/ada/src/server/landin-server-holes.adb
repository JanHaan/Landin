with Landin.Diagnostics;
with Landin.Diagnostics.Lexical;
with Landin.Machine;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Syntax;
with Landin.Syntax.Parser;
with Landin.Tokens;
with Landin.Tokens.Lexer;

package body Landin.Server.Holes is

   package Syn renames Landin.Syntax;
   package Tok renames Landin.Tokens;

   use type Landin.Diagnostics.Severity;
   use type Landin.Machine.Convention;
   use type Landin.Source.Byte_Offset;
   use type Landin.Source.Names.Name_Id;
   use type Syn.Node_Id;
   use type Syn.Node_Kind;
   use type Tok.Token_Index;
   use type Tok.Token_Kind;

   function Before (Left, Right : Landin.Source.Span) return Boolean
     is (Left.First < Right.First);

   package Sorting is new Span_Vectors.Generic_Sorting ("<" => Before);

   function Within (Held : Span_List; Where : Landin.Source.Span)
     return Boolean
   is
   begin
      for Region of Held loop
         if (Where.First < Region.Last and then Region.First < Where.Last)
           or else (Where.First = Where.Last
                    and then Where.First >= Region.First
                    and then Where.First < Region.Last)
         then
            return True;
         end if;
      end loop;
      return False;
   end Within;

   --  Whether every byte of Where lies in Region.
   function Inside (Region, Where : Landin.Source.Span) return Boolean
     is (Where.First >= Region.First and then Where.Last <= Region.Last
         and then (Where.First < Where.Last
                   or else Where.First < Region.Last));

   function Plan_For (Text : String) return Plan is
      --  Offsets count from zero and a caller's string need not start at
      --  one, so the bytes are read through a copy that does.
      Bytes   : constant String (1 .. Text'Length) := Text;
      Answer  : Plan (Text'Length);
      Sources : Landin.Source.Sets.Source_Set;
      Names   : Landin.Source.Names.Table;
      Stream  : Tok.Token_Stream;
      Found   : Landin.Diagnostics.Diagnostic_List;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add ("stand-in", Bytes);

      --  What is blanked in each held region: everything before its `end`.
      Blanked : Span_List;
   begin
      Answer.Text := Bytes;
      Tok.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Found);
      declare
         Tree : constant Syn.Tree :=
           Syn.Parser.Parse (Stream, Names, Found);
         Last : constant Tok.Token_Index := Tok.Count (Stream);

         --  The index of the first token that starts at or after Offset.
         function Token_From (Offset : Landin.Source.Byte_Offset)
           return Tok.Token_Index;

         function Token_From (Offset : Landin.Source.Byte_Offset)
           return Tok.Token_Index
         is
            Low  : Tok.Token_Index := 1;
            High : Tok.Token_Index := Last;
         begin
            while Low < High loop
               declare
                  Middle : constant Tok.Token_Index := Low + (High - Low) / 2;
               begin
                  if Tok.Where (Stream, Middle).First < Offset then
                     Low := Middle + 1;
                  else
                     High := Middle;
                  end if;
               end;
            end loop;
            return Low;
         end Token_From;

         function Sound_Or_Absent (Node : Syn.Node_Id) return Boolean
           is (Node = Syn.No_Node or else Syn.Is_Sound (Tree, Node));

         --  The region a function's body holds, from just after its `=`
         --  to the end of the `end` the parser closed it with, and the
         --  bytes before that `end`; nothing when no stand-in may
         --  replace it.
         procedure Body_Region
           (Node : Syn.Node_Id; Region, Blank : out Landin.Source.Span);

         procedure Body_Region
           (Node : Syn.Node_Id; Region, Blank : out Landin.Source.Span)
         is
            Runs    : constant Syn.Node_Id := Syn.Body_Of (Tree, Node);
            Returns : constant Syn.Node_Id := Syn.Returns_Of (Tree, Node);
            Errors  : constant Syn.Node_Id := Syn.Error_Set_Of (Tree, Node);
            Extent  : constant Landin.Source.Span := Syn.Where (Tree, Node);
            Signature_End : Landin.Source.Byte_Offset :=
              Syn.Anchor (Tree, Node).Last;
            Opening : Tok.Token_Index;
            Closing : Tok.Token_Index;
         begin
            Region := Landin.Source.Empty_Span;
            Blank := Landin.Source.Empty_Span;
            if Syn.Is_Sound (Tree, Runs)
              or else Syn.Is_External (Tree, Node)
              or else Syn.Machine_Convention (Tree, Node)
                /= Landin.Machine.Ordinary
              or else Syn.Generic_Formal_Count (Tree, Node) > 0
              or else Syn.Name (Tree, Node) = Landin.Source.Names.No_Name
              or else not Sound_Or_Absent (Returns)
              or else not Sound_Or_Absent (Errors)
              or else (Errors /= Syn.No_Node
                       and then Syn.Kind (Tree, Errors)
                         = Syn.Inferred_Error_Set)
            then
               return;
            end if;

            --  The `=` is the first after everything the signature holds.
            for Position in 1 .. Syn.Parameter_Count (Tree, Node) loop
               declare
                  Parameter : constant Syn.Node_Id :=
                    Syn.Nth_Parameter (Tree, Node, Position);
               begin
                  if not Syn.Is_Sound (Tree, Parameter) then
                     return;
                  end if;
                  Signature_End := Landin.Source.Byte_Offset'Max
                    (Signature_End, Syn.Where (Tree, Parameter).Last);
               end;
            end loop;
            if Returns /= Syn.No_Node then
               Signature_End := Landin.Source.Byte_Offset'Max
                 (Signature_End, Syn.Where (Tree, Returns).Last);
            end if;
            if Errors /= Syn.No_Node then
               Signature_End := Landin.Source.Byte_Offset'Max
                 (Signature_End, Syn.Where (Tree, Errors).Last);
            end if;
            Opening := Token_From (Signature_End);
            while Opening < Last
              and then Tok.Kind (Stream, Opening) /= Tok.Equal
            loop
               Opening := Opening + 1;
            end loop;
            if Tok.Kind (Stream, Opening) /= Tok.Equal
              or else Tok.Where (Stream, Opening).First >= Extent.Last
            then
               return;
            end if;

            --  The declaration's last token is `end`, or `end` and the
            --  name it repeats.
            Closing := Token_From (Extent.Last);
            if Closing = 1 then
               return;
            end if;
            Closing := Closing - 1;
            if Tok.Kind (Stream, Closing) = Tok.Identifier
              and then Closing > 1
              and then Tok.Kind (Stream, Closing - 1) = Tok.Kw_End
            then
               Closing := Closing - 1;
            end if;
            if Tok.Kind (Stream, Closing) /= Tok.Kw_End
              or else Closing <= Opening
            then
               return;
            end if;

            declare
               From : constant Landin.Source.Byte_Offset :=
                 Tok.Where (Stream, Opening).Last;
               To   : constant Landin.Source.Byte_Offset :=
                 Tok.Where (Stream, Closing).First;
            begin
               --  A line inside the body that begins in column one may be
               --  a declaration that recovery read as a statement.
               for Offset in From .. To - 1 loop
                  declare
                     At_Byte : constant Positive := Natural (Offset) + 1;
                  begin
                     if Offset + 1 < To
                       and then (Bytes (At_Byte) = ASCII.LF
                                 or else (Bytes (At_Byte) = ASCII.CR
                                          and then Bytes (At_Byte + 1)
                                            /= ASCII.LF))
                       and then Bytes (At_Byte + 1)
                         not in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
                     then
                        return;
                     end if;
                  end;
               end loop;
               Region := (From, Tok.Where (Stream, Closing).Last);
               Blank := (From, To);
            end;
         end Body_Region;

         Regions, Blanks : Span_List;
      begin
         if not Found.Has_Errors then
            Answer.Outcome := Sound;
            return Answer;
         end if;

         for Position in 1 .. Syn.Declaration_Count (Tree) loop
            declare
               Node : constant Syn.Node_Id :=
                 Syn.Nth_Declaration (Tree, Position);
               Region, Blank : Landin.Source.Span;
            begin
               if Syn.Kind (Tree, Node) = Syn.Function_Declaration then
                  Body_Region (Node, Region, Blank);
                  if Region.Last > Region.First then
                     Regions.Append (Region);
                     Blanks.Append (Blank);
                  end if;
               end if;
            end;
         end loop;

         --  Every error must lie in a held region, and only a region an
         --  error lies in is stood in for.
         for Index in 1 .. Found.Count loop
            declare
               Item  : constant Landin.Diagnostics.Diagnostic :=
                 Found.Get (Index);
               Where : constant Landin.Source.Span :=
                 Landin.Diagnostics.Span_Of
                   (Landin.Diagnostics.Primary (Item));
               Held  : Boolean := False;
            begin
               if Landin.Diagnostics.Level (Item) = Landin.Diagnostics.Error
               then
                  for Position in 1 .. Natural (Regions.Length) loop
                     if Inside (Regions.Element (Position), Where) then
                        Held := True;
                        if not Answer.Held.Contains
                          (Regions.Element (Position))
                        then
                           Answer.Held.Append (Regions.Element (Position));
                           Blanked.Append (Blanks.Element (Position));
                        end if;
                     end if;
                  end loop;
                  if not Held then
                     Answer.Held.Clear;
                     return Answer;
                  end if;
               end if;
            end;
         end loop;
      end;

      Sorting.Sort (Answer.Held);
      Sorting.Sort (Blanked);

      --  Each body's bytes become blanks, its line ends stay, and the
      --  stand-in's four words are written into the blanks in order, each
      --  with a blank on both sides: the `=` and the `end` around it are
      --  tokens that space has to separate from what touches them.
      for Region of Blanked loop
         declare
            Last_Byte : constant Natural := Natural (Region.Last);
            Cursor    : Natural := Natural (Region.First) + 1;
            Placed    : Natural := 0;

            type Word_Index is range 1 .. 4;
            function Word (Which : Word_Index) return String
              is (case Which is
                    when 1 | 4 => "loop",
                    when 2     => "do",
                    when 3     => "end");
         begin
            for Index in Cursor .. Last_Byte loop
               if Answer.Text (Index) not in ASCII.LF | ASCII.CR then
                  Answer.Text (Index) := ' ';
               end if;
            end loop;
            for Which in Word_Index loop
               declare
                  Spelled : constant String := Word (Which);
               begin
                  --  A word starts after a blank and ends before one, inside
                  --  the region: Cursor is the first byte it may take.
                  Cursor := Cursor + 1;
                  while Cursor + Spelled'Length <= Last_Byte
                    and then Answer.Text
                      (Cursor .. Cursor + Spelled'Length - 1)
                        /= [1 .. Spelled'Length => ' ']
                  loop
                     Cursor := Cursor + 1;
                  end loop;
                  exit when Cursor + Spelled'Length > Last_Byte;
                  Answer.Text (Cursor .. Cursor + Spelled'Length - 1) :=
                    Spelled;
                  Cursor := Cursor + Spelled'Length;
                  Placed := Placed + 1;
               end;
            end loop;
            if Placed < 4 then
               Answer.Held.Clear;
               Answer.Text := Bytes;
               return Answer;
            end if;
         end;
      end loop;
      Answer.Outcome := Stood_In;
      return Answer;
   end Plan_For;

end Landin.Server.Holes;
