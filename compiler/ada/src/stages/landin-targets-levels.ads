--  CPU feature levels.
--
--  A level is what a build assumes the processor executes, beside the
--  description of the machine it lays data out for.  It is a separate value
--  rather than a field of Target_Facts, so that comparing descriptions keeps
--  meaning "which backend, which ABI": every level of a family shares one
--  layout, one calling convention and one C ABI, and code built at two
--  levels of one family links together.  Layout and type checking do not
--  depend on a level; configuration, Cortex assembly text validation,
--  emission and the toolchain can use it.
--
--  A level's features are a set rather than a rank.  The x86-64 levels of
--  the psABI happen to nest, but ARMv8-M's baseline lacks what ARMv7-M has,
--  and RISC-V's extensions combine freely.  A feature of another family is
--  never held, so a program may ask for one without asking for the
--  architecture first.
--
--  Each level is named as the platform's own documents name it: the psABI's
--  `x86-64-v2`, and Arm's and GCC's `armv8.1-a` and `armv7-m`.

package Landin.Targets.Levels is

   type Feature is
     (
      --  x86-64-v2
      Cmpxchg16b, Lahf, Popcnt, Sse3, Ssse3, Sse4_1, Sse4_2,
      --  x86-64-v3
      Avx, Avx2, Bmi1, Bmi2, F16c, Fma, Lzcnt, Movbe, Xsave,
      --  x86-64-v4
      Avx512f, Avx512bw, Avx512cd, Avx512dq, Avx512vl,
      --  Armv8.1-A
      Lse, Crc32, Rdm,
      --  Armv7-M and Armv7E-M
      Thumb2, Idiv, Dsp,
      --  RV64GC and independent address-generation extensions
      I, M, A, F, D, C, Zicsr, Zifencei, Zba, Xtheadba);

   --  The word a program writes after `compiler.feature.`.
   function Spelling (Of_Feature : Feature) return String;

   function Is_Feature_Name (Name : String) return Boolean;

   function Feature_Named (Name : String) return Feature
     with Pre => Is_Feature_Name (Name);

   type Feature_Level is private;

   --  The level a build assumes when none is selected, which is the one
   --  every backend emitted for before levels existed.
   function Default_Level (Facts : Target_Facts) return Feature_Level;

   --  Whether NAME is a level of the family FACTS describes.  A described
   --  target with only one level, which synthetic-32 is, has none to select.
   function Is_Level_Of (Facts : Target_Facts; Name : String) return Boolean;

   function Level_Named
     (Facts : Target_Facts; Name : String) return Feature_Level
     with Pre => Is_Level_Of (Facts, Name);

   --  Every level FACTS can select, in declaration order, comma separated.
   function Levels_Of (Facts : Target_Facts) return String;

   function Name (Level : Feature_Level) return String;

   function Has (Level : Feature_Level; Wanted : Feature) return Boolean;

   function Belongs_To
     (Level : Feature_Level; Facts : Target_Facts) return Boolean;

private

   type Level_Id is
     (No_Level,
      X86_64_V1, X86_64_V2, X86_64_V3, X86_64_V4,
      Armv8_A, Armv8_1_A,
      Armv6_M, Armv7_M, Armv7E_M,
      RV64GC, RV64GC_Zba, RV64GC_Xtheadba, RV64GC_Zba_Xtheadba);

   type Feature_Level is record
      Id : Level_Id;
   end record;

end Landin.Targets.Levels;
