with Landin.Json;

package body Landin.Commands.Tracing is
   package US renames Ada.Strings.Unbounded;

   overriding function Available (Host : Runner; Program : String)
      return Boolean is (Host.Original.Available (Program));

   overriding function Resolve_Program (Host : Runner; Program : String)
      return String is (Host.Original.Resolve_Program (Program));

   overriding procedure Run
     (Host : Runner; Program : String;
      Arguments : Landin.Platform.Path_List;
      Result : out Landin.Platform.Tool_Result;
      Capture : Landin.Platform.Capture_Mode := Landin.Platform.Merged)
   is
   begin
      US.Append (Host.Transcript.all, "run [" & Landin.Json.Quoted (Program));
      for Argument of Arguments loop
         US.Append (Host.Transcript.all, "," & Landin.Json.Quoted (Argument));
      end loop;
      US.Append (Host.Transcript.all, "]" & ASCII.LF);
      Host.Original.Run (Program, Arguments, Result, Capture);
   end Run;

   overriding procedure Run_In_Environment
     (Host : Runner; Program : String;
      Arguments : Landin.Platform.Path_List;
      Environment : Landin.Platform.Path_List;
      Result : out Landin.Platform.Tool_Result;
      Capture : Landin.Platform.Capture_Mode := Landin.Platform.Merged)
   is
   begin
      US.Append (Host.Transcript.all, "run [" & Landin.Json.Quoted (Program));
      for Argument of Arguments loop
         US.Append (Host.Transcript.all, "," & Landin.Json.Quoted (Argument));
      end loop;
      US.Append (Host.Transcript.all, "]" & ASCII.LF);
      Host.Original.Run_In_Environment
        (Program, Arguments, Environment, Result, Capture);
   end Run_In_Environment;

   overriding procedure Run_Within
     (Host : Runner; Program : String;
      Arguments : Landin.Platform.Path_List;
      Seconds : Duration;
      Result : out Landin.Platform.Tool_Result;
      Capture : Landin.Platform.Capture_Mode := Landin.Platform.Merged)
   is
   begin
      US.Append (Host.Transcript.all, "run [" & Landin.Json.Quoted (Program));
      for Argument of Arguments loop
         US.Append (Host.Transcript.all, "," & Landin.Json.Quoted (Argument));
      end loop;
      US.Append (Host.Transcript.all, "]" & ASCII.LF);
      Host.Original.Run_Within (Program, Arguments, Seconds, Result, Capture);
   end Run_Within;

   overriding procedure Run_Command
     (Host : Runner; Program : String;
      Arguments : Landin.Platform.Path_List;
      Setting : String;
      Result : out Landin.Platform.Program_Result)
   is
   begin
      Host.Original.Run_Command (Program, Arguments, Setting, Result);
   end Run_Command;

   overriding function Programs_On_Path (Host : Runner; Prefix : String)
      return Landin.Platform.Path_List
      is (Host.Original.Programs_On_Path (Prefix));

   overriding procedure Run_Attached
     (Host : Runner; Program : String;
      Arguments : Landin.Platform.Path_List;
      Result : out Landin.Platform.Program_Result)
   is
   begin
      Host.Original.Run_Attached (Program, Arguments, Result);
   end Run_Attached;

   overriding procedure Prepare_Output
     (Host : Runner; Files : Landin.Platform.Filesystem'Class; Path : String)
   is
   begin
      Host.Original.Prepare_Output (Files, Path);
   end Prepare_Output;

   overriding function Output_Produced
     (Host : Runner; Files : Landin.Platform.Filesystem'Class; Path : String)
      return Boolean is (Host.Original.Output_Produced (Files, Path));
end Landin.Commands.Tracing;
