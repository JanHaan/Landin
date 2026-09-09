with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with GNAT.SHA256;

with Landin.Build_Reports.Sources;
with Landin.Byte_Encoding;
with Landin.Driver;
with Landin.IR;
with Landin.Layouts;
with Landin.Optimization;
with Landin.Platform;
with Landin.Source;
with Landin.Source_Maps;
with Landin.Stages;
with Landin.Targets;
with Landin.Targets.Layouts;
with Landin.Testing.Fakes;

package body Landin.Tests.Host_Reports_Suite is
   package US renames Ada.Strings.Unbounded;
   package Reports renames Landin.Build_Reports;
   package Layout renames Landin.Targets.Layouts;
   use type Layout.Plan;
   use type Landin.Layouts.Policy;
   use type Landin.Targets.Byte_Count;

   LF : constant Character := Character'Val (10);
   Source : constant String :=
     "public main: () -> (code: i32) = code = 0 end main";

   procedure Byte_Encoding (Item : in out Landin.Testing.Context);
   procedure Adapter_Bytes (Item : in out Landin.Testing.Context);
   procedure Whole_Plans (Item : in out Landin.Testing.Context);
   procedure Refused_Plans (Item : in out Landin.Testing.Context);
   procedure Host_Identity (Item : in out Landin.Testing.Context);

   procedure Byte_Encoding (Item : in out Landin.Testing.Context) is
      Bytes : String (17 .. 272);
      Expected : String (1 .. 512);
      Hex_Digits : constant String := "0123456789abcdef";
   begin
      for High in 0 .. 15 loop
         for Low in 0 .. 15 loop
            declare
               Value : constant Natural := High * 16 + Low;
            begin
               Bytes (17 + Value) := Character'Val (Value);
               Expected (2 * Value + 1) := Hex_Digits (High + 1);
               Expected (2 * Value + 2) := Hex_Digits (Low + 1);
            end;
         end loop;
      end loop;
      Landin.Testing.Check_Equal
        (Item, Landin.Byte_Encoding.Hex (Bytes), Expected,
         "all 256 bytes survive a non-one-based string");
      Landin.Testing.Check_Equal
        (Item, Landin.Byte_Encoding.Hex (Bytes (17 .. 16)), "",
         "an empty slice stays empty");
      Landin.Testing.Check_Equal
        (Item, Landin.Byte_Encoding.Hex ("""" & LF & Character'Val (255)),
         "220aff", "quotes, newlines and non-UTF-8 bytes are not text");
      for Index in Bytes'Range loop
         Landin.Testing.Check_Equal
           (Item, Landin.Byte_Encoding.Hex (Bytes (Index .. Index)),
            Expected (2 * (Index - 17) + 1 .. 2 * (Index - 17) + 2),
            "every singleton slice has the same byte encoding");
      end loop;
   end Byte_Encoding;

   procedure Adapter_Bytes (Item : in out Landin.Testing.Context) is
      Context : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Path : constant String := "q""" & LF & Character'Val (255) & ".ldn";
      Id : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Context, Path, Source);
      Report : Reports.Report;
      Files : constant String := "    {""file_id"":"
        & Landin.Source.Source_Id'Image (Id)
        & ",""path_hex"":""71220aff2e6c646e"",""source_sha256"":"""
        & GNAT.SHA256.Digest (Source) & """}";
      Assembly : constant String := "# assembly" & LF;
      Build_Id : constant String := GNAT.SHA256.Digest
        ("Landin caller files" & LF & Files & LF & Assembly);
      Expected_Assembly : constant String :=
        Assembly & "# Landin caller files " & Build_Id & LF;
   begin
      Landin.IR.Note_Caller_Source (Landin.Stages.Code (Context).all, Id);
      declare
         Map : constant Landin.Source_Maps.Artifact :=
           Landin.Source_Maps.Create (Context, Assembly);
         JSON : constant String := Reports.Sources.JSON
           (Report, Context, Landin.Optimization.Reference_Options);
      begin
         Landin.Testing.Check_Equal
           (Item, US.To_String (Map.Assembly), Expected_Assembly,
            "shared encoding preserves the complete build identity");
         Landin.Testing.Check_Equal
           (Item, US.To_String (Map.JSON),
            "{" & LF & "  ""build_id"":""" & Build_Id & """," & LF
            & "  ""assembly_sha256"":"""
            & GNAT.SHA256.Digest (Expected_Assembly) & """," & LF
            & "  ""files"": [" & LF & Files & LF & "  ]" & LF & "}" & LF,
            "source-map JSON is unchanged byte for byte");
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index
              (JSON, """path_hex"":""71220aff2e6c646e""") > 0,
            "report uses exactly the same arbitrary filename bytes");
      end;
   end Adapter_Bytes;

   procedure Whole_Plans (Item : in out Landin.Testing.Context) is
      Report : Reports.Report;
   begin
      --  Vary the discriminant through container growth, including zero.
      --  Target-sized extents must not become host-sized metadata arrays.
      for Count in 0 .. 128 loop
         declare
            Fields : Layout.Field_Extent_Array (1 .. Count);
         begin
            for Index in Fields'Range loop
               Fields (Index) :=
                 (if Index mod 2 = 0 then (2 ** 40, 8) else (1, 1));
            end loop;
            declare
               Plan : constant Layout.Plan :=
                 Layout.Make (Fields, Landin.Layouts.Optimal);
            begin
               Reports.Append_Layout
                 (Report, Count + 1, Landin.Layouts.Optimal, Plan);
               Landin.Testing.Check
                 (Item, Reports.Layout_Plan (Report, Count + 1) = Plan
                  and then Reports.Layout_Position (Report, Count + 1)
                    = Count + 1
                  and then Reports.Layout_Policy (Report, Count + 1)
                    = Landin.Layouts.Optimal,
                  "the complete discriminated plan round trips");
            end;
         end;
      end loop;
      Landin.Testing.Check_Equal
        (Item, Reports.Layout_Count (Report), 129,
         "different plan counts coexist in insertion order");
      declare
         Empty : constant Layout.Plan := Layout.Make
           (Layout.Field_Extent_Array'(1 .. 0 => <>));
         Small : constant Layout.Plan := Layout.Make
           ([(1, 1), (8, 8), (1, 1), (8, 8)], Landin.Layouts.Optimal);
      begin
         Reports.Clear (Report);
         Reports.Append_Layout (Report, 1, Landin.Layouts.Natural, Empty);
         Reports.Append_Layout (Report, 3, Landin.Layouts.Optimal, Small);
         Landin.Testing.Check_Equal
           (Item, Reports.JSON (Report, Landin.Targets.Linux_X86_64,
                                Landin.Optimization.Reference_Options),
            "{""format"":""landin-build-report-1"","
            & """target"":""linux-x86-64"",""optimize"":""none"","
            & """specialize"":""off"",""specializations"": ["
            & "],""routines"": [],""layouts"": [" & LF
            & "{""nominal"":1,""policy"":""natural"",""size"":0,"
            & """alignment"":1,""natural_size"":0,""saved_bytes"":0,"
            & """order"": [],""offsets"": []},"
            & LF & "{""nominal"":3,""policy"":""optimal"",""size"":24,"
            & """alignment"":8,""natural_size"":32,""saved_bytes"":8,"
            & """order"": [2,4,1,3],""offsets"": [16,0,17,8]}]}" & LF,
            "representation cleanup preserves the original JSON bytes");
      end;
   end Whole_Plans;

   procedure Refused_Plans (Item : in out Landin.Testing.Context) is
      Report : Reports.Report;
      Good : constant Layout.Plan := Layout.Make ([(1, 1), (8, 8)]);
   begin
      Reports.Append_Layout (Report, 1, Landin.Layouts.Natural, Good);
      for Failure in 1 .. 7 loop
         declare
            Bad : Layout.Plan := Good;
            Position : Positive := 2;
            Before : constant String := Reports.JSON
              (Report, Landin.Targets.Linux_X86_64,
               Landin.Optimization.Reference_Options);
         begin
            case Failure is
               when 1 => Bad.Order (2) := Bad.Order (1);
               when 2 => Bad.Order (2) := Bad.Count + 1;
               when 3 => Bad.Size := Bad.Natural_Size + 1;
               when 4 => Bad.Saved_Bytes := 1;
               when 5 => Bad.Alignment := 3;
               when 6 => Bad.Offsets (2) := Bad.Size + 1;
               when 7 => Position := 1;
            end case;
            begin
               Reports.Append_Layout
                 (Report, Position, Landin.Layouts.Natural, Bad);
               Landin.Testing.Fail (Item, "invalid report plan was accepted");
            exception
               when Landin.Compiler_Defect => null;
            end;
            Landin.Testing.Check
              (Item, Reports.Layout_Count (Report) = 1
               and then Reports.Layout_Plan (Report, 1) = Good,
               "invalid placement leaves the stored plan untouched");
            Landin.Testing.Check_Equal
              (Item, Reports.JSON (Report, Landin.Targets.Linux_X86_64,
                                   Landin.Optimization.Reference_Options),
               Before, "refusal leaves all report bytes untouched");
         end;
      end loop;
   end Refused_Plans;

   procedure Host_Identity (Item : in out Landin.Testing.Context) is
      procedure Compile
        (Input, Output, Report : String; Alias : String := "";
         Executable : Boolean := False; Many : Boolean := False);

      procedure Compile
        (Input, Output, Report : String; Alias : String := "";
         Executable : Boolean := False; Many : Boolean := False)
      is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List;
         Result : Landin.Driver.Outcome;
      begin
         Host.Add_File (Input, Source);
         Args.Append (Input);
         if Many then
            for Index in 1 .. 64 loop
               declare
                  Name : constant String := "f" & Ada.Strings.Fixed.Trim
                    (Index'Image, Ada.Strings.Both);
               begin
                  Host.Add_File (Name & ".ldn",
                                 Name & ": () -> none = end " & Name);
                  Args.Append (Name & ".ldn");
               end;
            end loop;
         end if;
         if Alias /= "" then
            Host.Add_Alias (Report, Alias);
         end if;
         Args.Append (if Executable then "--emit=exe" else "--emit=asm");
         Args.Append ("-o");
         Args.Append (Output);
         Args.Append ("--build-report=" & Report);
         Result := Landin.Driver.Execute (Args, Host, Tools);
         Landin.Testing.Check_Equal
           (Item, Result.Status,
            (if Alias = "" then 0 else Landin.Driver.Status_Misuse),
            "only the host decides whether these destinations overlap");
         if Alias /= "" then
            Landin.Testing.Check
              (Item, Host.Write_Count = 0 and then Tools.Run_Count = 0,
               "every collision is refused before any write or tool");
         else
            Landin.Testing.Check
              (Item, Host.Written (Output) /= ""
               and then Host.Written (Report) /= "",
               "proven distinct paths produce both artifacts");
         end if;
      end Compile;
   begin
      Compile ("a/main.ldn", "out.s", "a/link/../main.ldn");
      Compile ("main.ldn", "a/out.s", "a/link/../out.s");
      Compile ("main.ldn", "OUT.s", "out.s");
      Compile ("main.ldn", "out.s", "./out.s", Alias => "out.s");
      Compile ("main.ldn", "out.s", "a/../main.ldn", Alias => "main.ldn");
      Compile ("app/main.ldn", "out.s", "./app//main.ldn",
               Alias => "app/main.ldn");
      Compile ("main.ldn", "OUT.s", "out.s", Alias => "OUT.s");
      Compile ("main.ldn", "PROGRAM", "program", Alias => "PROGRAM",
               Executable => True);
      Compile ("main.ldn", "PROGRAM", "program.s", Alias => "PROGRAM.s",
               Executable => True);
      Compile ("main.ldn", "PROGRAM", "program.sources.json",
               Alias => "PROGRAM.sources.json", Executable => True);
      Compile ("main.ldn", "out.s", "MAIN.ldn", Alias => "main.ldn");
      Compile ("main.ldn", "out.s", "last.json", Alias => "f64.ldn",
               Many => True);
   end Host_Identity;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "host reports", "all byte values and slices",
         Byte_Encoding'Access);
      Landin.Testing.Register
        (Into, "host reports", "source adapters preserve JSON and build ids",
         Adapter_Bytes'Access);
      Landin.Testing.Register
        (Into, "host reports", "whole discriminated plans",
         Whole_Plans'Access);
      Landin.Testing.Register
        (Into, "host reports", "invalid plans do not mutate reports",
         Refused_Plans'Access);
      Landin.Testing.Register
        (Into, "host reports", "host identity controls every collision",
         Host_Identity'Access);
   end Register;
end Landin.Tests.Host_Reports_Suite;
