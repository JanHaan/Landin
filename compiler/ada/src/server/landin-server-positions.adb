package body Landin.Server.Positions is

   use type Landin.Source.Byte_Offset;

   function Before (Left, Right : Endpoint) return Boolean
     is (Left.Offset < Right.Offset);

   package Endpoint_Sorting is new Endpoint_Vectors.Generic_Sorting
     ("<" => Before);

   function Width
     (Lead, Second, Third, Fourth : Integer) return Positive
   is
   begin
      case Lead is
         when 16#C2# .. 16#DF# =>
            return (if Second in 16#80# .. 16#BF# then 2 else 1);
         when 16#E0# =>
            return (if Second in 16#A0# .. 16#BF#
                      and then Third in 16#80# .. 16#BF# then 3 else 1);
         when 16#E1# .. 16#EC# | 16#EE# .. 16#EF# =>
            return (if Second in 16#80# .. 16#BF#
                      and then Third in 16#80# .. 16#BF# then 3 else 1);
         when 16#ED# =>
            return (if Second in 16#80# .. 16#9F#
                      and then Third in 16#80# .. 16#BF# then 3 else 1);
         when 16#F0# =>
            return (if Second in 16#90# .. 16#BF#
                      and then Third in 16#80# .. 16#BF#
                      and then Fourth in 16#80# .. 16#BF# then 4 else 1);
         when 16#F1# .. 16#F3# =>
            return (if Second in 16#80# .. 16#BF#
                      and then Third in 16#80# .. 16#BF#
                      and then Fourth in 16#80# .. 16#BF# then 4 else 1);
         when 16#F4# =>
            return (if Second in 16#80# .. 16#8F#
                      and then Third in 16#80# .. 16#BF#
                      and then Fourth in 16#80# .. 16#BF# then 4 else 1);
         when others =>
            return 1;
      end case;
   end Width;

   --  The byte length of the character starting at Index.
   function Width (Text : String; Index : Positive) return Positive;

   function Width (Text : String; Index : Positive) return Positive is
      function Byte (Offset : Natural) return Integer
        is (if Index + Offset <= Text'Last
            then Character'Pos (Text (Index + Offset)) else -1);
   begin
      return Width (Byte (0), Byte (1), Byte (2), Byte (3));
   end Width;

   procedure Register
     (Map : in out Position_Map; Offset : Landin.Source.Byte_Offset)
   is
   begin
      Map.Points.Append (Endpoint'(Offset => Offset, At_Pos => (0, 0)));
      Map.Built := False;
   end Register;

   procedure Prepare
     (Map : in out Position_Map; Text : String; Unit : Encoding)
   is
      At_Byte : Natural := Text'First;
      At_Pos  : Position;
      Remaining : Natural := 0;
      Pending_Units : Positive := 1;
   begin
      Endpoint_Sorting.Sort (Map.Points);
      if Map.Points.Is_Empty then
         Map.Built := True;
         return;
      end if;
      for Index in Map.Points.First_Index .. Map.Points.Last_Index loop
         declare
            Offset : constant Landin.Source.Byte_Offset :=
              Map.Points.Element (Index).Offset;
            Target : constant Natural :=
              Text'First + Natural'Min (Natural (Offset), Text'Length);
         begin
            while At_Byte < Target loop
               if Remaining > 0 then
                  Remaining := Remaining - 1;
                  if Remaining = 0 then
                     At_Pos.Character := At_Pos.Character + Pending_Units;
                  end if;
               elsif Text (At_Byte) = ASCII.LF
                 or else (Text (At_Byte) = ASCII.CR
                          and then (At_Byte = Text'Last
                                    or else Text (At_Byte + 1) /= ASCII.LF))
               then
                  At_Pos.Line := At_Pos.Line + 1;
                  At_Pos.Character := 0;
               elsif Text (At_Byte) /= ASCII.CR then
                  declare
                     Size : constant Positive := Width (Text, At_Byte);
                  begin
                     if Size = 1 then
                        At_Pos.Character := At_Pos.Character
                          + Units (Size, Unit);
                     else
                        Remaining := Size - 1;
                        Pending_Units := Units (Size, Unit);
                     end if;
                  end;
               end if;
               At_Byte := At_Byte + 1;
            end loop;
            Map.Points.Replace_Element
              (Index, (Offset => Offset, At_Pos => At_Pos));
         end;
      end loop;
      Map.Built := True;
   end Prepare;

   function Endpoint_Count (Map : Position_Map) return Natural
     is (Natural (Map.Points.Length));

   function Ready (Map : Position_Map) return Boolean
     is (Map.Built);

   function Position_Of
     (Map : Position_Map; Offset : Landin.Source.Byte_Offset)
      return Position
   is
      Low, High : Natural;
   begin
      if not Map.Built or else Map.Points.Is_Empty then
         raise Program_Error with "unprepared LSP positions";
      end if;
      Low := Map.Points.First_Index;
      High := Map.Points.Last_Index;
      while Low <= High loop
         declare
            Middle : constant Natural := Low + (High - Low) / 2;
            Found  : constant Endpoint := Map.Points.Element (Middle);
         begin
            if Found.Offset = Offset then
               return Found.At_Pos;
            elsif Offset < Found.Offset then
               exit when Middle = 0;
               High := Middle - 1;
            else
               Low := Middle + 1;
            end if;
         end;
      end loop;
      raise Program_Error with "unregistered LSP position";
   end Position_Of;

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
