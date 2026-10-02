--  What the hosted runtime bridge asks of the operating system's C library.
--
--  `Landin.Hosted` names the bridge's helpers and nothing else; this says
--  what each system's libc spells beneath them.  The values are facts about
--  the operating system rather than the object format or the processor:
--  FreeBSD is ELF with Darwin's errno function, and Linux keeps one set of
--  `open` flags on every architecture its generic ABI covers.  A backend
--  asks here by `Landin.Targets.Capabilities.Hosted_System_Of` and never by
--  comparing descriptions.

with Landin.Targets.Capabilities;

package Landin.Backend.Hosted_ABI is

   subtype Hosted_System is Landin.Targets.Capabilities.Hosted_System;

   use all type Landin.Targets.Capabilities.Hosted_System;

   --  The logical C name of the function returning the calling thread's
   --  errno cell.  A backend renders it through `Link_Symbol` like any
   --  other C name, and reserves it so no program symbol can capture it.
   function Errno_Function (System : Hosted_System) return String
     with Pre => System /= No_Hosted_System;

   --  `O_WRONLY | O_CREAT | O_TRUNC`, which the bridge's write-open passes
   --  to `open` with the mode 0666 the process umask then filters.
   function Create_For_Writing (System : Hosted_System) return Natural
     with Pre => System /= No_Hosted_System;

   --  0666, the same on every system.
   Created_File_Mode : constant := 8#666#;

end Landin.Backend.Hosted_ABI;
