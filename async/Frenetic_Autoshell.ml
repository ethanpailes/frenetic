open Core.Std
open Async.Std
open Frenetic_NetKAT
open Frenetic_Network

module Compiler = Frenetic_NetKAT_Compiler
module Log = Frenetic_Log

type fdd = Compiler.t
type automaton = Compiler.automaton
type fabric = Frenetic_Fabric.fabric
type topology = Net.Topology.t


(** Various types. Need cleanup and consolidation at some point. *)
type source =
  | String of string
  | Filename of string

type element =
  | Policy   of policy
  | Topology of topology
  | Fabric   of fabric

type loc = (switchId * portId)

type re_state = { mutable ideal : policy
                ; mutable existing : policy
                ; mutable physical : policy
                ; mutable ideal_in : loc list
                ; mutable ideal_out : loc list
                ; mutable existing_in : loc list
                ; mutable existing_out : loc list
                ; mutable ingress : policy list
                ; mutable egress  : policy list
                }

let re_state = { ideal = Filter True
               ; existing = Filter True
               ; physical = Filter True
               ; ideal_in = []
               ; ideal_out = []
               ; existing_in = []
               ; existing_out = []
               ; ingress = []
               ; egress  = []
               }

type state = { mutable policy   : policy option
             ; mutable topology : topology option
             ; mutable fabric   : fabric option
             ; mutable fdd      : fdd option
             ; mutable automaton: automaton option
             }

let state =  { policy   = None
             ; topology = None
             ; fabric   = None
             ; fdd      = None
             ; automaton= None
             }

type update =
  | Fabrication       of fabric
  | FullCompilation   of (policy -> fdd)
  | StagedCompilation of (policy -> automaton) * (automaton -> fdd)
  | ToAuto            of (policy -> automaton)
  | FromAuto          of (automaton -> fdd)

type intermediate =
  | FDD of Compiler.t
  | Automaton of Compiler.automaton

type compile =
  | Local
  | Global
  | ToAutomaton
  | FromAutomaton

type show =
  | SPolicy
  | STopology
  | SFabric
  | STable of switchId
  | SAll

type json =
  | JPolicy
  | JTable of switchId

type input =
  | IPolicy
  | ITopology
  | IFabric

type fabricate =
  | FTopology of (source * switchId list)
  | FPolicy of (source * switchId list)

type retarget =
  | RIdeal of (source * loc list * loc list)
  | RFabric of (source * loc list * loc list)
  | RCircuit of (source * loc list * loc list)
  | RTopo of source
  | RCompile
  | RCore of string * int * switchId list
  | REdge of string * int

type command =
  | Load of (input * source)
  | Show of show
  | Json of json
  | Compile of compile
  | Post of (string * int * string * switchId)
  | Fabricate of fabricate
  | Retarget of retarget
  | Circuit of source
  | Write of string
  | Blank
  | Exit

(** Useful modules, mostly for code clarity *)
module Parser = struct

  (** Monadic Parsers for the command line *)
  open MParser

  module Tokens = MParser_RE.Tokens

  let symbol = Tokens.symbol

  (* Parser for sources *)
  let source : (source, bytes list) MParser.t =
    (char '"' >> many_chars_until any_char (char '"') >>=
     (fun string -> return ( String string) ) ) <|>
    (many_chars (alphanum <|> (any_of "./_-")) >>=
     (fun w -> return (Filename w)))

  (* Parser for integer lists *)
  let int_list : (int list, bytes list) MParser.t =
    (char '[' >> many_until (many_chars_until digit (char ';')) (char ']') >>=
     (fun ints -> return (List.map ints ~f:Int.of_string)))

  (* Parser for lists of locations: (switch, port) pairs written as sw:pt *)
  let loc_list : (loc list, bytes list) MParser.t =
    (char '[' >> many_until (
        many_chars_until digit (char ':') >>=
        (fun swid -> many_chars_until digit (char ';') >>=
          (fun ptid -> return ((Int64.of_string swid),
                               (Int32.of_string ptid)))))
        (char ']') >>=
     (fun ints -> return ints))

  (* Parser for URI endpoints. Not bulletproof. *)
  let uri : ((string * int), bytes list) MParser.t =
    many_chars (alphanum <|> (char '.')) >>=
    (fun hostname ->
       (* Parse hostname:port swid *)
       ((char ':') >> many_chars digit >>=
        (fun port_s -> return (hostname, (Int.of_string port_s)))) <|>
       (* Parse hostname swid *)
       ( blank >> return (hostname, 80)))

  (* Parser for the load command *)
  let load : (command, bytes list) MParser.t =
    symbol "load" >> (
      (symbol "policy"   >> source >>= (fun s -> return (Load (IPolicy, s)))) <|>
      (symbol "topology" >> source >>= (fun s -> return (Load (ITopology, s)))) <|>
      (symbol "fabric"   >> source >>= (fun s -> return (Load (IFabric, s)))))

  (* Parser for the show command *)
  let show : (command, bytes list) MParser.t =
    symbol "show" >> (
      (symbol "policy"   >> (return (Show SPolicy)))   <|>
      (symbol "topology" >> (return (Show STopology))) <|>
      (symbol "fabric"   >> (return (Show SFabric)))  <|>
      (symbol "table"    >> (many_until digit eof >>= (fun sw ->
           let swid = Int64.of_string (String.of_char_list sw) in
           return (Show (STable swid))))) <|>
      (symbol "all"      >> (return (Show SAll))))

  (* Parser for the json command *)
  let json : (command, bytes list) MParser.t =
    symbol "json" >> (
      (symbol "policy"   >> (return (Json JPolicy)))   <|>
      (symbol "table"    >> (many_until digit eof >>= (fun sw ->
           let swid = Int64.of_string (String.of_char_list sw) in
           return (Json (JTable swid))))))

  (* Parser for the compile command *)
  let compile : (command, bytes list) MParser.t =
    symbol "compile" >> (
      (symbol "local" >> (return (Compile Local))) <|>
      (symbol "global" >> (return (Compile Global))) <|>
      (symbol "to-auto" >> (return (Compile ToAutomaton))) <|>
      (symbol "from-auto" >> (return (Compile FromAutomaton))))

  (* Parser for the post command *)
  let post : (command, bytes list) MParser.t =
    symbol "post" >> (
      many_chars_until alphanum blank >>=
      (fun cmd ->
         many_chars (alphanum <|> (char '.')) >>=
         (fun hostname ->
            (* Parse hostname:port swid *)
            ((char ':') >> many_chars_until digit blank >>=
             (fun port_s -> many_chars digit >>=
               (fun sw_s -> return (Post (hostname, (Int.of_string port_s),
                                          cmd,
                                          (Int64.of_string sw_s)))))) <|>
            (* Parse hostname swid *)
            ( blank >> many_chars digit >>=
              (fun sw_s -> return (Post (hostname, 80,
                                         cmd,
                                         (Int64.of_string sw_s))))))))

  (* Parser for the fabricate command *)
  (* TODO(basus) : raise errors if ints are parsed properly *)
  let fabricate : (command, bytes list) MParser.t =
    symbol "fabricate" >> (
      (symbol "policy" >> source >>=
       (fun s -> blank >> int_list >>= (fun ints ->
            let swids = List.map ints ~f:(Int64.of_int_exn) in
            return (Fabricate (FPolicy (s, swids)))))) <|>
      (symbol "topology" >> source >>=
       (fun s -> blank >> int_list >>= (fun ints ->
            let swids = List.map ints ~f:(Int64.of_int_exn) in
            return (Fabricate (FPolicy (s, swids)))))))

  (* Parser for retarget command *)
  let retarget : (command, bytes list) MParser.t =
    symbol "retarget" >> (
      (symbol "ideal" >>
       (source >>=
        (fun pol -> blank >> loc_list >>=
          (fun ings -> blank >> loc_list >>=
            (fun egs ->
               return (RIdeal( pol, ings, egs))))))) <|>
      (symbol "fabric" >>
       (source >>=
        (fun pol -> blank >> loc_list >>=
          (fun ings -> blank >> loc_list >>=
            (fun egs ->
               return (RFabric( pol, ings, egs))))))) <|>
      (symbol "circuit" >>
       (source >>=
        (fun pol -> blank >> loc_list >>=
          (fun ings -> blank >> loc_list >>=
            (fun egs ->
               return (RCircuit( pol, ings, egs))))))) <|>
      (symbol "topology" >>
       (source >>= (fun topo -> return (RTopo topo)))) <|>
      (symbol "compile" >> return RCompile) <|>
      (symbol "setup" >> (
          (symbol "edge" >> uri >>=
           (fun (hostname, port) -> return
               (REdge (hostname, port)))) <|>
          (symbol "core" >> uri >>=
           (fun (hostname, port) -> blank >> int_list >>=
             (fun ints ->
                let swids = List.map ints ~f:(Int64.of_int_exn) in
                return (RCore (hostname, port, swids)))))))) >>=
    (fun r -> return ( Retarget r) )

  let circuit : (command, bytes list) MParser.t =
    symbol "circuit" >> source >>= (fun s -> return (Circuit s))

  (* Parser for the write command *)
  let write : (command, bytes list) MParser.t =
    symbol "write" >>
      many_until any_char eof >>=
      (fun filename -> return (Write (String.of_char_list filename)))

  (* Parser for a blank line *)
  let blank : (command, bytes list) MParser.t =
    eof >> return Blank

  (* Parser for the exit command *)
  let exit : (command, bytes list) MParser.t =
    (symbol "exit" <|> symbol "quit") >> return Exit

  let command : (command, bytes list) MParser.t =
    load     <|>
    show     <|>
    json     <|>
    compile  <|>
    post     <|>
    retarget <|>
    fabricate<|>
    circuit  <|>
    write    <|>
    blank    <|>
    exit

  (** Non-Monadic parsers for the information that the shell can
  manipulate. Mostly just wrappers for parsers from the rest of the Frenetic
  codebase. *)

  (* Use the netkat parser to parse policies *)
  let policy (pol_str : string) : (policy, string) Result.t =
    try
      Ok (Frenetic_NetKAT_Parser.policy_of_string pol_str)
    with Camlp4.PreCast.Loc.Exc_located (error_loc,x) ->
      Error (sprintf "Error: %s\n%s"
               (Camlp4.PreCast.Loc.to_string error_loc)
               (Exn.to_string x))

end

module Source = struct
  let to_string (s:source) : (string, string) Result.t = match s with
    | String s -> Ok s
    | Filename f ->
      try
        let chan = In_channel.create f in
        Ok (In_channel.input_all chan)
      with Sys_error msg -> Error msg

  let to_policy (s:source) : (policy, string) Result.t =
    match to_string s with
    | Ok s -> Parser.policy s
    | Error e -> print_endline e; Error e
end

(** Utility functions and shorthands *)
let log_filename = "frenetic.log"
let log = Log.printf
let (>>|) = Result.(>>|)

let string_of_policy = Frenetic_NetKAT_Pretty.string_of_policy

let compile_local =
  let open Compiler in
  compile_local ~options:{ default_compiler_options with cache_prepare = `Keep }

let rec update (s:state) (u:update) : unit = match u with
  | Fabrication fabric -> s.fabric <- Some fabric
  | FullCompilation fn -> begin match s.policy with
      | Some p -> s.fdd <- Some(fn p)
      | None   -> print_endline "Local and global compilation requires a policy"
    end
  | StagedCompilation (fn1, fn2) -> begin match s.policy with
      (* This check is redundant, we could call update recursively without an *)
      (* error, but it allows for a better error message *)
      | Some p -> update s (ToAuto fn1) ; update s (FromAuto fn2)
      | None   -> print_endline "Staged compilation requires a policy"
    end
  | ToAuto fn -> begin match s.policy with
      | Some p -> s.automaton <- Some (fn p)
      | None   -> print_endline "Compilation to automaton requires a policy" end
  | FromAuto fn -> begin match s.automaton with
      | Some a -> s.fdd <- Some(fn a)
      | None   -> print_endline "Compilation from automaton requires a automaton"
    end

let load (l:input) (s:source) : (element, string) Result.t =
  try match l with
    | IPolicy -> Source.to_policy s >>| (fun p -> Policy p )
    | ITopology -> begin match s with
        | Filename f ->  Ok (Topology (Net.Parse.from_dotfile f))
        | _ -> Error "Topologies can only be loaded from DOT files" end
    | IFabric -> Error "Fabric loading unimplemented"
  with Sys_error e
     | Failure e -> Error e

let rec show (s:show) : unit = match s with
  | SPolicy -> begin match state.policy with
      | None -> print_endline "No policy specified"
      | Some p -> printf "%s\n" (Frenetic_NetKAT_Pretty.string_of_policy p) end
  | STopology -> begin match state.topology with
      | None -> print_endline "No topology specified"
      | Some t -> printf "%s\n" (Net.Pretty.to_string t) end
  | SFabric -> begin match state.fabric with
      | None -> print_endline "No fabric specified. Use `fabricate` command."
      | Some f -> printf "\n%s\n" (Frenetic_Fabric.to_string f) end
  | STable swid ->
    (* TODO(basus): print an error if the given switch id is not in the *)
    (* topology or policy *)
    begin match state.fdd with
      | Some fdd -> let table = Compiler.to_table swid fdd in
        printf "\n%s\n" (Frenetic_OpenFlow.string_of_flowTable table)
      | None ->
        print_endline "Showing flowtables requires a loaded and compiled policy"
    end
  | SAll ->
    print_endline "Policy";
    show SPolicy;
    print_endline "Topology";
    show STopology;
    print_endline "Fabric";
    show SFabric

let json(j:json) : unit = match j with
  | JPolicy -> begin match state.policy with
      | None -> print_endline "No policy specified"
      | Some p ->
        let json = Frenetic_NetKAT_Json.policy_to_json p in
        printf "%s\n" (Yojson.Basic.pretty_to_string json)
    end
  | JTable swid -> begin match state.fdd with
      | Some fdd ->
        let table = Compiler.to_table swid fdd in
        let json = Frenetic_NetKAT_SDN_Json.flowTable_to_json table in
        printf "\n%s\n" (Yojson.Basic.pretty_to_string json)
      | None ->
        print_endline "JSON flowtables requires a loaded and compiled policy"
    end

let fabricate (fab:fabricate) : (fabric, string) Result.t = match fab with
  | FPolicy(source, swids) -> Source.to_policy source >>|
    fun p -> Frenetic_Fabric.of_local_policy p swids
  | FTopology(s, swids) -> begin match s with
      | Filename f ->
        let topology = Net.Parse.from_dotfile f in
        Ok (Frenetic_Fabric.vlan_per_port topology)
      | _ -> Error "Topologies can only be loaded from DOT files" end

let circuit (s:source) : (policy, string) Result.t =
  let open Frenetic_Circuit_NetKAT in
  let (>>=) = Result.(>>=) in
  match Source.to_policy s with
  | Ok pol ->
    config_of_policy pol >>=
    validate_config >>|
    local_policy_of_config
 | Error e ->
    Error ( "Could not read circuit policy" ^ e)

let post (uri:Uri.t) (body:string) : unit =
  try_with (fun () ->
      let open Cohttp.Body in
      Cohttp_async.Client.post ~body:(`String body) uri >>=
      (fun (_,body) -> (Cohttp_async.Body.to_string body)))
  >>> (function
      | Ok s -> printf "%s\n" s
      | Error _ -> printf "Could not post")

let install (host:string) (port:int) (swids:switchId list) (fdd:fdd) : unit =
  List.iter swids ~f:(fun swid ->
      let path = String.concat ~sep:"/" ["install"; Int64.to_string swid] in
      let uri = Uri.make ~host:host ~port:port ~path:path () in
      try
        let table =  Compiler.to_table swid fdd in
        let json = (Frenetic_NetKAT_SDN_Json.flowTable_to_json table) in
        let body = Yojson.Basic.to_string json in
        post uri body
      with Not_found -> printf "No table found for swid %Ld\n%!" swid;
        printf "%s\n%!" (Printexc.get_backtrace ()))

let retarget (r:retarget) = match r with
  | RIdeal (s, ings, egs) -> begin match Source.to_policy s with
      | Ok policy ->
        re_state.ideal     <- policy;
        re_state.ideal_in  <- ings;
        re_state.ideal_out <- egs
      | Error e -> print_endline e end
  | RFabric (s, ings, egs) -> begin match Source.to_policy s with
      | Ok policy ->
        re_state.existing     <- policy;
        re_state.existing_in  <- ings;
        re_state.existing_out <- egs
      | Error e -> print_endline e end
  | RCircuit (s, ings, egs) -> begin match circuit s with
      | Ok policy ->
        re_state.existing     <- policy;
        re_state.existing_in  <- ings;
        re_state.existing_out <- egs
      | Error e -> print_endline e end
  | RTopo s -> begin match Source.to_policy s with
      | Ok policy ->
        re_state.physical <- policy
      | Error e -> print_endline e end
  | RCompile ->
    let ideal = Frenetic_Fabric.assemble re_state.ideal re_state.physical re_state.ideal_in
        re_state.ideal_out in
    let fabric = Frenetic_Fabric.assemble re_state.existing re_state.physical re_state.existing_in
        re_state.existing_out in
    let ideal_parts = (Frenetic_Fabric.extract ideal) in
    let fab_parts = Frenetic_Fabric.extract fabric in
    let ins, outs = Frenetic_Fabric.retarget ideal_parts fab_parts
        re_state.physical in
    re_state.ingress <- ins;
    re_state.egress <- outs
  | REdge (host, port) ->
    let ingress = Frenetic_NetKAT_Optimize.mk_big_union re_state.ingress in
    print_endline (string_of_policy ingress);
    let egress  = Frenetic_NetKAT_Optimize.mk_big_union re_state.egress in
    print_endline (string_of_policy egress);
    let edge = Frenetic_NetKAT.Union (ingress, egress) in
    let edge_fdd = compile_local edge in
    let edge_switches = List.dedup (List.rev_append
                                      (List.map re_state.ideal_in fst)
                                      (List.map re_state.ideal_out fst)) in
    install host port edge_switches edge_fdd;
  | RCore (host, port, swids) ->
    let core_fdd = compile_local re_state.existing in
    install host port swids core_fdd

let write (at : Frenetic_NetKAT_Compiler.automaton) (filename:string) : unit =
  let string = Frenetic_NetKAT_Compiler.automaton_to_string at in
  Out_channel.write_all "%s\n%!" ~data:string

let parse_command (line : string) : command option =
  match (MParser.parse_string Parser.command line []) with
  | Success command -> Some command
  | Failed (msg, e) -> (print_endline msg; None)

let command (com:command) : unit = match com with
  | Load (l,s) -> begin match load l s with
      | Ok (Policy p)   -> state.policy   <- Some p
      | Ok (Topology t) -> state.topology <- Some t
      | Ok (Fabric f)   -> state.fabric   <- Some f
      | Error s         -> print_endline s end
  | Show s -> show s
  | Json s -> json s
  | Fabricate f -> begin match (fabricate f) with
      | Ok f -> update state (Fabrication f)
      | Error s -> print_endline s end
  | Circuit c -> begin match circuit c with
      | Ok p ->
        print_endline "Implementable localized policy is:";
        print_endline (string_of_policy p)
      | Error e -> print_endline e end
  | Retarget r -> retarget r
  | Compile c -> begin match c with
      | Local         -> begin
          try update state (FullCompilation Compiler.compile_local)
          with Compiler.Non_local -> print_endline "Policy is non-local." end
      | Global        -> update state (FullCompilation Compiler.compile_global)
      | ToAutomaton   -> update state (ToAuto Compiler.compile_to_automaton)
      | FromAutomaton -> update state (FromAuto Compiler.compile_from_automaton)
    end
  | Post(host, port, cmd, swid) ->
    let path = String.concat ~sep:"/" [cmd; Int64.to_string swid] in
    let uri = Uri.make ~host:host ~port:port ~path:path () in
    begin match state.fdd with
      | Some fdd ->
        let table = Compiler.to_table swid fdd in
        let json = (Frenetic_NetKAT_SDN_Json.flowTable_to_json table) in
        let body = Yojson.Basic.to_string json in
        post uri body
      | None -> printf "Please `load` and `compile` a policy first" end
  | Write _ -> ()
  | Exit ->
    print_endline "Goodbye!"; Shutdown.shutdown 0
  | Blank -> ()

let rec repl () : unit Deferred.t =
  printf "autoshell> %!";
  Reader.read_line (Lazy.force Reader.stdin) >>= fun input ->
  let handle line = match line with
    | `Eof -> Shutdown.shutdown 0
    | `Ok line -> begin match parse_command line with
        | Some c -> command c
        | None -> () end
  in handle input;
  repl ()

let main () : unit =
  Log.set_output [Async.Std.Log.Output.file `Text log_filename];
  printf "Frenetic Automaton Shell v 1.0\n%!";
  printf "Type `help` for a list of commands\n%!";
  let _ = repl () in
  ()
  
