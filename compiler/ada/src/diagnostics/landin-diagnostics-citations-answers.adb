with Landin.Diagnostics.Citations.Texts;

package body Landin.Diagnostics.Citations.Answers is

   LF : constant Character := Character'Val (10);

   --  A run of one to four digits, which is as long as either number is
   --  written; a longer one names nothing either document could hold.
   function Is_Number (Text : String) return Boolean
     is (Text'Length in 1 .. 4
         and then (for all Each of Text => Each in '0' .. '9'));

   function Kind_Of (Asked : String) return Citation_Kind
     is (if Asked (Asked'First) in 'D' | 'd' then Decision else Construct);

   --  The digits Asked is written with.
   function Digits_Of (Asked : String) return String
     is (if Asked (Asked'First) in 'D' | 'd'
         then Asked (Asked'First + 1 .. Asked'Last)
         elsif Asked (Asked'First) = '['
         then Asked (Asked'First + 1 .. Asked'Last - 1)
         else Asked);

   function Is_Citation (Asked : String) return Boolean is
   begin
      if Asked'Length = 0 then
         return False;
      elsif Asked (Asked'First) in 'D' | 'd' then
         return Is_Number (Asked (Asked'First + 1 .. Asked'Last));
      elsif Asked (Asked'First) = '[' then
         return Asked'Length = 6 and then Asked (Asked'Last) = ']'
           and then Is_Number (Asked (Asked'First + 1 .. Asked'Last - 1));
      else
         return Asked'Length = 4 and then Is_Number (Asked);
      end if;
   end Is_Citation;

   function Number_Of (Asked : String) return Natural
     is (Natural'Value (Digits_Of (Asked)));

   --  A decision's number without the leading zeros `D0275` was asked with.
   function Image (Number : Natural) return String;

   function Image (Number : Natural) return String is
      Spelled : constant String := Natural'Image (Number);
   begin
      return Spelled (Spelled'First + 1 .. Spelled'Last);
   end Image;

   --  The citation as the documents write it: `[1590]` and `D275`.
   function Written (Asked : String) return String
     is (case Kind_Of (Asked) is
            when Construct => "[" & Digits_Of (Asked) & "]",
            when Decision  =>
               "D" & Image (Number_Of (Asked)));

   function Is_Known (Asked : String) return Boolean
     is (Holds (Kind_Of (Asked), Number_Of (Asked)));

   function Answer (Asked : String; Full : Boolean) return String is
      Number : constant Natural := Number_Of (Asked);
      Head   : constant String :=
        (case Kind_Of (Asked) is
            when Construct =>
               Written (Asked) & "  " & Construct_Title (Number) & LF
               & "  " & Construct_Document (Number) & LF
               & "  " & Construct_Page (Number) & LF,
            when Decision =>
               Written (Asked) & "  " & Decision_Title (Number) & LF
               & "  spec.md, " & Decision_Section (Number) & LF
               & "  " & Decision_Page (Number) & LF);
      Text   : constant String :=
        (if not Full then ""
         else (case Kind_Of (Asked) is
                  when Construct => Texts.Construct_Text (Number),
                  when Decision  => Texts.Decision_Text (Number)));
   begin
      return Head & (if Text = "" then "" else LF & Text & LF);
   end Answer;

   function Unknown (Asked : String) return String
     is (case Kind_Of (Asked) is
            when Construct =>
               "no construct is numbered " & Written (Asked)
               & " in tour.md or spec.md",
            when Decision =>
               "no decision is numbered " & Written (Asked)
               & " in spec.md's register");

end Landin.Diagnostics.Citations.Answers;
