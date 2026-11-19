--  `refine-dap`, the Debug Adapter Protocol server (D1383, D1523).
--
--  An editor speaks the protocol to it over standard input and output,
--  and it speaks to a debugger the targets already script: GDB through
--  GDB/MI, or LLDB through LLDB's own adapter, `lldb-dap`, whose messages
--  it relays.  What it adds is Landin's: which debugger a program takes,
--  where the library's files are (D422), and what a panic site means,
--  read from the program's source table (D1292).
--
--  It holds no front end: it reads source tables through
--  Landin.Site_Tables, finds the library through Landin.Library, and every
--  host effect goes through Landin.Platform.

package Landin.Adapter is

   pragma Pure;

end Landin.Adapter;
