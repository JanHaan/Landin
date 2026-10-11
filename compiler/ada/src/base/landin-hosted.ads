--  The one hosted name the compiler still owns.
--
--  The hosted operating-system boundary is library source: `hosted/libc`
--  declares the C library and `hosted/io` keeps the argument root.  The
--  compiler's hosted entry is C's `main`, and before its source body runs
--  it calls the program's C-callable definition of this routine with the
--  incoming `argc` and `argv`, when the program defines one.  Checking
--  holds that definition to `extern(c) (i32, ptr ptr u8) -> none` whenever
--  a hosted entry is selected; nothing else here is a contract.  No target
--  prefix, libc name or machine signature belongs here.
package Landin.Hosted is

   Argument_Initializer : constant String :=
     "_landin_host_initialize_arguments";

end Landin.Hosted;
