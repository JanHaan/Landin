package body Landin.Optimization is

   function Spelling (Value : Objective) return String
     is (case Value is
            when None => "none",
            when Size => "size",
            when Speed => "speed");

   function Spelling (Value : Specialization_Mode) return String
     is (case Value is
            when Off => "off",
            when Auto => "auto",
            when All_Eligible => "all");

   procedure Parse
     (Text : String; Value : out Objective; Accepted : out Boolean) is
   begin
      for Candidate in Objective loop
         if Text = Spelling (Candidate) then
            Value := Candidate;
            Accepted := True;
            return;
         end if;
      end loop;
      Value := Default_Options.Optimize;
      Accepted := False;
   end Parse;

   procedure Parse
     (Text : String; Value : out Specialization_Mode;
      Accepted : out Boolean) is
   begin
      for Candidate in Specialization_Mode loop
         if Text = Spelling (Candidate) then
            Value := Candidate;
            Accepted := True;
            return;
         end if;
      end loop;
      Value := Default_Options.Specialize;
      Accepted := False;
   end Parse;

end Landin.Optimization;
