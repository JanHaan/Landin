--  A split command's main on the real host: the arguments from the command
--  line, the native filesystem and tool runner, what the command produced
--  written as bytes, and its status as the process's.  Exceptions end as
--  `refine` ends them, with a sentence and the same statuses.

with Landin.Outcomes;
with Landin.Platform;

package Landin.Splits.Native is

   type Entry_Point is access function
     (Arguments      : Landin.Platform.Path_List;
      Host           : Landin.Platform.Filesystem'Class;
      Tools          : Landin.Platform.Tool_Runner'Class;
      Built_For      : String;
      Terminal_Color : Boolean) return Landin.Outcomes.Outcome;

   --  Name is the command's, `svd`, which the process's own lines name as
   --  `refine-svd`.
   procedure Main (Name : String; Run : Entry_Point);

end Landin.Splits.Native;
