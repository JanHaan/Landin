package body Landin.Platform is

   package Unbounded renames Ada.Strings.Unbounded;

   function No_Arguments return Path_List is
      Empty : Path_List;
   begin
      return Empty;
   end No_Arguments;

   function Arguments (First : String) return Path_List is
      Result : Path_List;
   begin
      Result.Append (First);
      return Result;
   end Arguments;

   procedure Add (Into : in out Path_List; Argument : String) is
   begin
      Into.Append (Argument);
   end Add;

   function Joined (Lines : Path_List) return String is
      Buffer : Unbounded.Unbounded_String;
   begin
      for Line of Lines loop
         Unbounded.Append (Buffer, Line);
         Unbounded.Append (Buffer, Character'Val (10));
      end loop;
      return Unbounded.To_String (Buffer);
   end Joined;

end Landin.Platform;
