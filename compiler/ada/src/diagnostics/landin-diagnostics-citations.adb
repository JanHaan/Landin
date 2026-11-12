package body Landin.Diagnostics.Citations is

   package Unbounded renames Ada.Strings.Unbounded;

   LF  : constant Character := Character'Val (10);
   Tab : constant Character := Character'Val (9);

   function Read
     (Content : Ada.Strings.Unbounded.Unbounded_String) return Table
   is
      Head : constant Natural := Format_Line'Length;
   begin
      return
        (Content => Content,
         Ok      =>
           Unbounded.Length (Content) > Head
           and then Unbounded.Slice (Content, 1, Head) = Format_Line
           and then Unbounded.Element (Content, Head + 1) = LF);
   end Read;

   function First_Line (From : Table) return String is
      Shown : Unbounded.Unbounded_String;
   begin
      for At_Byte in 1 .. Natural'Min (Unbounded.Length (From.Content), 60)
      loop
         declare
            Each : constant Character :=
              Unbounded.Element (From.Content, At_Byte);
         begin
            exit when Each = LF;
            if Each in ' ' .. '~' then
               Unbounded.Append (Shown, Each);
            end if;
         end;
      end loop;
      return Unbounded.To_String (Shown);
   end First_Line;

   function Source (From : Table) return String is
      First : constant Positive := Format_Line'Length + 2;
      Last  : constant Natural :=
        First + Source_Head'Length + Digest_Length - 1;
      Size  : constant Natural := Unbounded.Length (From.Content);
   begin
      if not From.Ok or else Size < Last
        or else Unbounded.Slice
          (From.Content, First, First + Source_Head'Length - 1)
          /= Source_Head
        or else (Size > Last
                 and then Unbounded.Element (From.Content, Last + 1) /= LF)
      then
         return "";
      end if;
      declare
         Digest : constant String :=
           Unbounded.Slice (From.Content, Last - Digest_Length + 1, Last);
      begin
         if (for some Each of Digest =>
               Each not in '0' .. '9' | 'a' .. 'f')
         then
            return "";
         end if;
         return Digest;
      end;
   end Source;

   --  The number as the file writes it, with no leading blank.
   function Image (Number : Natural) return String;

   function Image (Number : Natural) return String is
      Spelled : constant String := Natural'Image (Number);
   begin
      return Spelled (Spelled'First + 1 .. Spelled'Last);
   end Image;

   --  A field's bytes with its three escapes undone.  A backslash before
   --  anything else is kept as it is written.
   function Plain (Field : String) return String;

   function Plain (Field : String) return String is
      Result  : String (1 .. Field'Length);
      Last    : Natural := 0;
      At_Byte : Natural := Field'First;
   begin
      while At_Byte <= Field'Last loop
         Last := Last + 1;
         if Field (At_Byte) = '\' and then At_Byte < Field'Last
           and then Field (At_Byte + 1) in '\' | 'n' | 't'
         then
            Result (Last) :=
              (case Field (At_Byte + 1) is
                  when 'n' => LF, when 't' => Tab, when others => '\');
            At_Byte := At_Byte + 2;
         else
            Result (Last) := Field (At_Byte);
            At_Byte := At_Byte + 1;
         end if;
      end loop;
      return Result (1 .. Last);
   end Plain;

   --  The field numbered Wanted of the entry for Kind and Number, the
   --  title being the first, or "" when the table holds no such entry or
   --  the entry is short of that field.  The first entry answers when a
   --  number is written twice, which `check.py` refuses in the file it
   --  generates.
   function Field
     (From   : Table;
      Kind   : Citation_Kind;
      Number : Natural;
      Wanted : Positive) return String;

   function Field
     (From   : Table;
      Kind   : Citation_Kind;
      Number : Natural;
      Wanted : Positive) return String
   is
      Key   : constant String :=
        LF & (case Kind is when Construct => 'C', when Decision => 'D')
        & Tab & Image (Number) & Tab;
      Found : constant Natural :=
        (if From.Ok then Unbounded.Index (From.Content, Key) else 0);
      Size  : constant Natural := Unbounded.Length (From.Content);
      First : Natural := Found + Key'Length;
      Seen  : Positive := 1;
   begin
      if Found = 0 then
         return "";
      end if;
      for At_Byte in First .. Size + 1 loop
         if At_Byte > Size
           or else Unbounded.Element (From.Content, At_Byte) in LF | Tab
         then
            if Seen = Wanted then
               return Plain
                 (Unbounded.Slice (From.Content, First, At_Byte - 1));
            end if;
            exit when At_Byte > Size
              or else Unbounded.Element (From.Content, At_Byte) = LF;
            Seen := Seen + 1;
            First := At_Byte + 1;
         end if;
      end loop;
      return "";
   end Field;

   function Holds
     (From : Table; Kind : Citation_Kind; Number : Natural) return Boolean
     is (Field (From, Kind, Number, 1) /= "");

   function Title
     (From : Table; Kind : Citation_Kind; Number : Natural) return String
     is (Field (From, Kind, Number, 1));

   function Place
     (From : Table; Kind : Citation_Kind; Number : Natural) return String
     is (Field (From, Kind, Number, 2));

   function Page
     (From : Table; Kind : Citation_Kind; Number : Natural) return String
     is (Field (From, Kind, Number, 3));

   function Text
     (From : Table; Kind : Citation_Kind; Number : Natural) return String
     is (Field (From, Kind, Number, 4));

end Landin.Diagnostics.Citations;
