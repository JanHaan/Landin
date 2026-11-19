with Ada.Containers.Indefinite_Vectors;
with Landin.Json;

package body Landin.Adapter.MI is

   package US renames Ada.Strings.Unbounded;
   package J renames Landin.Json;

   package Name_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, String);

   --  A malformed record: the line is then Other.
   Malformed : exception;

   function Parse (Text : String) return Line is
      Position : Natural := Text'First;
      Result : Line;
      Out_Of : J.Builder;

      function At_End return Boolean is (Position > Text'Last);

      function Peek return Character is
        (if At_End then Character'Val (0) else Text (Position));

      procedure Expect (C : Character);
      procedure Expect (C : Character) is
      begin
         if Peek /= C then
            raise Malformed;
         end if;
         Position := Position + 1;
      end Expect;

      --  A C string's decoded bytes; Position is at its opening quote.
      function C_String return String;
      function C_String return String is
         Decoded : US.Unbounded_String;
      begin
         Expect ('"');
         loop
            if At_End then
               raise Malformed;
            end if;
            declare
               C : constant Character := Text (Position);
            begin
               Position := Position + 1;
               exit when C = '"';
               if C /= '\' then
                  US.Append (Decoded, C);
               else
                  if At_End then
                     raise Malformed;
                  end if;
                  declare
                     E : constant Character := Text (Position);
                  begin
                     Position := Position + 1;
                     case E is
                        when 'n' => US.Append (Decoded, ASCII.LF);
                        when 't' => US.Append (Decoded, ASCII.HT);
                        when 'r' => US.Append (Decoded, ASCII.CR);
                        when 'a' => US.Append (Decoded, ASCII.BEL);
                        when 'b' => US.Append (Decoded, ASCII.BS);
                        when 'f' => US.Append (Decoded, ASCII.FF);
                        when 'v' => US.Append (Decoded, ASCII.VT);
                        when 'e' => US.Append (Decoded, ASCII.ESC);
                        when '0' .. '7' =>
                           declare
                              Code : Natural :=
                                Character'Pos (E) - Character'Pos ('0');
                           begin
                              for Unused in 1 .. 2 loop
                                 exit when Peek not in '0' .. '7';
                                 Code := Code * 8 + Character'Pos (Peek)
                                   - Character'Pos ('0');
                                 Position := Position + 1;
                              end loop;
                              US.Append
                                (Decoded, Character'Val (Code mod 256));
                           end;
                        when others => US.Append (Decoded, E);
                     end case;
                  end;
               end if;
            end;
         end loop;
         return US.To_String (Decoded);
      end C_String;

      function Variable return String;
      function Variable return String is
         First : constant Positive := Position;
      begin
         while not At_End and then Text (Position) not in '=' | ',' | '}'
           | ']' | '{' | '[' | '"'
         loop
            Position := Position + 1;
         end loop;
         if Position = First then
            raise Malformed;
         end if;
         return Text (First .. Position - 1);
      end Variable;

      procedure Value;

      --  Results up to Closer, as members of the object being built.
      procedure Members (Closer : Character);
      procedure Members (Closer : Character) is
         Seen : Name_Vectors.Vector;
      begin
         if Peek = Closer then
            return;
         end if;
         loop
            declare
               Name : constant String := Variable;
               Count : Natural := 0;
            begin
               for Earlier of Seen loop
                  if Earlier = Name then
                     Count := Count + 1;
                  end if;
               end loop;
               Seen.Append (Name);
               J.Name (Out_Of, (if Count = 0 then Name
                                else Name & "#" & Count'Image
                                  (2 .. Count'Image'Last)));
               Expect ('=');
               Value;
            end;
            exit when Peek /= ',';
            Position := Position + 1;
         end loop;
      end Members;

      procedure Value is
      begin
         case Peek is
            when '"' =>
               J.Write_String (Out_Of, C_String);
            when '{' =>
               Position := Position + 1;
               J.Begin_Object (Out_Of);
               Members ('}');
               J.End_Object (Out_Of);
               Expect ('}');
            when '[' =>
               Position := Position + 1;
               J.Begin_Array (Out_Of);
               if Peek /= ']' then
                  loop
                     if Peek in '"' | '{' | '[' then
                        Value;
                     else
                        --  A named element: its name is dropped.
                        declare
                           Unused : constant String := Variable;
                        begin
                           Expect ('=');
                           Value;
                        end;
                     end if;
                     exit when Peek /= ',';
                     Position := Position + 1;
                  end loop;
               end if;
               J.End_Array (Out_Of);
               Expect (']');
            when others =>
               raise Malformed;
         end case;
      end Value;

   begin
      Result.Results := US.To_Unbounded_String ("{}");
      if Text'Length >= 5
        and then Text (Text'First .. Text'First + 4) = "(gdb)"
        and then (for all C of Text (Text'First + 5 .. Text'Last) => C = ' ')
      then
         Result.Kind := Prompt;
         return Result;
      end if;
      while not At_End and then Text (Position) in '0' .. '9' loop
         if Result.Token > 99_999_999 then
            raise Malformed;
         end if;
         Result.Token := Result.Token * 10
           + (Character'Pos (Text (Position)) - Character'Pos ('0'));
         Position := Position + 1;
      end loop;
      case Peek is
         when '^' | '*' | '+' | '=' =>
            Result.Kind :=
              (case Peek is
                 when '^' => MI.Result,
                 when '*' => Exec,
                 when '+' => Status,
                 when others => Notify);
            Position := Position + 1;
            declare
               First : constant Positive := Position;
            begin
               while not At_End and then Text (Position) /= ',' loop
                  Position := Position + 1;
               end loop;
               if Position = First then
                  raise Malformed;
               end if;
               Result.Class := US.To_Unbounded_String
                 (Text (First .. Position - 1));
            end;
            J.Begin_Object (Out_Of);
            if not At_End then
               Position := Position + 1;
               Members (Character'Val (0));
            end if;
            J.End_Object (Out_Of);
            if not At_End then
               raise Malformed;
            end if;
            Result.Results := US.To_Unbounded_String (J.Result (Out_Of));
         when '~' | '@' | '&' =>
            if Result.Token /= 0 then
               raise Malformed;
            end if;
            Result.Kind :=
              (case Peek is
                 when '~' => Console,
                 when '@' => Target,
                 when others => Log);
            Position := Position + 1;
            Result.Text := US.To_Unbounded_String (C_String);
            if not At_End then
               raise Malformed;
            end if;
         when others =>
            raise Malformed;
      end case;
      return Result;
   exception
      when Malformed =>
         return (Kind => Other, Token => 0,
                 Class => US.Null_Unbounded_String,
                 Results => US.To_Unbounded_String ("{}"),
                 Text => US.To_Unbounded_String (Text));
   end Parse;

   function Quoted (Item : String) return String is
      Written : US.Unbounded_String := US.To_Unbounded_String ("""");
   begin
      for C of Item loop
         case C is
            when '"' | '\' =>
               US.Append (Written, '\' & C);
            when ASCII.LF =>
               US.Append (Written, "\n");
            when ASCII.CR =>
               US.Append (Written, "\r");
            when ASCII.HT =>
               US.Append (Written, "\t");
            when others =>
               if Character'Pos (C) < 32 or else Character'Pos (C) = 127 then
                  declare
                     Code : constant Natural := Character'Pos (C);
                  begin
                     US.Append (Written, '\'
                       & Character'Val (Character'Pos ('0') + Code / 64)
                       & Character'Val (Character'Pos ('0') + Code / 8 mod 8)
                       & Character'Val (Character'Pos ('0') + Code mod 8));
                  end;
               else
                  US.Append (Written, C);
               end if;
         end case;
      end loop;
      US.Append (Written, '"');
      return US.To_String (Written);
   end Quoted;

end Landin.Adapter.MI;
