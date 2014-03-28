module OF10 = OpenFlow0x01_Core
module OF13 = OpenFlow0x04_Core

open Packet

exception Unsupported of string

type switchId = int64
type portId = int32
type queueId = int32

type bufferId = int32

type field =
  | InPort
  | EthType
  | EthSrc
  | EthDst
  | Vlan
  | VlanPcp
  | IPProto
  | IP4Src
  | IP4Dst
  | TCPSrcPort
  | TCPDstPort

type fieldVal = VInt.t

type pattern =
    { dlSrc : dlAddr option
    ; dlDst : dlAddr option
    ; dlTyp : dlTyp option
    ; dlVlan : dlVlan option
    ; dlVlanPcp : dlVlanPcp option
    ; nwSrc : nwAddr option
    ; nwDst : nwAddr option
    ; nwProto : nwProto option
    ; tpSrc : tpPort option
    ; tpDst : tpPort option
    ; inPort : portId option }

let all_pattern =
    { dlSrc = None
    ; dlDst = None
    ; dlTyp = None
    ; dlVlan = None
    ; dlVlanPcp = None
    ; nwSrc = None
    ; nwDst = None
    ; nwProto = None
    ; tpSrc = None
    ; tpDst = None
    ; inPort = None }


type action =
  | OutputAllPorts
  | OutputPort of portId
  | Controller of int
  | Enqueue of portId * queueId
  | SetField of field * fieldVal

type seq = action list

type par = seq list

type group = par list

type timeout =
  | Permanent
  | ExpiresAfter of int16

type flow = {
  pattern: pattern;
  action: group;
  cookie: int64;
  idle_timeout: timeout;
  hard_timeout: timeout
}

type flowTable = flow list 

type payload =
  | Buffered of bufferId * bytes 
  | NotBuffered of bytes

type packetInReason =
  | NoMatch
  | ExplicitSend

type pktIn = payload * int * VInt.t * packetInReason

type switchFeatures = {
  switch_id : switchId;
  switch_ports : VInt.t list
}

type flowStats = {
  flow_table_id : int8; (** ID of table flow came from. *)
  flow_pattern : pattern;
  flow_duration_sec: int32;
  flow_duration_nsec: int32;
  flow_priority: int16;
  flow_idle_timeout: int16;
  flow_hard_timeout: int16;
  flow_action: action;
  flow_packet_count: int64;
  flow_byte_count: int64
}

let format_field (fmt : Format.formatter) (f : field) : unit =
  Format.pp_print_string fmt
    (match f with
      | InPort -> "port"
      | EthType -> "ethTyp"
      | EthSrc -> "ethSrc"
      | EthDst -> "ethDst"
      | Vlan -> "vlanId"
      | VlanPcp -> "vlanPcp"
      | IPProto -> "ipProto"
      | IP4Src -> "ipSrc"
      | IP4Dst -> "ipDst"
      | TCPSrcPort -> "tcpSrcPort"
      | TCPDstPort -> "tcpDstPort")

let format_value (fmt : Format.formatter) (f : field) (v : VInt.t) : unit =
  match f with
    | EthType -> Format.fprintf fmt "0x%x" (VInt.get_int16 v)
    | EthSrc
    | EthDst -> Format.pp_print_string fmt (Packet.string_of_mac (VInt.get_int48 v))
    | IPProto -> Format.fprintf fmt "0x%x" (VInt.get_int8 v)
    | IP4Src
    | IP4Dst -> Format.pp_print_string fmt (Packet.string_of_ip (VInt.get_int32 v))
    | _ -> VInt.format fmt v

let format_mac (fmt : Format.formatter) (v:int48) =
  Format.pp_print_string fmt (Packet.string_of_mac v)

let format_ip (fmt : Format.formatter) (v:int32) =
  Format.pp_print_string fmt (Packet.string_of_ip v)

let format_hex (fmt : Format.formatter) (v:int) =
  Format.fprintf fmt "0x%x" v

let format_int (fmt : Format.formatter) (v:int) =
  Format.fprintf fmt "%u" v

let format_int32 (fmt : Format.formatter) (v:int32) =
  Format.fprintf fmt "%lu" v

let format_pattern (fmt:Format.formatter) (p:pattern) : unit = 
  let first = ref true in
  let format_field name format_val m_val =
    match m_val with
      | None   -> ()
      | Some v ->
        if not (!first) then Format.fprintf fmt ",@,";
        Format.fprintf fmt "%s = %a" name format_val v;
        first := false in
  Format.fprintf fmt "@[{";
  format_field "ethSrc" format_mac p.dlSrc;
  format_field "ethDst" format_mac p.dlDst;
  format_field "ethTyp" format_hex p.dlTyp;
  format_field "vlanId" (fun fmt v -> match v with
                          | None -> ()
                          | Some v ->  format_int fmt v)
                        p.dlVlan;
  format_field "vlanPcp" format_int p.dlVlanPcp;
  format_field "nwProto" format_hex p.nwProto;
  format_field "ipSrc" format_ip p.nwSrc;
  format_field "ipDst" format_ip p.nwDst;
  format_field "tcpSrcPort" format_int p.tpSrc;
  format_field "tcpDstPort" format_int p.tpDst;
  format_field "port" format_int32 p.inPort;
  Format.fprintf fmt "}@]"

let rec format_action (fmt:Format.formatter) (a:action) : unit = 
  match a with         
  | OutputAllPorts -> 
    Format.fprintf fmt "OutputAllPorts"
  | OutputPort(n) -> 
    Format.fprintf fmt "OutputPort(%ld)" n
  | Controller(n) -> 
    Format.fprintf fmt "Controller(%d)" n
  | Enqueue(m,n) -> 
    Format.fprintf fmt "Enqueue(%ld,%ld)" m n
  | SetField(f,v) -> 
    Format.fprintf fmt "SetField(%a,%a)" format_field f (fun fmt -> format_value fmt f) v

let rec format_seq (fmt : Format.formatter) (seq : seq) : unit =
  match seq with
  | [] -> ()
  | [act] -> format_action fmt act
  | (act :: act' :: seq') ->
      Format.fprintf fmt "@[%a;@ %a@]" format_action act format_seq (act' :: seq')

let rec format_par (fmt : Format.formatter) (par : par) : unit =
  match par with
  | [] -> ()
  | [seq] -> format_seq fmt seq
  | (seq :: seq' :: par') ->
    Format.fprintf fmt "@[%a |@ %a@]" format_seq seq format_par (seq' :: par')

let rec format_group (fmt : Format.formatter) (group : group) : unit =
  match group with
  | [] -> ()
  | [par] -> format_par fmt par
  | (par :: par' :: groups) ->
    Format.fprintf fmt "@[%a +@ %a@]" format_par par format_group (par' :: groups)
  
let format_timeout (fmt:Format.formatter) (t:timeout) : unit = 
  match t with 
    | Permanent -> Format.fprintf fmt "Permanent"
    | ExpiresAfter(n) -> Format.fprintf fmt "ExpiresAfter(%d)" n

let format_flow (fmt: Format.formatter) (f : flow) : unit = 
  Format.fprintf fmt "@[{pattern=%a,@," format_pattern f.pattern;
  Format.fprintf fmt "action=%a,@," format_group f.action;
  Format.fprintf fmt "cookie=%s,@," (Int64.to_string f.cookie);
  Format.fprintf fmt "idle_timeout=%a,@," format_timeout f.idle_timeout;
  Format.fprintf fmt "hard_timeout=%a}@]" format_timeout f.hard_timeout
    
let format_flowTable (fmt:Format.formatter) (l:flowTable) : unit = 
  Format.fprintf fmt "@[[";
  let _ = 
    List.fold_left
      (fun b f -> 
        if b then Format.fprintf fmt "@ ";
        format_flow fmt f;
        true) false l in 
  Format.fprintf fmt "]@]"

let make_string_of formatter x =
  let open Format in
  let buf = Buffer.create 100 in
  let fmt = formatter_of_buffer buf in
  pp_set_margin fmt 80;
  formatter fmt x;
  fprintf fmt "@?";
  Buffer.contents buf

let string_of_action = make_string_of format_action
let string_of_seq = make_string_of format_seq
let string_of_par = make_string_of format_par
let string_of_field = make_string_of format_field
let string_of_pattern = make_string_of format_pattern
let string_of_flow = make_string_of format_flow
let string_of_flowTable = make_string_of format_flowTable
