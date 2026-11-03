with Ada.Strings.Fixed;

package body Landin.Targets.Selection is

   function Described_Name (Index : Positive) return String is
     (case Index is
         when 1 => "linux-x86-64", when 2 => "linux-arm64",
         when 3 => "darwin-arm64", when 4 => "freebsd-x86-64",
         when 5 => "freebsd-arm64", when 6 => "linux-rv64",
         when 7 => "cortex-m0", when 8 => "rv32", when 9 => "synthetic-32",
         when others => raise Compiler_Defect);

   function Described_At (Index : Positive) return Target_Facts is
     (case Index is
         when 1 => Linux_X86_64, when 2 => Linux_Arm64,
         when 3 => Darwin_Arm64, when 4 => FreeBSD_X86_64,
         when 5 => FreeBSD_Arm64, when 6 => Linux_RV64,
         when 7 => Cortex_M, when 8 => RV32, when 9 => Synthetic_32,
         when others => raise Compiler_Defect);

   function Is_Described (Name : String) return Boolean is
     (for some Index in 1 .. Described_Count => Described_Name (Index) = Name);

   function Described (Name : String) return Target_Facts is
   begin
      for Index in 1 .. Described_Count loop
         if Described_Name (Index) = Name then
            return Described_At (Index);
         end if;
      end loop;
      raise Compiler_Defect with "no target is described as " & Name;
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
