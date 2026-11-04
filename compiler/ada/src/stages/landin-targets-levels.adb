with Ada.Strings.Unbounded;
with Landin.Targets.RiscV_ISA;

package body Landin.Targets.Levels is

   subtype X86_64_Level is Level_Id range X86_64_V1 .. X86_64_V4;
   subtype Arm64_Level is Level_Id range Armv8_A .. Armv8_1_A;
   subtype M_Profile_Level is Level_Id range Armv6_M .. Armv8_M_Main;
   subtype RV64_Level is Level_Id range RV64GC .. RV64GC_Zba_Xtheadba;
   subtype RV32_Level is Level_Id range RV32IMC .. RV32IMAC;
   subtype RISC_V_Level is Level_Id range RV64GC .. RV32IMAC;
   subtype Xtensa_Level is Level_Id range Xtensa_ESP32 .. Xtensa_ESP32S3;

   function Spelling (Of_Feature : Feature) return String
     is (case Of_Feature is
            when Cmpxchg16b => "cmpxchg16b",
            when Lahf       => "lahf",
            when Popcnt     => "popcnt",
            when Sse3       => "sse3",
            when Ssse3      => "ssse3",
            when Sse4_1     => "sse4_1",
            when Sse4_2     => "sse4_2",
            when Avx        => "avx",
            when Avx2       => "avx2",
            when Bmi1       => "bmi1",
            when Bmi2       => "bmi2",
            when F16c       => "f16c",
            when Fma        => "fma",
            when Lzcnt      => "lzcnt",
            when Movbe      => "movbe",
            when Xsave      => "xsave",
            when Avx512f    => "avx512f",
            when Avx512bw   => "avx512bw",
            when Avx512cd   => "avx512cd",
            when Avx512dq   => "avx512dq",
            when Avx512vl   => "avx512vl",
            when Lse        => "lse",
            when Crc32      => "crc32",
            when Rdm        => "rdm",
            when Thumb2     => "thumb2",
            when Idiv       => "idiv",
            when Dsp        => "dsp",
            when I          => "i",
            when M          => "m",
            when A          => "a",
            when F          => "f",
            when D          => "d",
            when C          => "c",
            when Zicsr      => "zicsr",
            when Zifencei   => "zifencei",
            when Zba        => "zba",
            when Xtheadba   => "xtheadba",
            when Salt       => "salt");

   function Is_Feature_Name (Name : String) return Boolean
     is (for some Each in Feature => Spelling (Each) = Name);

   function Feature_Named (Name : String) return Feature is
   begin
      for Each in Feature loop
         if Spelling (Each) = Name then
            return Each;
         end if;
      end loop;
      raise Compiler_Defect with "no feature is spelled " & Name;
   end Feature_Named;

   function Default_Level (Facts : Target_Facts) return Feature_Level
     is ((Id => (case Architecture_Of (Facts) is
                    when X86_64 => X86_64_V1,
                    when Arm64 => Armv8_A,
                    when RV64 => RV64GC,
                    when Cortex_M0 => Armv6_M,
                    when RV32 => RV32IMC,
                    when Xtensa => Xtensa_ESP32,
                    when Synthetic_32_Architecture => No_Level)));

   function Spelled (Id : Level_Id) return String
     is (case Id is
            when No_Level  => "none",
            when X86_64_V1 => "x86-64-v1",
            when X86_64_V2 => "x86-64-v2",
            when X86_64_V3 => "x86-64-v3",
            when X86_64_V4 => "x86-64-v4",
            when Armv8_A   => "armv8-a",
            when Armv8_1_A => "armv8.1-a",
            when Armv6_M   => "armv6-m",
            when Armv7_M   => "armv7-m",
            when Armv7E_M  => "armv7e-m",
            when Armv8_M_Main => "armv8-m.main",
            when RV64GC => "rv64gc",
            when RV64GC_Zba => "rv64gc_zba",
            when RV64GC_Xtheadba => "rv64gc_xtheadba",
            when RV64GC_Zba_Xtheadba => "rv64gc_zba_xtheadba",
            when RV32IMC => "rv32imc",
            when RV32IMAC => "rv32imac",
            when Xtensa_ESP32 => "xtensa-esp32",
            when Xtensa_ESP32S3 => "xtensa-esp32s3");

   function In_Family (Id : Level_Id; Facts : Target_Facts) return Boolean
     is (case Architecture_Of (Facts) is
            when X86_64 => Id in X86_64_Level,
            when Arm64 => Id in Arm64_Level,
            when RV64 => Id in RV64_Level,
            when Cortex_M0 => Id in M_Profile_Level,
            when RV32 => Id in RV32_Level,
            when Xtensa => Id in Xtensa_Level,
            when Synthetic_32_Architecture => False);

   function Is_Level_Of (Facts : Target_Facts; Name : String) return Boolean
     is (for some Id in Level_Id =>
            In_Family (Id, Facts) and then Spelled (Id) = Name);

   function Level_Named
     (Facts : Target_Facts; Name : String) return Feature_Level is
   begin
      for Id in Level_Id loop
         if In_Family (Id, Facts) and then Spelled (Id) = Name then
            return (Id => Id);
         end if;
      end loop;
      raise Compiler_Defect with "no level of the target is named " & Name;
   end Level_Named;

   function Levels_Of (Facts : Target_Facts) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
   begin
      for Id in Level_Id loop
         if In_Family (Id, Facts) then
            if Ada.Strings.Unbounded.Length (Result) > 0 then
               Ada.Strings.Unbounded.Append (Result, ", ");
            end if;
            Ada.Strings.Unbounded.Append (Result, Spelled (Id));
         end if;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Levels_Of;

   function Family_Levels (Facts : Target_Facts) return Level_List is
      Result : Level_List (1 .. Level_Id'Pos (Level_Id'Last) + 1);
      Count  : Natural := 0;
   begin
      for Id in Level_Id loop
         if In_Family (Id, Facts) then
            Count := Count + 1;
            Result (Count) := (Id => Id);
         end if;
      end loop;
      return Result (1 .. Count);
   end Family_Levels;

   function Name (Level : Feature_Level) return String
     is (Spelled (Level.Id));

   function Has (Level : Feature_Level; Wanted : Feature) return Boolean is
   begin
      case Wanted is
         when Salt =>
            return Level.Id = Xtensa_ESP32S3;
         when Cmpxchg16b | Lahf | Popcnt | Sse3 | Ssse3 | Sse4_1 | Sse4_2 =>
            return Level.Id in X86_64_V2 .. X86_64_V4;
         when Avx | Avx2 | Bmi1 | Bmi2 | F16c | Fma | Lzcnt | Movbe
            | Xsave =>
            return Level.Id in X86_64_V3 .. X86_64_V4;
         when Avx512f | Avx512bw | Avx512cd | Avx512dq | Avx512vl =>
            return Level.Id = X86_64_V4;
         when Lse | Crc32 | Rdm =>
            return Level.Id = Armv8_1_A;
         when Thumb2 | Idiv =>
            return Level.Id in Armv7_M .. Armv8_M_Main;
         when Dsp =>
            return Level.Id = Armv7E_M;
         when I | M | A | F | D | C | Zicsr | Zifencei | Zba | Xtheadba =>
            return Level.Id in RISC_V_Level
              and then RiscV_ISA.Has
                (RiscV_ISA.Named (Name (Level)),
                 RiscV_ISA.Extension'Val
                   (Feature'Pos (Wanted) - Feature'Pos (I)));
      end case;
   end Has;

   function Belongs_To
     (Level : Feature_Level; Facts : Target_Facts) return Boolean
     is (Level = Default_Level (Facts) or else In_Family (Level.Id, Facts));

end Landin.Targets.Levels;
