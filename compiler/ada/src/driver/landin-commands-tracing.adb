with Landin.Json;

package body Landin.Commands.Tracing is
   package US renames Ada.Strings.Unbounded;

   overriding function Available (Host : Runner; Program : String)
      return Boolean is (Host.Original.Available (Program));

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
