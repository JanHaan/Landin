package body Landin.Server.Positions is

   --  The byte length of the character starting at Index, by Unicode's
   --  well-formed table: 1 for a byte that begins nothing well formed.
   function Width (Text : String; Index : Positive) return Positive;

   function Width (Text : String; Index : Positive) return Positive is
      function Byte (Offset : Natural) return Natural
        is (Character'Pos (Text (Index + Offset)));
      function Continues (Offset : Natural; Low, High : Natural)
        return Boolean
        is (Index + Offset <= Text'Last
            and then Byte (Offset) in Low .. High);
   begin
      case Byte (0) is
         when 16#C2# .. 16#DF# =>
            return (if Continues (1, 16#80#, 16#BF#) then 2 else 1);
         when 16#E0# =>
            return (if Continues (1, 16#A0#, 16#BF#)
                      and then Continues (2, 16#80#, 16#BF#) then 3 else 1);
         when 16#E1# .. 16#EC# | 16#EE# .. 16#EF# =>
            return (if Continues (1, 16#80#, 16#BF#)
                      and then Continues (2, 16#80#, 16#BF#) then 3 else 1);
         when 16#ED# =>
            return (if Continues (1, 16#80#, 16#9F#)
                      and then Continues (2, 16#80#, 16#BF#) then 3 else 1);
         when 16#F0# =>
            return (if Continues (1, 16#90#, 16#BF#)
                      and then Continues (2, 16#80#, 16#BF#)
                      and then Continues (3, 16#80#, 16#BF#) then 4 else 1);
         when 16#F1# .. 16#F3# =>
            return (if Continues (1, 16#80#, 16#BF#)
                      and then Continues (2, 16#80#, 16#BF#)
                      and then Continues (3, 16#80#, 16#BF#) then 4 else 1);
         when 16#F4# =>
            return (if Continues (1, 16#80#, 16#8F#)
                      and then Continues (2, 16#80#, 16#BF#)
                      and then Continues (3, 16#80#, 16#BF#) then 4 else 1);
         when others =>
            return 1;
      end case;
   end Width;

   --  How many units a character of Bytes bytes is.
   function Units (Bytes : Positive; Unit : Encoding) return Positive
     is (case Unit is
           when UTF_8  => Bytes,
           when UTF_16 => (if Bytes = 4 then 2 else 1));

   procedure Prepare
     (Map : in out Position_Map; Text : String; Unit : Encoding)
   is
      At_Byte : Natural := Text'First;
      At_Pos  : Position;
   begin
      Map.Points.Clear;
      Map.Points.Append (At_Pos);
      while At_Byte <= Text'Last loop
         if Text (At_Byte) = ASCII.LF
           or else (Text (At_Byte) = ASCII.CR
                    and then (At_Byte = Text'Last
                              or else Text (At_Byte + 1) /= ASCII.LF))
         then
            At_Pos.Line := At_Pos.Line + 1;
            At_Pos.Character := 0;
            Map.Points.Append (At_Pos);
            At_Byte := At_Byte + 1;
         elsif Text (At_Byte) = ASCII.CR then
            --  The LF, rather than the CR, advances a CR LF line.
            Map.Points.Append (At_Pos);
            At_Byte := At_Byte + 1;
         else
            declare
               Size : constant Positive := Width (Text, At_Byte);
            begin
               --  An endpoint inside a UTF-8 character names its first
               --  byte, so all interior boundaries keep the old column.
               for Byte in 1 .. Size - 1 loop
                  Map.Points.Append (At_Pos);
               end loop;
               At_Pos.Character := At_Pos.Character + Units (Size, Unit);
               Map.Points.Append (At_Pos);
               At_Byte := At_Byte + Size;
            end;
         end if;
      end loop;
   end Prepare;

   function Ready (Map : Position_Map) return Boolean
     is (not Map.Points.Is_Empty);

   function Position_Of
     (Map : Position_Map; Offset : Landin.Source.Byte_Offset)
      return Position
     is (Map.Points.Element
           (Natural'Min (Natural (Offset), Map.Points.Last_Index)));

   --  The index of the first byte of Line, and of the byte after it ends
   --  (its terminator excluded), in Text's own indexing.
   procedure Line_Bounds
     (Text : String; Line : Natural; First, Stop : out Natural;
      Found : out Boolean);

   procedure Line_Bounds
     (Text : String; Line : Natural; First, Stop : out Natural;
      Found : out Boolean)
   is
      Current : Natural := 0;
      Index   : Natural := Text'First;
   begin
      First := Text'First;
      Found := Line = 0;
      while not Found and then Index <= Text'Last loop
         if Text (Index) = ASCII.LF
           or else (Text (Index) = ASCII.CR
                    and then (Index = Text'Last
                              or else Text (Index + 1) /= ASCII.LF))
         then
            Current := Current + 1;
            if Current = Line then
               First := Index + 1;
               Found := True;
            end if;
         end if;
         Index := Index + 1;
      end loop;
      if not Found then
         First := Text'Last + 1;
      end if;
      Stop := First;
      while Stop <= Text'Last
        and then Text (Stop) not in ASCII.LF | ASCII.CR
      loop
         Stop := Stop + 1;
      end loop;
   end Line_Bounds;

   function Position_Of
     (Text   : String;
      Offset : Landin.Source.Byte_Offset;
      Unit   : Encoding) return Position
   is
      Target : constant Natural :=
        Text'First + Natural'Min (Natural (Offset), Text'Length);
      Answer : Position;
      Start  : Natural := Text'First;
      Index  : Natural := Text'First;
   begin
      while Index < Target loop
         if Text (Index) = ASCII.LF
           or else (Text (Index) = ASCII.CR
                    and then (Index = Text'Last
                              or else Text (Index + 1) /= ASCII.LF))
         then
            Answer.Line := Answer.Line + 1;
            Start := Index + 1;
         end if;
         Index := Index + 1;
      end loop;
      --  A CR whose LF is the target is the line's end, not a new line.
      Index := Start;
      while Index < Target loop
         if Text (Index) in ASCII.LF | ASCII.CR then
            exit;
         end if;
         declare
            Size : constant Positive := Width (Text, Index);
         begin
            exit when Index + Size > Target;
            Answer.Character := Answer.Character + Units (Size, Unit);
            Index := Index + Size;
         end;
      end loop;
      return Answer;
   end Position_Of;

   function Offset_Of
     (Text  : String;
      Where : Position;
      Unit  : Encoding) return Landin.Source.Byte_Offset
   is
      First, Stop : Natural;
      Found       : Boolean;
      Index       : Natural;
      Counted     : Natural := 0;
   begin
      Line_Bounds (Text, Where.Line, First, Stop, Found);
      if not Found then
         return Landin.Source.Byte_Offset (Text'Length);
      end if;
      Index := First;
      while Index < Stop loop
         declare
            Size : constant Positive := Width (Text, Index);
            Next : constant Natural := Counted + Units (Size, Unit);
         begin
            exit when Next > Where.Character;
            Counted := Next;
            Index := Index + Size;
         end;
      end loop;
      return Landin.Source.Byte_Offset (Index - Text'First);
   end Offset_Of;

end Landin.Server.Positions;
