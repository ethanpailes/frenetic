(* Write tests in independent modules, then just include them here to run them 
 *)
open NetKAT_Test
open NetKAT_Pretty_Tests
open PolicyGenerator_Test
(* open Verify_Tests *)

Pa_ounit_lib.Runtime.summarize ()
