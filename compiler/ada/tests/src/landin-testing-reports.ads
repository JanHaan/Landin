--  Recorded reports.
--
--  A recorded fixture's `expect` file holds refine's report in its
--  recorded form.  A report quotes each source it cites under the line's
--  number, and a library line moves whenever anything above it in its
--  file does, so a recording that pinned that number broke on an
--  unrelated library edit.  The recorded form keeps a location outside
--  the fixture's own directory to its file, its column, the line it
--  quotes and its carets, and writes `*` for the line's number, in the
--  location and in the gutter, whose width is then the marker's; every
--  other byte is the report's.  A location in the fixture's own files
--  keeps its number.  compiler/tests/fixture_meta.py's `recorded_report`
--  is the same rule for the Python lanes, and check.py holds every
--  recording to being in this form.

package Landin.Testing.Reports is

   --  What a library location's line number is recorded as.
   Library_Line : constant String := "*";

   --  REPORT, as refine wrote it with the fixture's directory spelled
   --  DIRECTORY from where it ran, in its recorded form.  Applied to a
   --  recorded form it changes nothing.
   function Recorded_Form (Report, Directory : String) return String;

   --  PATH with each `.` and each `..` that follows a name removed, as
   --  the host would resolve it before any symbolic link: a leading `..`
   --  stays, and `/` alone separates.
   function Lexical (Path : String) return String;

   --  Whether PATH, read lexically, names a file below DIRECTORY.
   function Is_Below (Path, Directory : String) return Boolean;

end Landin.Testing.Reports;
