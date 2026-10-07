with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Targets.Selection;

package body Landin.Testing.Lanes is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Targets.Target_Facts;

   Chosen        : Landin.Targets.Target_Facts := Landin.Targets.Synthetic_32;
   Chosen_Is_Set : Boolean := False;
   Runner_Name   : Unbounded.Unbounded_String;
   Driver_Name   : Unbounded.Unbounded_String;

   --  The product targets' own names, and the label each one's fixtures
   --  carry.  synthetic-32 has no corpus to execute, so it is no lane.
   function Label_Of (Name : String) return String
     is (if Name = "linux-x86-64" then "linux-x86-64"
         elsif Name = "linux-arm64" then "linux-arm64"
         elsif Name = "darwin-arm64" then "macos-arm64"
         elsif Name in "freebsd-x86-64" | "freebsd-arm64" then Name
         elsif Name = "cortex-m0" then "cortex-m"
         else "");

   function Select_Target (Name : String) return Boolean is
   begin
      if not Landin.Targets.Selection.Is_Described (Name)
        or else Label_Of (Name) = ""
      then
         return False;
      end if;
      Chosen := Landin.Targets.Selection.Described (Name);
      Chosen_Is_Set := True;
      return True;
   end Select_Target;

   procedure Select_Runner (Program : String) is
   begin
      Runner_Name := Unbounded.To_Unbounded_String (Program);
   end Select_Runner;

   procedure Select_Toolchain (Driver : String) is
   begin
      Driver_Name := Unbounded.To_Unbounded_String (Driver);
   end Select_Toolchain;

   function Host_Has_Default return Boolean
     is (Landin.Targets.Selection.Has_Host_Default
           (Landin.Targets.Selection.Build_Triplet));

   function Has_Target return Boolean
     is (Chosen_Is_Set or else Host_Has_Default);

   function Target return Landin.Targets.Target_Facts is
   begin
      if Chosen_Is_Set then
         return Chosen;
      elsif Host_Has_Default then
         return Landin.Targets.Selection.Host_Default
           (Landin.Targets.Selection.Build_Triplet);
      else
         raise Compiler_Defect
           with "no lane: this host has no description; name --target=";
      end if;
   end Target;

   function Target_Name return String is (Landin.Targets.Name (Target));

   function Fixture_Label return String is (Label_Of (Target_Name));

   function Applies (Targets : String) return Boolean is
      Wanted : constant String := Fixture_Label;
      First  : Integer := Targets'First;
   begin
      for Index in Targets'First .. Targets'Last + 1 loop
         if Index > Targets'Last or else Targets (Index) = ',' then
            if Ada.Strings.Fixed.Trim
                 (Targets (First .. Index - 1), Ada.Strings.Both) = Wanted
            then
               return True;
            end if;
            First := Index + 1;
         end if;
      end loop;
      return False;
   end Applies;

   function Is_Native return Boolean
     is (Host_Has_Default
         and then Target = Landin.Targets.Selection.Host_Default
                             (Landin.Targets.Selection.Build_Triplet));

   function Runner return String is (Unbounded.To_String (Runner_Name));

   function Toolchain return String is (Unbounded.To_String (Driver_Name));

   function Target_Arguments return Landin.Platform.Path_List is
      Result : Landin.Platform.Path_List;
   begin
      if not Is_Native then
         Result.Append ("--target=" & Target_Name);
      end if;
      return Result;
   end Target_Arguments;

   function Describe return String is
     ((if Is_Native then "NATIVE " else "CROSS ") & Target_Name
      & (if Runner = "" then "" else ", run by " & Runner)
      & (if Toolchain = "" then "" else ", linked by " & Toolchain));

end Landin.Testing.Lanes;
