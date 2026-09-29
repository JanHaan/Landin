--  Identities for the objects that decide whether a table belongs to them.
--
--  A resolution or checking table answers only for the trees it was
--  prepared from, and a checking key only for the table that made it; each
--  of them used to say which one by keeping the other's host address.  An
--  address is unique only while the object at it lives.  Once a finished
--  compilation is freed, the next one's tree or table may be put exactly
--  where the old one was, and a stale key would then be accepted by a table
--  it never belonged to.  A serial is never issued twice in one process, so
--  a stale identity names nothing and is refused.
--
--  A serial serves only that equality.  It never reaches output, numbering
--  or iteration order: it depends on how many objects the process made
--  before, which two runs of one request need not agree on.  The counter
--  is protected because the test program creates compilations in several
--  tasks at once.

package Landin.Serials is

   type Serial is private;

   No_Serial : constant Serial;

   --  A serial no earlier call returned.
   function Next return Serial;

private

   type Serial is mod 2 ** 64;

   No_Serial : constant Serial := 0;

end Landin.Serials;
