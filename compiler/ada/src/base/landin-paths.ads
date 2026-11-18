--  Path text, with no host behind it.
--
--  These read and build the text of a path and ask the host nothing.
--  They sit below `Landin.Library` and `Landin.Driver.Loading`
--  so that a unit which only has to find the library, `refine explain`,
--  `refine version` and `Landin.Source_Maps` among them, does not link
--  the front end that loading a program needs (D1386).

package Landin.Paths is
   pragma Pure;

   --  Child named inside Directory: one `/` between them, none added
   --  when Directory already ends with one.
   function Joined_Path (Directory, Child : String) return String is
     (if Directory'Length > 0
          and then Directory (Directory'Last) = '/'
      then Directory & Child
      else Directory & "/" & Child);

   --  Whether Name is a Landin source's: a name ending `.ldn` with
   --  something before it.
   function Is_Source_Name (Name : String) return Boolean is
     (Name'Length > 4
      and then Name (Name'Last - 3 .. Name'Last) = ".ldn");

end Landin.Paths;
