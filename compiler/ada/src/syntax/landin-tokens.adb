with Ada.Characters.Handling;

package body Landin.Tokens is

   --  A sign's bytes.  Its enumeration name is the byte names joined by
   --  underscores, so the table and the name say the same thing twice and
   --  check.py compares them.
   function Sign_Spelling (Of_Kind : Token_Kind) return String;

   function Sign_Spelling (Of_Kind : Token_Kind) return String is
     (case Of_Kind is
         when Ampersand       => "&",
         when Bar             => "|",
         when Caret           => "^",
         when Colon           => ":",
         when Colon_Equal     => ":=",
         when Comma           => ",",
         when Equal           => "=",
         when Equal_Equal     => "==",
         when Greater         => ">",
         when Greater_Equal   => ">=",
         when Greater_Greater => ">>",
         when Left_Paren      => "(",
         when Less            => "<",
         when Less_Equal      => "<=",
         when Less_Greater    => "<>",
         when Less_Less       => "<<",
         when Minus           => "-",
         when Minus_Greater   => "->",
         when Minus_Percent   => "-%",
         when Percent         => "%",
         when Plus            => "+",
         when Plus_Percent    => "+%",
         when Right_Paren     => ")",
         when Slash           => "/",
         when Star            => "*",
         when Star_Percent    => "*%",
         when Tilde           => "~",
         when Underscore      => "_",
         when Bang            => "!",
         when Dot             => ".",
         when Dot_Dot         => "..",
         when Dot_Dot_Dot     => "...",
         when Dot_Dot_Less    => "..<",
         when Left_Bracket    => "[",
         when Right_Bracket   => "]",
         when others          =>
            raise Compiler_Defect with "not a sign: " & Of_Kind'Image);

   function Spelling (Of_Kind : Spelled_Kind) return String is
   begin
      if Of_Kind in Reserved_Word then
         --  Kw_Elsif -> elsif.  The letters of a reserved word are written
         --  once in this compiler, in the enumeration literal.
         return Ada.Characters.Handling.To_Lower
           (Of_Kind'Image (Of_Kind'Image'First + 3 .. Of_Kind'Image'Last));
      end if;

      return Sign_Spelling (Of_Kind);
   end Spelling;

   function Construct (Of_Kind : Described_Kind) return Construct_Reference is
     (case Of_Kind is
         when Character_Literal => "[0250]",
         when Hex_Float_Literal => "[0230]",
         when Raw_Literal       => "[0280]",
         when Text_Literal      => "[0260]");

   function Kind (Item : Token) return Token_Kind is (Item.Kind);

   function Where (Item : Token) return Landin.Source.Span is (Item.Where);

   function Name (Item : Token) return Landin.Source.Names.Name_Id
     is (Item.Name);

   function Base (Item : Token) return Integer_Base is (Item.Base);

   function Digit_Span (Item : Token) return Landin.Source.Span
     is (Item.Digit_Run);

   function Assignment_Operation (Item : Token) return Assignment_Operator
     is (Item.Assignment);

   function Kind (Item : Fault) return Fault_Kind is (Item.Kind);

   function Where (Item : Fault) return Landin.Source.Span is (Item.Where);

   function Opened_At (Item : Fault) return Landin.Source.Span
     is (Item.Opened);

   function Refused (Item : Fault) return Described_Kind is (Item.Refused);

   function Source_Of (Of_Stream : Token_Stream)
     return Landin.Source.Source_Id is (Of_Stream.Source);

   function Count (Of_Stream : Token_Stream) return Token_Index
     is (Token_Index (Of_Stream.Items.Length));

   function Token_At (Of_Stream : Token_Stream; At_Index : Token_Index)
     return Token is (Of_Stream.Items.Element (Positive (At_Index)));

   function Kind (Of_Stream : Token_Stream; At_Index : Token_Index)
     return Token_Kind is (Token_At (Of_Stream, At_Index).Kind);

   function Where (Of_Stream : Token_Stream; At_Index : Token_Index)
     return Landin.Source.Span is (Token_At (Of_Stream, At_Index).Where);

   function Skip_To
     (Of_Stream : Token_Stream;
      From      : Token_Index;
      Wanted    : Kind_Set) return Token_Index
   is
      At_Index : Token_Index := From;
   begin
      --  End_Of_Input is wanted by precondition and is the last token by
      --  construction, so this cannot run off the end.
      while not Wanted (Kind (Of_Stream, At_Index)) loop
         At_Index := At_Index + 1;
      end loop;
      return At_Index;
   end Skip_To;

   function Fault_Count (Of_Stream : Token_Stream) return Natural
     is (Natural (Of_Stream.Faults.Length));

   function Nth_Fault (Of_Stream : Token_Stream; Index : Positive)
     return Fault is (Of_Stream.Faults.Element (Index));

   function Doc_Comment_Count (Of_Stream : Token_Stream) return Natural
     is (Natural (Of_Stream.Docs.Length));

   function Nth_Doc_Comment (Of_Stream : Token_Stream; Index : Positive)
     return Landin.Source.Span is (Of_Stream.Docs.Element (Index));

end Landin.Tokens;
