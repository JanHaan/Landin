--  What `refine explain` prints for a construct or a decision (D530).
--
--  A diagnostic's note cites the paragraph or the decision that states its
--  rule, `[1760]` or `D275`, and a reader at a terminal follows that
--  citation here: the title, the document and, for a decision, the section
--  of `spec.md`'s register it is in, and its page on the site.  The bodies
--  of this package and of its child Texts are generated from `tour.md` and
--  `spec.md` by `python3 check.py --catalogue`, so the executable carries
--  its own copy and reads no file; `check.py` fails when they disagree.
--
--  A number neither document defines answers "" everywhere, so Holds is
--  what a caller asks first.

package Landin.Diagnostics.Citations is

   type Citation_Kind is (Construct, Decision);

   --  A construct's title as its heading writes it, without the number;
   --  a decision's, without its `Dnnn —`.
   function Construct_Title (Number : Natural) return String;
   function Decision_Title (Number : Natural) return String;

   --  The document that defines the construct, `tour.md` or `spec.md`.
   function Construct_Document (Number : Natural) return String;

   --  The register section a decision is recorded under, as the site
   --  heads it: `Decisions: The toolchain, C and the machine`.
   function Decision_Section (Number : Natural) return String;

   --  The address of the entry on https://www.701.dev, with the anchor
   --  the site's renderer gives its heading.
   function Construct_Page (Number : Natural) return String;
   function Decision_Page (Number : Natural) return String;

   function Holds (Kind : Citation_Kind; Number : Natural) return Boolean
     is (case Kind is
            when Construct => Construct_Title (Number) /= "",
            when Decision  => Decision_Title (Number) /= "");

end Landin.Diagnostics.Citations;
