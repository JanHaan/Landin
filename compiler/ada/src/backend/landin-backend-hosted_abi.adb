package body Landin.Backend.Hosted_ABI is

   function Errno_Function (System : Hosted_System) return String is
   begin
      case System is
         when Linux =>
            return "__errno_location";
         when Darwin =>
            return "__error";
         when No_Hosted_System =>
            raise Compiler_Defect with "a freestanding target has no errno";
      end case;
   end Errno_Function;

   --  Linux's generic values, O_WRONLY 1, O_CREAT 8#100#, O_TRUNC 8#1000#;
   --  Darwin's BSD ones, O_WRONLY 1, O_CREAT 16#200#, O_TRUNC 16#400#.
   function Create_For_Writing (System : Hosted_System) return Natural is
   begin
      case System is
         when Linux =>
            return 1 + 8#100# + 8#1000#;
         when Darwin =>
            return 1 + 16#200# + 16#400#;
         when No_Hosted_System =>
            raise Compiler_Defect
              with "a freestanding target has no open flags";
      end case;
   end Create_For_Writing;

end Landin.Backend.Hosted_ABI;
