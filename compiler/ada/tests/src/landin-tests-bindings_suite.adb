--  `refine bindings`: C headers bound for Landin (D820, D821).
--
--  A fake Clang answers here: the target's triple and macros, the
--  preprocessed header, its JSON AST and the enum probe's answers, written
--  as the pinned Clang writes them.  The cases hold the target rows, the
--  refusal of another ABI before any header work, a whole binding through
--  the fake host with every Clang run in an environment of its own, each
--  request and output refusal by its code, and a replacement that fails
--  after each of its moves putting every output back.  What the real
--  Clang makes of real headers is `bindings/test.py`'s.

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Bindings;
with Landin.Commands;
with Landin.Driver;
with Landin.Platform;
with Landin.Testing.Fakes;

package body Landin.Tests.Bindings_Suite is

   package US renames Ada.Strings.Unbounded;
   package B renames Landin.Bindings;

   LF : constant Character := ASCII.LF;

   function Contains (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) /= 0);

   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   Work : constant String := "/virtual/tmp/refine-bindings-1";
   Root : constant String := "/virtual/compile";

   Header : constant String :=
     "typedef enum Mode { MODE_A = 1, MODE_B } Mode;" & LF
     & "enum { FIRST = -1 };" & LF
     & "int twice(int value);" & LF;

   Anonymous_Offset : constant Natural :=
     Ada.Strings.Fixed.Index (Header, "enum {") - Header'First;

   Policy : constant String :=
     "{""schema_version"": 1, ""namespace"": ""fake"", ""abi"": "
     & "{""target"": ""x86_64-pc-linux-gnu"", ""data_model"": ""lp64"", "
     & """plain_char"": ""signed"", ""enum_policy"": ""clang-default""}, "
     & """declarations"": ["
     & "{""kind"": ""enum"", ""name"": ""Mode""}, "
     & "{""kind"": ""enum"", ""name"": ""@FIRST"", "
     & """landin_name"": ""first_enum""}, "
     & "{""kind"": ""function"", ""name"": ""twice"", "
     & """direction"": ""import"", ""parameters"": {}}]}";

   --  Clang's AST of Header, as `-ast-dump=json` writes it, without the
   --  members nothing reads.
   Ast : constant String :=
     "{""id"":""0x1"",""kind"":""TranslationUnitDecl"",""inner"":["
     & "{""id"":""0x10"",""kind"":""EnumDecl"",""loc"":{""offset"":8},"
     & """name"":""Mode"",""inner"":["
     & "{""id"":""0x11"",""kind"":""EnumConstantDecl"",""name"":""MODE_A"","
     & """type"":{""qualType"":""int""},""inner"":[{""id"":""0x12"","
     & """kind"":""ConstantExpr"",""value"":""1""}]},"
     & "{""id"":""0x13"",""kind"":""EnumConstantDecl"",""name"":""MODE_B"","
     & """type"":{""qualType"":""int""}}]},"
     & "{""id"":""0x20"",""kind"":""TypedefDecl"",""name"":""Mode"","
     & """type"":{""qualType"":""enum Mode""},""inner"":[{""id"":""0x21"","
     & """kind"":""ElaboratedType"",""type"":{""qualType"":""enum Mode""},"
     & """ownedTagDecl"":{""id"":""0x10"",""kind"":""EnumDecl"","
     & """name"":""Mode""},""inner"":[{""id"":""0x22"",""kind"":""EnumType"","
     & """type"":{""qualType"":""enum Mode""},""decl"":{""id"":""0x10"","
     & """kind"":""EnumDecl"",""name"":""Mode""}}]}]},"
     & "{""id"":""0x30"",""kind"":""EnumDecl"",""loc"":{""offset"":"
     & Image (Anonymous_Offset) & "},""inner"":["
     & "{""id"":""0x31"",""kind"":""EnumConstantDecl"",""name"":""FIRST"","
     & """type"":{""qualType"":""int""},""inner"":[{""id"":""0x32"","
     & """kind"":""ConstantExpr"",""value"":""-1""}]}]},"
     & "{""id"":""0x40"",""kind"":""FunctionDecl"",""name"":""twice"","
     & """type"":{""qualType"":""int (int)""},""inner"":["
     & "{""id"":""0x41"",""kind"":""ParmVarDecl"",""name"":""value"","
     & """type"":{""qualType"":""int""}}]}]}";

   --  The probe's answers: the anonymous enum's type is the sixth
   --  candidate, int, and Mode's the seventh, unsigned int.
   Probe_Answers : constant String :=
     "{""id"":""0x9"",""kind"":""EnumConstantDecl"","
     & """name"":""landin_enum_probe_type_0"",""inner"":[{""id"":""0xa"","
     & """kind"":""ConstantExpr"",""value"":""6""}]}" & LF
     & "{""id"":""0xb"",""kind"":""EnumConstantDecl"","
     & """name"":""landin_enum_probe_type_1"",""inner"":[{""id"":""0xc"","
     & """kind"":""ConstantExpr"",""value"":""7""}]}" & LF;

   function Macros (Unsigned_Char : Boolean; Arm : Boolean := False)
     return String is
     ("#define __LP64__ 1" & LF & "#define __CHAR_BIT__ 8" & LF
      & "#define __SIZEOF_SHORT__ 2" & LF & "#define __SIZEOF_INT__ 4" & LF
      & "#define __SIZEOF_LONG__ 8" & LF & "#define __SIZEOF_LONG_LONG__ 8"
      & LF & "#define __SIZEOF_POINTER__ 8" & LF
      & "#define __SIZEOF_SIZE_T__ 8" & LF
      & "#define __SIZEOF_PTRDIFF_T__ 8" & LF
      & "#define __SIZEOF_FLOAT__ 4" & LF & "#define __SIZEOF_DOUBLE__ 8"
      & LF & "#define __FLT_RADIX__ 2" & LF & "#define __FLT_MANT_DIG__ 24"
      & LF & "#define __DBL_MANT_DIG__ 53" & LF
      & (if Arm then "#define __aarch64__ 1" else "#define __x86_64__ 1")
      & LF & "#define __linux__ 1" & LF & "#define __ELF__ 1" & LF
      & "#define __ORDER_LITTLE_ENDIAN__ 1234" & LF
      & "#define __BYTE_ORDER__ __ORDER_LITTLE_ENDIAN__" & LF
      & (if Unsigned_Char then "#define __CHAR_UNSIGNED__ 1" & LF else ""));

   function Preprocessed
     (Extra_Marker : String := ""; Directory : String := Work) return String
   is ("# 1 """ & Directory & "/translation.c""" & LF
       & "# 1 ""<built-in>"" 1" & LF
       & "# 1 """ & Directory & "/headers/api/api.h"" 1" & LF
       & Extra_Marker & Header);

   Arguments : constant Landin.Platform.Path_List :=
     ["bindings", "--clang=clang-19", "--target=linux-x86-64",
      "--sysroot=sysroot", "--policy=policy.json", "--out-dir=out",
      "--system-include-dir=include", "api/api.h=api.h"];

   procedure Prepare (Host : in out Landin.Testing.Fakes.Fake_Filesystem);

   procedure Prepare (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
   begin
      Host.Add_File (Root & "/api.h", Header);
      Host.Add_File (Root & "/policy.json", Policy);
      Host.Add_Directory (Root & "/sysroot");
      Host.Add_Directory (Root & "/include");
   end Prepare;

   --  Every answer a binding of Header asks the fake Clang for, in order.
   procedure Script
     (Tools : in out Landin.Testing.Fakes.Fake_Tool_Runner;
      Directory : String := Work);

   --  Directory is the private directory the run's Clang works in: the
   --  fake host's first is Work, and its second ends in 2.
   procedure Script
     (Tools : in out Landin.Testing.Fakes.Fake_Tool_Runner;
      Directory : String := Work) is
   begin
      Tools.Add_Result (0, "x86_64-pc-linux-gnu" & LF);
      Tools.Add_Result (0, Macros (Unsigned_Char => False));
      Tools.Add_Result (0, Preprocessed (Directory => Directory));
      Tools.Add_Result (0, Ast);
      Tools.Add_Result (0, Probe_Answers);
      Tools.Add_Result
        (0, "refine-bindings: " & Directory & "/output/adapters.c "
         & Directory & "/headers/api/api.h" & LF);
   end Script;

   function Report_Of (Result : Landin.Driver.Outcome) return String is
     (US.To_String (Result.Report));

   --  What Path holds now, or "".
   function Content_Of
     (Host : Landin.Testing.Fakes.Fake_Filesystem; Path : String)
      return String;

   function Content_Of
     (Host : Landin.Testing.Fakes.Fake_Filesystem; Path : String)
      return String
   is
      Content : US.Unbounded_String;
      Read : Landin.Platform.Read_Status;
   begin
      Host.Read_File (Path, Content, Read);
      return US.To_String (Content);
   end Content_Of;

   procedure Each_Target_Is_One_Row (Item : in out Landin.Testing.Context);

   --  D256: the standard AAPCS64's plain char is unsigned, and its
   --  bindings assert their own fact rather than Darwin's.
   procedure Each_Target_Is_One_Row (Item : in out Landin.Testing.Context)
   is
   begin
      Landin.Testing.Check_Equal
        (Item, B.Triple (B.Linux_Arm64) & " " & B.Fact (B.Linux_Arm64) & " "
         & B.Convention (B.Linux_Arm64),
         "aarch64-unknown-linux-gnu c_aapcs64_lp64 aapcs64",
         "the Linux arm64 row");
      Landin.Testing.Check
        (Item, B.Unsigned_Char (B.Linux_Arm64)
         and then not B.Unsigned_Char (B.Linux_X86_64)
         and then not B.Unsigned_Char (B.Darwin_Arm64),
         "only the standard AAPCS64's plain char is unsigned");
      Landin.Testing.Check_Equal
        (Item, B.Fact (B.Linux_X86_64) & " " & B.Fact (B.Darwin_Arm64),
         "c_sysv_lp64 c_darwin_lp64", "each row asserts its own fact");
      Landin.Testing.Check_Equal
        (Item, B.Triple (B.Darwin_Arm64) & " "
          & B.Target_Name (B.Darwin_Arm64),
         "arm64-apple-macos26.0.0 darwin-arm64", "the Darwin row");
   end Each_Target_Is_One_Row;

   procedure Plain_Char_Must_Be_The_Rows
     (Item : in out Landin.Testing.Context);

   --  A Clang that disagrees with the row about char describes another
   --  ABI.
   procedure Plain_Char_Must_Be_The_Rows
     (Item : in out Landin.Testing.Context)
   is
      Arm_Policy : constant String :=
        Ada.Strings.Fixed.Replace_Slice
          (Policy, Ada.Strings.Fixed.Index (Policy, "x86_64-pc-linux-gnu"),
           Ada.Strings.Fixed.Index (Policy, "x86_64-pc-linux-gnu") + 18,
           "aarch64-unknown-linux-gnu");
      Unsigned_Policy : constant String :=
        Ada.Strings.Fixed.Replace_Slice
          (Arm_Policy, Ada.Strings.Fixed.Index (Arm_Policy, """signed"""),
           Ada.Strings.Fixed.Index (Arm_Policy, """signed""") + 7,
           """unsigned""");
   begin
      for Unsigned in Boolean loop
         declare
            Session : B.Session;
         begin
            B.Load_Policy (Session, Unsigned_Policy);
            B.Check_Triple
              (Session, B.Linux_Arm64, "aarch64-unknown-linux-gnu" & LF);
            B.Check_Macros
              (Session, B.Linux_Arm64,
               Macros (Unsigned_Char => Unsigned, Arm => True));
            if Unsigned then
               Landin.Testing.Check
                 (Item, B.Ok (Session),
                  "an unsigned plain char is the row's: "
                    & B.Message (Session));
            else
               Landin.Testing.Check
                 (Item, not B.Ok (Session)
                  and then B.Message (Session)
                           = "unsupported Clang target ABI: plain char is"
                             & " signed",
                  "a signed plain char is another ABI: "
                  & B.Message (Session));
            end if;
         end;
      end loop;
      declare
         Session : B.Session;
      begin
         B.Load_Policy (Session, Arm_Policy);
         Landin.Testing.Check
           (Item, not B.Ok (Session)
            and then B.Message (Session)
                     = "policy abi: plain_char must be 'unsigned', got"
                       & " 'signed'",
            "a policy's plain char must be its target's: "
            & B.Message (Session));
      end;
   end Plain_Char_Must_Be_The_Rows;

   procedure Another_Triple_Is_Refused_First
     (Item : in out Landin.Testing.Context);

   procedure Another_Triple_Is_Refused_First
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
   begin
      Prepare (Host);
      Tools.Add_Result (0, "arm64-apple-macosx26.0.0" & LF);
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (Arguments, Host, Tools, Meter);
      begin
         Landin.Testing.Check
           (Item, Result.Status = Landin.Driver.Status_Reported
            and then Contains
              (Report_Of (Result),
               "error[L0580]: Clang selected target"
               & " 'arm64-apple-macosx26.0.0'; required"
               & " 'x86_64-pc-linux-gnu'"),
            "another triple is refused: " & Report_Of (Result));
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 1, "before the macros are asked");
         Landin.Testing.Check
           (Item, not Host.Exists (Root & "/out/bindings.ldn")
            and then not Host.Exists (Work),
            "nothing is written and the work directory is gone");
      end;
   end Another_Triple_Is_Refused_First;

   procedure A_Header_Is_Bound (Item : in out Landin.Testing.Context);

   procedure A_Header_Is_Bound (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Meter : Landin.Platform.Unmetered;
      Environment : constant Landin.Platform.Path_List :=
        ["PATH", "HOME", "TMPDIR", "TMP", "TEMP", "SystemRoot", "LC_ALL=C",
         "TZ=UTC"];
   begin
      declare
         Files : Landin.Platform.Path_List;
         Valid : Boolean;
      begin
         B.Dependency_Files
           ("refine-bindings: /one\ two.h /dollar$$.h \" & LF
            & " /hash\#.h /slash\\.h" & LF, Files, Valid);
         Landin.Testing.Check
           (Item, Valid and then Landin.Platform.Path_Vectors."="
              (Files, ["/one two.h", "/dollar$.h", "/hash#.h", "/slash\.h"]),
            "Clang dependency filenames retain escaped physical spellings");
         Landin.Testing.Check
           (Item, Landin.Platform.Path_Vectors."="
              (B.Marker_Files (Preprocessed),
               [Work & "/translation.c", Work & "/headers/api/api.h"]),
            "marker closure excludes synthetic built-in files");
      end;
      Prepare (Host);
      Script (Tools);
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (Arguments, Host, Tools, Meter);
         Bindings : constant String :=
           Content_Of (Host, Root & "/out/bindings.ldn");
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, 0, "bound: " & Report_Of (Result));
         Landin.Testing.Check_Equal
           (Item, US.To_String (Result.Output),
            "refine bindings: 4 files under " & Root & "/out, 4 of them"
            & " written" & LF, "says what it wrote");
         Landin.Testing.Check
           (Item, Contains (Bindings, "compiler.assert(compiler.c_sysv_lp64)")
            and then Contains
              (Bindings, "public first_enum: type = c.c_int" & LF
               & "public first: first_enum = -1")
            and then Contains
              (Bindings, "public mode: type = c.c_uint" & LF
               & "public mode_a: mode = 1" & LF & "public mode_b: mode = 2")
            and then Contains
              (Bindings, "public extern(c) link(symbol: ""twice"") twice:"
               & " (value: c.c_int) -> (result: c.c_int)"),
            "the enums, from the probe's answers, and the function: "
            & Bindings);
         Landin.Testing.Check
           (Item, Contains
              (Content_Of (Host, Root & "/out/adapters.c"),
               "_Static_assert(__builtin_types_compatible_p(Mode, unsigned"
               & " int)")
            and then Contains
              (Content_Of (Host, Root & "/out/exports.h"),
               "#include ""api/api.h""")
            and then Contains
              (Content_Of (Host, Root & "/out/bindings.json"),
               """name"": ""api/api.h"""),
            "the adapters, the exports and the metadata");
         Landin.Testing.Check
           (Item, Contains
              (Host.Written (Work & "/enum-probe.i"),
               "enum landin_enum_probe_tag_0 { FIRST = -1 };")
            and then Contains
              (Host.Written (Work & "/enum-probe.i"),
               "enum { landin_enum_probe_type_1 = 1 *"
               & " __builtin_types_compatible_p(Mode, char) + 2 *")
            and then not Contains
              (Host.Written (Work & "/translation.i"), "# 1"),
            "the probe tags the anonymous enum in the markerless text");
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 6, "six questions are asked of Clang");
         for Index in 1 .. Tools.Run_Count loop
            declare
               Call : constant Landin.Testing.Fakes.Tool_Call :=
                 Tools.Call_At (Index);
            begin
               Landin.Testing.Check
                 (Item, Call.Isolated
                  and then Landin.Platform.Path_Vectors."="
                    (Call.Environment, Environment)
                  and then US.To_String (Call.Program) = "clang-19"
                  and then Call.Arguments.Contains ("-nostdinc")
                  and then Call.Arguments.Contains ("--no-default-config")
                  and then Call.Arguments.Contains
                    ("--target=x86_64-pc-linux-gnu")
                  and then Call.Arguments.Contains
                    ("-ffile-prefix-map=" & Work & "=."),
                  "Clang run" & Natural'Image (Index)
                  & " has its own environment and roots");
            end;
         end loop;
         Landin.Testing.Check
           (Item, Tools.Call_At (5).Arguments.Contains
              ("-ast-dump-filter=landin_enum_probe_type_")
            and then Tools.Call_At (6).Arguments.Contains ("-Werror")
            and then Tools.Call_At (6).Arguments.Contains
              (Work & "/output/adapters.c"),
            "the probe is filtered and the adapters are compiled");
         Landin.Testing.Check
           (Item, not Host.Exists (Work)
            and then not Host.Exists (Root & "/out/bindings.ldn.refine-new"),
            "nothing staged or temporary is left");
      end;
      Script (Tools, "/virtual/tmp/refine-bindings-2");
      declare
         Again : constant Landin.Driver.Outcome :=
           Landin.Commands.Execute (Arguments, Host, Tools, Meter);
      begin
         Landin.Testing.Check
           (Item, Again.Status = 0
            and then Contains (US.To_String (Again.Output),
                               "0 of them written"),
            "an unchanged output is left alone: " & Report_Of (Again));
      end;
   end A_Header_Is_Bound;

   procedure Requests_Are_Refused_By_Code
     (Item : in out Landin.Testing.Context);

   procedure Requests_Are_Refused_By_Code
     (Item : in out Landin.Testing.Context)
   is
      Meter : Landin.Platform.Unmetered;

      procedure Expect
        (Asked : Landin.Platform.Path_List; Code, Words : String;
         Policy_Text : String := Policy; Marker : String := "";
         Arrange : access procedure
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) := null);

      procedure Expect
        (Asked : Landin.Platform.Path_List; Code, Words : String;
         Policy_Text : String := Policy; Marker : String := "";
         Arrange : access procedure
           (Host : in out Landin.Testing.Fakes.Fake_Filesystem) := null)
      is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      begin
         Host.Add_File (Root & "/api.h", Header);
         Host.Add_File (Root & "/policy.json", Policy_Text);
         Host.Add_Directory (Root & "/sysroot");
         Host.Add_Directory (Root & "/include");
         if Arrange /= null then
            Arrange (Host);
         end if;
         Tools.Add_Result (0, "x86_64-pc-linux-gnu" & LF);
         Tools.Add_Result (0, Macros (Unsigned_Char => False));
         Tools.Add_Result (0, Preprocessed (Marker));
         Tools.Add_Result (0, Ast);
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Commands.Execute (Asked, Host, Tools, Meter);
         begin
            Landin.Testing.Check
              (Item, Result.Status /= 0
               and then Contains (Report_Of (Result), "error[" & Code & "]")
               and then Contains (Report_Of (Result), Words)
               and then not Host.Exists (Root & "/out/bindings.ldn"),
               Code & " " & Words & ": " & Report_Of (Result));
         end;
      end Expect;

      function With_Header (Operand : String) return Landin.Platform.Path_List;

      function With_Header (Operand : String) return Landin.Platform.Path_List
      is
         Result : Landin.Platform.Path_List := Arguments;
      begin
         Result.Replace_Element (Result.Last_Index, Operand);
         return Result;
      end With_Header;

      procedure Link_Out (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
      procedure Link_Out (Host : in out Landin.Testing.Fakes.Fake_Filesystem)
      is
      begin
         Host.Add_Directory (Root & "/out");
         Host.Add_Link (Root & "/out");
      end Link_Out;

      procedure Directory_In_The_Way
        (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
      procedure Directory_In_The_Way
        (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
      begin
         Host.Add_Directory (Root & "/out/adapters.c");
      end Directory_In_The_Way;

      procedure Leftover (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
      procedure Leftover (Host : in out Landin.Testing.Fakes.Fake_Filesystem)
      is
      begin
         Host.Add_File (Root & "/out/exports.h.refine-old", "");
      end Leftover;

      procedure Linked_Leftover
        (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
      procedure Linked_Leftover
        (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
      begin
         Host.Add_Link (Root & "/out/bindings.ldn.refine-new");
      end Linked_Leftover;

      procedure Input_Alias
        (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
      procedure Input_Alias
        (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
      begin
         Host.Add_File (Root & "/out/exports.h", Header);
         Host.Add_Alias (Root & "/out/exports.h", Root & "/api.h");
      end Input_Alias;

      procedure No_Sysroot
        (Host : in out Landin.Testing.Fakes.Fake_Filesystem);
      procedure No_Sysroot
        (Host : in out Landin.Testing.Fakes.Fake_Filesystem) is
      begin
         Host.Add_File (Root & "/sysroot.h", "");
      end No_Sysroot;

      Stale : constant String :=
        Ada.Strings.Fixed.Replace_Slice
          (Policy, Ada.Strings.Fixed.Index (Policy, """twice"""),
           Ada.Strings.Fixed.Index (Policy, """twice""") + 6,
           """gone""");

      Twice_Key : constant String :=
        Ada.Strings.Fixed.Replace_Slice
          (Policy, Ada.Strings.Fixed.Index (Policy, """namespace"""),
           Ada.Strings.Fixed.Index (Policy, """namespace""") - 1,
           """namespace"": ""again"", ");
   begin
      Expect (With_Header ("../api.h=api.h"), "L0002",
              "a header's logical name must be a canonical relative include"
              & " path, got '../api.h'");
      Expect (With_Header ("api.h=missing.h"), "L0003",
              "the header 'missing.h' is not a regular file");
      Expect (["bindings", "--clang=clang-19", "--target=cortex-m0",
               "--sysroot=sysroot", "--policy=policy.json", "--out-dir=out",
               "api.h"], "L0002", "and --target names cortex-m0");
      Expect (Landin.Platform.Path_Vectors."&"
                (Arguments, String'("--define=1BAD")),
              "L0002",
              "--define is not NAME or NAME=VALUE: '1BAD'");
      Expect (Arguments, "L0579", "policy: duplicate JSON key 'namespace'",
              Policy_Text => Twice_Key);
      Expect (["bindings", "--clang=clang-19", "--target=linux-arm64",
               "--sysroot=sysroot", "--policy=policy.json", "--out-dir=out",
               "api.h"], "L0579",
              "the policy binds for x86_64-pc-linux-gnu, and --target names"
              & " linux-arm64");
      Expect (Arguments, "L0581",
              "policy declaration 3 (function 'gone'): selected function was"
              & " not found in Clang AST (stale policy)",
              Policy_Text => Stale);
      Expect (Arguments, "L0580",
              "unsupported path-sensitive preprocessing outside explicit"
              & " roots",
              Marker => "# 1 ""/elsewhere/leak.h"" 1" & LF);
      Expect (Arguments, "L0580",
              "relative header outside its private workspace",
              Marker => "# 1 ""../outside.h"" 1" & LF);
      Expect (Arguments, "L0580",
              "relative header outside its private workspace",
              Marker => "# 1 ""../sibling/../refine-bindings-1/"
                & "headers/api/api.h"" 1" & LF);
      Expect (["bindings", "--clang=clang-19", "--target=linux-x86-64",
               "--sysroot=sysroot.h", "--policy=policy.json",
               "--out-dir=out", "api.h"], "L0580",
              "--sysroot 'sysroot.h' is not a directory",
              Arrange => No_Sysroot'Access);
      Expect (Arguments, "L0582", "is a symbolic link",
              Arrange => Link_Out'Access);
      Expect (Arguments, "L0582",
              "cannot publish adapters.c: existing output is not a regular"
              & " file", Arrange => Directory_In_The_Way'Access);
      Expect (Arguments, "L0582", "was left by an interrupted run of refine"
              & " bindings", Arrange => Leftover'Access);
      Expect (Arguments, "L0582", "was left by an interrupted run of refine"
              & " bindings", Arrange => Linked_Leftover'Access);
      Expect (Arguments, "L0582", "overlaps an input",
              Arrange => Input_Alias'Access);
   end Requests_Are_Refused_By_Code;

   procedure A_Failed_Replacement_Puts_Back
     (Item : in out Landin.Testing.Context);

   --  Fail each capture and installation in the shared group: every
   --  output is what it was before and all private staging is cleaned.
   procedure A_Failed_Replacement_Puts_Back
     (Item : in out Landin.Testing.Context)
   is
      Meter : Landin.Platform.Unmetered;
   begin
      for Existing in Boolean loop
         for At_Move in 1 .. 8 loop
            declare
               Host : Landin.Testing.Fakes.Fake_Filesystem;
               Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
               Label : constant String :=
                 (if Existing then "replacing" else "creating")
                 & ", move" & Natural'Image (At_Move);
            begin
               Prepare (Host);
               if Existing then
                  for Index in B.Output_Index loop
                     Host.Add_File (Root & "/out/" & B.Output_Name (Index),
                                    "old " & B.Output_Name (Index));
                  end loop;
               end if;
               Script (Tools);
               Host.Fail_Move (At_Move);
               declare
                  Result : constant Landin.Driver.Outcome :=
                    Landin.Commands.Execute (Arguments, Host, Tools, Meter);
               begin
                  Landin.Testing.Check
                    (Item, Result.Status = Landin.Driver.Status_Reported
                     and then Contains (Report_Of (Result), "error[L0005]"),
                     Label & ": " & Report_Of (Result));
                  for Index in B.Output_Index loop
                     declare
                        Path : constant String :=
                          Root & "/out/" & B.Output_Name (Index);
                        Content : US.Unbounded_String;
                        Read : Landin.Platform.Read_Status;
                        use type Landin.Platform.Read_Status;
                     begin
                        if Existing then
                           Host.Read_File (Path, Content, Read);
                           Landin.Testing.Check
                             (Item, Read = Landin.Platform.Read_Ok
                              and then US.To_String (Content)
                                       = "old " & B.Output_Name (Index),
                              Label & ": " & B.Output_Name (Index)
                              & " is the old one");
                        else
                           Landin.Testing.Check
                             (Item, not Host.Exists (Path),
                              Label & ": " & B.Output_Name (Index)
                              & " is not made");
                        end if;
                        Landin.Testing.Check
                          (Item, not Host.Exists (Path & ".refine-new")
                           and then not Host.Exists (Path & ".refine-old"),
                           Label & ": nothing of " & B.Output_Name (Index)
                           & " is left beside it");
                     end;
                  end loop;
               end;
            end;
         end loop;
      end loop;
   end A_Failed_Replacement_Puts_Back;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "bindings", "each target is one row",
         Each_Target_Is_One_Row'Access);
      Landin.Testing.Register
        (Into, "bindings", "plain char must be the row's",
         Plain_Char_Must_Be_The_Rows'Access);
      Landin.Testing.Register
        (Into, "bindings", "another triple is refused first",
         Another_Triple_Is_Refused_First'Access);
      Landin.Testing.Register
        (Into, "bindings", "a header is bound through a fake clang",
         A_Header_Is_Bound'Access);
      Landin.Testing.Register
        (Into, "bindings", "requests are refused by code",
         Requests_Are_Refused_By_Code'Access);
      Landin.Testing.Register
        (Into, "bindings", "a failed replacement puts back",
         A_Failed_Replacement_Puts_Back'Access);
   end Register;

end Landin.Tests.Bindings_Suite;
