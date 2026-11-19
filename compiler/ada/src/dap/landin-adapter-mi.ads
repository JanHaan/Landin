--  GDB/MI's output, read one line at a time (D1523).
--
--  A record is a result (`^`), an asynchronous record (`*`, `+`, `=`) or a
--  stream (`~` console, `@` target, `&` log); `(gdb)` ends a batch.  The
--  results after a record's class are written here as one JSON object, so
--  the adapter reads GDB's answers with the same reader it reads the
--  editor's requests with: a tuple is an object, a list an array, whether
--  its elements were named or not, and a string its decoded bytes.  A
--  name a tuple repeats keeps its first value and the later ones are
--  named NAME#2, NAME#3 and on, since JSON gives a name one member.

with Ada.Strings.Unbounded;

package Landin.Adapter.MI is

   type Record_Kind is
     (Result, Exec, Status, Notify, Console, Target, Log, Prompt, Other);

   type Line is record
      Kind    : Record_Kind := Other;
      --  The token a command was sent with, or 0 when it had none.
      Token   : Natural := 0;
      --  `done`, `running`, `stopped`, `error` and so on.
      Class   : Ada.Strings.Unbounded.Unbounded_String;
      --  The results as one JSON object; `{}` when there are none.
      Results : Ada.Strings.Unbounded.Unbounded_String;
      --  A stream's decoded text, or the whole line of an Other.
      Text    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  One line of GDB's output, without its line end.  A line that is
   --  not a record, which a debugged program writing to GDB's own
   --  terminal can produce, is Other.
   function Parse (Text : String) return Line;

   --  Item as an MI C string, quotes included, for a command's operand.
   function Quoted (Item : String) return String;

end Landin.Adapter.MI;
