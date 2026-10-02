with Ada.Strings.Fixed;

package body Landin.Targets.Selection is

   function Is_Described (Name : String) return Boolean
     is (Name in "linux-x86-64" | "linux-arm64" | "darwin-arm64"
                | "cortex-m0" | "synthetic-32");

   function Described (Name : String) return Target_Facts is
   begin
      if Name = "linux-x86-64" then
         return Linux_X86_64;
      elsif Name = "linux-arm64" then
         return Linux_Arm64;
      elsif Name = "darwin-arm64" then
         return Darwin_Arm64;
      elsif Name = "cortex-m0" then
         return Cortex_M;
      elsif Name = "synthetic-32" then
         return Synthetic_32;
      else
         raise Compiler_Defect with "no target is described as " & Name;
      end if;
   end Described;

   --  A GNU triplet is machine-vendor-system, the vendor optional, and the
   --  system may carry a release: x86_64-pc-linux-gnu, aarch64-linux-gnu,
   --  aarch64-apple-darwin24.6.0.
   function Machine_Of (Triplet : String) return String is
     (Triplet (Triplet'First
               .. (if Ada.Strings.Fixed.Index (Triplet, "-") = 0
                   then Triplet'Last
                   else Ada.Strings.Fixed.Index (Triplet, "-") - 1)));

   function Contains (Text, Part : String) return Boolean
     is (Ada.Strings.Fixed.Index (Text, Part) /= 0);

   function Is_Linux (Triplet : String) return Boolean
     is (Contains (Triplet, "-linux-gnu"));

   function Is_Darwin (Triplet : String) return Boolean
     is (Contains (Triplet, "-darwin"));

   function Has_Host_Default (Triplet : String) return Boolean
     is ((Machine_Of (Triplet) = "x86_64" and then Is_Linux (Triplet))
         or else (Machine_Of (Triplet) = "aarch64"
                  and then (Is_Linux (Triplet) or else Is_Darwin (Triplet))));

   function Host_Default (Triplet : String) return Target_Facts is
   begin
      if Machine_Of (Triplet) = "x86_64" and then Is_Linux (Triplet) then
         return Linux_X86_64;
      elsif Machine_Of (Triplet) = "aarch64" and then Is_Linux (Triplet) then
         return Linux_Arm64;
      elsif Machine_Of (Triplet) = "aarch64" and then Is_Darwin (Triplet)
      then
         return Darwin_Arm64;
      else
         raise Compiler_Defect
           with "no target describes a compiler built for " & Triplet;
      end if;
   end Host_Default;

   function Build_Triplet return String is (Standard'Target_Name);

end Landin.Targets.Selection;
