with Landin.Source;

package body Landin.Testing.Layout is

   use type Landin.Source.Byte_Offset;
   use type Landin.Tokens.Fault_Kind;
   use type Landin.Tokens.Space_Kind;
   use type Landin.Tokens.Token_Index;
   use type Landin.Tokens.Token_Kind;

   Tab : constant Character := Character'Val (9);
   LF  : constant Character := Character'Val (10);
   CR  : constant Character := Character'Val (13);

   function Image (Value : Landin.Source.Byte_Offset) return String;

   function Image (Value : Landin.Source.Byte_Offset) return String is
      Text : constant String := Value'Image;
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   function Problem
     (Text : String; Stream : Landin.Tokens.Token_Stream) return String
   is
      Length : constant Landin.Source.Byte_Offset := Text'Length;

      --  The byte at an offset, which is how every span counts.
      function At_Offset (Offset : Landin.Source.Byte_Offset)
        return Character
        is (Text (Text'First + Natural (Offset)));

      function Slice (Where : Landin.Source.Span) return String
        is (Text (Text'First + Natural (Where.First)
                  .. Text'First + Natural (Where.Last) - 1));

      function Starts (Where : Landin.Source.Span; Opener : String)
        return Boolean
        is (Where.Last - Where.First >= Opener'Length
            and then Slice ((Where.First,
                             Where.First + Opener'Length)) = Opener);

      function Is_Blank (Item : Character) return Boolean
        is (Item = ' ' or else Item = Tab);

      --  Whether the file's next byte after Stop is a line end, or there
      --  is none: where a line or doc comment has to end.
      function At_Line_End (Stop : Landin.Source.Byte_Offset)
        return Boolean
        is (Stop = Length or else At_Offset (Stop) in LF | CR);

      function Has_No_Line_End (Where : Landin.Source.Span) return Boolean
        is (for all Item of Slice (Where) => Item not in LF | CR);

      --  [1780]'s block comment, read again: whether Where is one comment
      --  whose own `)--` closes it at its last byte, or one never closed
      --  that runs to the end of the file with the fault that says so.
      function Is_Block (Where : Landin.Source.Span) return Boolean;

      function Is_Block (Where : Landin.Source.Span) return Boolean is
         Bytes  : constant String := Slice (Where);
         Cursor : Natural := Bytes'First + 3;
         Depth  : Natural := 1;

         function Ahead (Opener : String) return Boolean
           is (Cursor + Opener'Length - 1 <= Bytes'Last
               and then Bytes (Cursor .. Cursor + Opener'Length - 1)
                        = Opener);
      begin
         if not Starts (Where, "--(") then
            return False;
         end if;

         while Cursor <= Bytes'Last loop
            if Depth = 0 then
               --  Closed before the piece ends.
               return False;
            elsif Ahead ("--(") then
               Depth := Depth + 1;
               Cursor := Cursor + 3;
            elsif Ahead (")--") then
               Depth := Depth - 1;
               Cursor := Cursor + 3;
            else
               Cursor := Cursor + 1;
            end if;
         end loop;

         if Depth = 0 then
            return True;
         end if;

         if Where.Last /= Length then
            return False;
         end if;

         for Index in 1 .. Landin.Tokens.Fault_Count (Stream) loop
            declare
               Fault : constant Landin.Tokens.Fault :=
                 Landin.Tokens.Nth_Fault (Stream, Index);
            begin
               if Landin.Tokens.Kind (Fault)
                    = Landin.Tokens.Unterminated_Block_Comment
                 and then Landin.Tokens.Opened_At (Fault).First = Where.First
               then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Is_Block;

      --  Whether a piece is what its kind says, and no longer or shorter.
      function Is_Kind
        (Kind : Landin.Tokens.Space_Kind; Where : Landin.Source.Span)
         return Boolean
        is (case Kind is
               when Landin.Tokens.Blanks =>
                 (for all Item of Slice (Where) => Is_Blank (Item))
                 and then (Where.Last = Length
                           or else not Is_Blank (At_Offset (Where.Last))),
               when Landin.Tokens.Line_End =>
                 Slice (Where) = [LF]
                 or else Slice (Where) = [CR, LF]
                 or else (Slice (Where) = [CR]
                          and then (Where.Last = Length
                                    or else At_Offset (Where.Last) /= LF)),
               when Landin.Tokens.Line_Comment =>
                 Starts (Where, "--")
                 and then not Starts (Where, "---")
                 and then not Starts (Where, "--(")
                 and then Has_No_Line_End (Where)
                 and then At_Line_End (Where.Last),
               when Landin.Tokens.Doc_Comment =>
                 Starts (Where, "---")
                 and then Has_No_Line_End (Where)
                 and then At_Line_End (Where.Last),
               when Landin.Tokens.Block_Comment => Is_Block (Where));

      --  Every byte before Cursor is in a token or a piece already seen,
      --  and each started where the one before it ended.  That is the
      --  file rebuilt, one slice at a time, without a copy of it.
      Cursor  : Landin.Source.Byte_Offset := 0;
      Next    : Positive := 1;
      Last    : constant Landin.Tokens.Token_Index :=
        Landin.Tokens.Count (Stream);
   begin
      for Index in 1 .. Last loop
         declare
            Token : constant Landin.Source.Span :=
              Landin.Tokens.Where (Stream, Index);
            First_Piece : constant Positive := Next;
            Leading : constant Landin.Tokens.Space_Range :=
              Landin.Tokens.Leading (Stream, Index);
         begin
            --  Every piece before this token, in order, from the cursor.
            while Next <= Landin.Tokens.Space_Count (Stream)
              and then Landin.Tokens.Where
                         (Landin.Tokens.Nth_Space (Stream, Next)).First
                       < Token.First
            loop
               declare
                  Piece : constant Landin.Tokens.Space :=
                    Landin.Tokens.Nth_Space (Stream, Next);
                  Where : constant Landin.Source.Span :=
                    Landin.Tokens.Where (Piece);
               begin
                  if Where.First /= Cursor then
                     return "piece" & Next'Image & " starts at "
                       & Image (Where.First) & " and the file is covered to "
                       & Image (Cursor);
                  elsif Where.Last <= Where.First or else Where.Last > Length
                  then
                     return "piece" & Next'Image & " at " & Image (Cursor)
                       & " is empty or runs past the file";
                  elsif not Is_Kind (Landin.Tokens.Kind (Piece), Where) then
                     return "piece" & Next'Image & " at " & Image (Cursor)
                       & " is not a "
                       & Landin.Tokens.Kind (Piece)'Image;
                  end if;
                  Cursor := Where.Last;
                  Next := Next + 1;
               end;
            end loop;

            if Leading.First /= First_Piece or else Leading.Last /= Next - 1
            then
               return "token" & Index'Image & " is led by pieces"
                 & Leading.First'Image & " .." & Leading.Last'Image
                 & " and not" & First_Piece'Image & " .."
                 & Natural'Image (Next - 1);
            elsif Token.First /= Cursor then
               return "token" & Index'Image & " starts at "
                 & Image (Token.First) & " and the file is covered to "
                 & Image (Cursor);
            elsif Index < Last and then Token.Last <= Token.First then
               return "token" & Index'Image & " is empty";
            end if;
            Cursor := Token.Last;
         end;
      end loop;

      if Landin.Tokens.Kind (Stream, Last) /= Landin.Tokens.End_Of_Input
        or else Landin.Tokens.Where (Stream, Last).First /= Length
      then
         return "the stream does not end in End_Of_Input at the end";
      elsif Next <= Landin.Tokens.Space_Count (Stream) then
         return "piece" & Next'Image & " follows the end of input";
      end if;
      return "";
   end Problem;

   procedure Require
     (Text : String; Stream : Landin.Tokens.Token_Stream)
   is
      Found : constant String := Problem (Text, Stream);
   begin
      if Found /= "" then
         raise Not_Reproduced with Found;
      end if;
   end Require;

end Landin.Testing.Layout;
