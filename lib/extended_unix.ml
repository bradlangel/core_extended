open Core.Std
open Unix

external raw_fork_exec :
  stdin : File_descr.t
  -> stdout : File_descr.t
  -> stderr : File_descr.t
  -> ?working_dir : string
  -> ?setuid : int
  -> ?setgid : int
  -> ?env : (string) array
  -> string
  -> string array
  -> Pid.t
  =  "extended_ml_spawn_bc" "extended_ml_spawn"

module Env = struct
  open String.Map
  type t = string String.Map.t

  let empty : t = empty

  let get ()  =
    Array.fold  (Unix.environment ())
      ~init:empty
      ~f:(fun env str ->
        match String.lsplit2 ~on:'=' str with
        | Some (key,data) -> add ~key ~data env
        | None ->
          failwithf
            "extended_unix.Env.get %S is not in the form of key=value"
            str
            ())

  let add ~key ~data env =
    if String.mem key '=' then
      failwithf "extended_unix.Env.add:\
  variable to export in the environment %S contains an equal sign"
        key
        ()
    else if String.mem key '\000' then
      failwithf "extended_unix.Env.add:\
  variable to export in the environment %S contains an null character"
        key
        ()
    else if String.mem data '\000' then
      failwithf "extended_unix.Env.add:\
  value (%S) to export in the environment for %S contains an null character"
        data
        key
        ()
    else
      String.Map.add ~key ~data env

  let to_string_array env =
    String.Map.to_alist env
    |! List.map ~f:(fun (k,v) -> k^"="^v)
    |! List.to_array
end

let fork_exec
    ?(stdin=Unix.stdin)
    ?(stdout=Unix.stdout)
    ?(stderr=Unix.stderr)
    ?(path_lookup=true)
    ?env
    ?working_dir
    ?setuid
    ?setgid
    prog
    args
    =
  let env = Option.map env
    ~f:(fun e ->
      let init,l = match e with
        | `Extend  l ->
          Env.get (),l
        | `Replace l ->
          Env.empty,l
      in
      List.fold_left l
        ~init
        ~f:(fun env (key,data) -> Env.add ~key ~data env)
      |! Env.to_string_array)

  and full_prog =
    if path_lookup then
      match Shell__core.which prog with
      | Some s -> s
      | None -> failwithf "fork_exec: Process not found %s"
        prog
        ()
    else
      prog
  in
  raw_fork_exec
    ~stdin
    ~stdout
    ~stderr
    ?working_dir
    ?setuid
    ?setgid
    ?env
    full_prog
    (Array.of_list (prog::args))

external seteuid : int -> unit = "extended_ml_seteuid"
external setreuid : uid:int -> euid:int -> unit = "extended_ml_setreuid"
external gettid : unit -> int = "extended_ml_gettid"

let ntohl some_int =
  if some_int > 0xFFFFFFFF then
    failwith "int too big"
  else if some_int < 0 then
    failwith "signed ints not supported"
  else
    (
    let buf = String.create 4 in
    Binary_packing.pack_unsigned_32_int_little_endian ~buf ~pos:0 some_int;
    Binary_packing.unpack_unsigned_32_int_big_endian ~buf ~pos:0
    )

let htonl some_int =
  if some_int > 0xFFFFFFFF then
    failwith "int too big"
  else if some_int < 0 then
    failwith "signed ints not supported"
  else
    (
  let buf = String.create 4 in
  Binary_packing.pack_unsigned_32_int_big_endian ~buf ~pos:0 some_int;
  Binary_packing.unpack_unsigned_32_int_little_endian ~buf ~pos:0
    )


type statvfs = {
  bsize: int;                           (** file system block size *)
  frsize: int;                          (** fragment size *)
  blocks: int;                          (** size of fs in frsize units *)
  bfree: int;                           (** # free blocks *)
  bavail: int;                          (** # free blocks for non-root *)
  files: int;                           (** # inodes *)
  ffree: int;                           (** # free inodes *)
  favail: int;                          (** # free inodes for non-root *)
  fsid: int;                            (** file system ID *)
  flag: int;                            (** mount flags *)
  namemax: int;                         (** maximum filename length *)
} with sexp, bin_io

(** get file system statistics *)
external statvfs : string -> statvfs = "statvfs_stub"

(** get load averages *)
external getloadavg : unit -> float * float * float = "getloadavg_stub"

module Extended_passwd = struct
  open Passwd

  let of_passwd_line_exn s =
    match String.split s ~on:':' with
    | name::passwd::uid::gid::gecos::dir::shell::[] ->
        { name = name;
          passwd = passwd;
          uid = Int.of_string uid;
          gid = Int.of_string gid;
          gecos = gecos;
          dir = dir;
          shell = shell
        }
    | _ -> failwithf "of_passwd_line: failed to parse: %s" s ()
  ;;
  let of_passwd_line s = Option.try_with (fun () -> of_passwd_line_exn s) ;;

  let of_passwd_file_exn fn =
    Exn.protectx (In_channel.create fn)
      ~f:(fun chan ->
        List.map (In_channel.input_lines chan) ~f:of_passwd_line_exn)
      ~finally:In_channel.close
  ;;

  let of_passwd_file f = Option.try_with (fun () -> of_passwd_file_exn f) ;;
end

external strptime : fmt:string -> string -> Unix.tm = "unix_strptime"

(* This is based on jli's util code and the python iptools implementation. *)
module Cidr = struct
  type t = {
    address : Unix.Inet_addr.t;
    bits : int;
  } with sexp, fields

  let of_string_exn s =
    match String.split ~on:'/' s with
    | [s_inet_address ; s_bits] ->
      begin
          let bits = Int.of_string s_bits in
          assert (bits >= 0);
          assert (bits <= 32);
          {address=Unix.Inet_addr.of_string s_inet_address; bits=bits}
      end
    | _ -> failwith ("Unable to parse "^s^" into a CIDR address/mask pair.")

  let of_string s =
    try
      Some (of_string_exn s)
    with _ -> None

  let to_string t =
    sprintf "%s/%d" (Unix.Inet_addr.to_string t.address) t.bits


  (** IPv6 addresses are not supported.
    The RFC regarding how to properly format an IPv6 string is...painful.

    Note the 0010 and 0000:
     # "2a03:2880:0010:1f03:face:b00c:0000:0025" |! Unix.Inet_addr.of_string |!
     Unix.Inet_addr.to_string ;;
      - : string = "2a03:2880:10:1f03:face:b00c:0:25"
    *)

  let inet6_addr_to_int_exn _addr =
    failwith "IPv6 isn't supported yet."

  let ip4_valid_range =
    List.map ~f:(fun y ->
          assert (y <= 255) ;
          assert (y >= 0);
          y)

  let inet4_addr_to_int_exn addr =
    let stringified = Unix.Inet_addr.to_string addr in
    match String.split ~on:'.' stringified
    |! List.map ~f:Int.of_string
    |! ip4_valid_range
    with
    | [a;b;c;d] ->
        let address =
              ( a lsl 24)
          lor ( b lsl 16)
          lor ( c lsl 8 )
          lor  d
        in
        address
    | _ -> failwith (stringified ^ " is not a valid IPv4 address.")

  let inet4_addr_of_int_exn l =
    assert (l >= 0);
    assert (l <= 4294967295); (* 0xffffffff *)

    Unix.Inet_addr.of_string (sprintf "%d.%d.%d.%d"
    (l lsr 24 land 255)
    (l lsr 16 land 255)
    (l lsr 8 land 255)
    (l land 255))

  let inet_addr_to_int_exn addr =
    let stringified = Unix.Inet_addr.to_string addr in
    let has_colon = String.contains stringified ':' in
    let has_period = String.contains stringified '.' in
    match has_colon, has_period with
    | true, false -> inet6_addr_to_int_exn addr
    | false, true -> inet4_addr_to_int_exn addr
    | true, true -> failwith "Address cannot have both : and . in it."
    | false, false -> failwith "No address delimter (: or .) found."

  let cidr_to_block c =
    let baseip = inet_addr_to_int_exn c.address in
    let shift = 32 - c.bits in
    let first_ip = (baseip lsr shift) lsl shift in
    let end_mask = (1 lsl shift) -1 in
    let last_ip  = first_ip lor end_mask in
    (first_ip, last_ip)

  let match_exn t ip =
    let range_begin, range_end = cidr_to_block t in
    let ip_int = inet_addr_to_int_exn ip in
    ip_int >= range_begin && ip_int <= range_end

  let match_ t ip =
    try
      Some (match_exn t ip)
    with _ -> None

  (* This exists mostly to simplify the tests below. *)
  let match_strings c a =
    let c = of_string_exn c in
    let a = Unix.Inet_addr.of_string a in
    match_exn c a

  let _flag = Command.Spec.Arg_type.create of_string_exn
end

(* Can we parse some random correct netmasks? *)
TEST = Cidr.of_string "10.0.0.0/8" <> None
TEST = Cidr.of_string "172.16.0.0/12" <> None
TEST = Cidr.of_string "192.168.0.0/16" <> None
TEST = Cidr.of_string "192.168.13.0/24" <> None
TEST = Cidr.of_string "172.25.42.0/18" <> None

(* Do we properly fail on some nonsense? *)
TEST = Cidr.of_string "172.25.42.0/35" =  None
TEST = Cidr.of_string "172.25.42.0/sandwich" =  None
TEST = Cidr.of_string "sandwich/sandwich" =  None
TEST = Cidr.of_string "sandwich/39" =  None
TEST = Cidr.of_string "sandwich/16" =  None
TEST = Cidr.of_string "172.52.43/16" =  None
TEST = Cidr.of_string "172.52.493/16" =  None

(* Can we convert ip addr to an int? *)
TEST = Cidr.inet_addr_to_int_exn (Unix.Inet_addr.of_string "0.0.0.1") = 1
TEST = Cidr.inet_addr_to_int_exn (Unix.Inet_addr.of_string "1.0.0.0") = 16777216
TEST = Cidr.inet_addr_to_int_exn (Unix.Inet_addr.of_string "255.255.255.255") = 4294967295

TEST = Cidr.inet_addr_to_int_exn (Unix.Inet_addr.of_string "172.25.42.1") = 2887330305
TEST = Cidr.inet_addr_to_int_exn (Unix.Inet_addr.of_string "4.2.2.1") = 67240449
TEST = Cidr.inet_addr_to_int_exn (Unix.Inet_addr.of_string "8.8.8.8") = 134744072
TEST = Cidr.inet_addr_to_int_exn (Unix.Inet_addr.of_string "173.194.73.103") = 2915191143
TEST = Cidr.inet_addr_to_int_exn (Unix.Inet_addr.of_string "98.139.183.24") = 1653323544

(* And from an int to a string? *)
TEST = Cidr.inet4_addr_of_int_exn 4294967295 = Unix.Inet_addr.of_string "255.255.255.255"
TEST = Cidr.inet4_addr_of_int_exn 0 =          Unix.Inet_addr.of_string "0.0.0.0"
TEST = Cidr.inet4_addr_of_int_exn 1653323544 = Unix.Inet_addr.of_string "98.139.183.24"
TEST = Cidr.inet4_addr_of_int_exn 2915191143 = Unix.Inet_addr.of_string "173.194.73.103"

(* And round trip for kicks *)
TEST = Cidr.inet4_addr_of_int_exn (Cidr.inet_addr_to_int_exn (Unix.Inet_addr.of_string
"4.2.2.1"
) ) = Unix.Inet_addr.of_string "4.2.2.1"

(* Basic match tests *)
TEST = Cidr.match_strings "10.0.0.0/8" "9.255.255.255" = false
TEST = Cidr.match_strings "10.0.0.0/8" "10.0.0.1" = true
TEST = Cidr.match_strings "10.0.0.0/8" "10.34.67.1" = true
TEST = Cidr.match_strings "10.0.0.0/8" "10.255.255.255" = true
TEST = Cidr.match_strings "10.0.0.0/8" "11.0.0.1" = false

TEST = Cidr.match_strings "172.16.0.0/12" "172.15.255.255" = false
TEST = Cidr.match_strings "172.16.0.0/12" "172.16.0.0" = true
TEST = Cidr.match_strings "172.16.0.0/12" "172.31.255.254" = true

TEST = Cidr.match_strings "172.25.42.0/24" "172.25.42.1" = true
TEST = Cidr.match_strings "172.25.42.0/24" "172.25.42.255" = true
TEST = Cidr.match_strings "172.25.42.0/24" "172.25.42.0" = true

TEST = Cidr.match_strings "172.25.42.0/16" "172.25.0.1" = true
TEST = Cidr.match_strings "172.25.42.0/16" "172.25.255.254" = true
TEST = Cidr.match_strings "172.25.42.0/16" "172.25.42.1" = true
TEST = Cidr.match_strings "172.25.42.0/16" "172.25.105.237" = true

(* And some that should fail *)
TEST = Cidr.match_strings "172.25.42.0/24" "172.26.42.47" = false
TEST = Cidr.match_strings "172.25.42.0/24" "172.26.42.208" = false

module Inet_port = struct
  type t = int with sexp

  let of_int_exn x =
    if x > 0 && x < 65536 then
      x
    else
      failwith (sprintf "%d is not a valid port number." x)

  let of_int x =
    try
      Some (of_int_exn x )
    with _ ->
      None

  let of_string_exn x =
    Int.of_string x |! of_int_exn

  let of_string x =
    try
      Some (of_string_exn x)
    with _ ->
      None

  let to_string x =
    Int.to_string x

  let to_int x =
    x

  let t_of_sexp sexp = String.t_of_sexp sexp |! of_string_exn
  let sexp_of_t t = to_string t |! String.sexp_of_t

  let _flag = Command.Spec.Arg_type.create of_string_exn
end

TEST = Inet_port.of_string "88" = Some 88
TEST = Inet_port.of_string "2378472398572" = None
TEST = Inet_port.of_int 88 = Some 88
TEST = Inet_port.of_int 872342 = None

module Mac_address = struct
  (* An efficient internal representation would be something like a 6 byte array,
     but let's use a hex string to get this off the ground. *)
  type t = string with sexp
  let rex = Pcre.regexp "[^a-f0-9]"
  let of_string s =
    let addr = String.lowercase s |! Pcre.qreplace ~rex ~templ:"" in
    let length = String.length addr in
    if length <> 12 then
      failwithf "MAC address '%s' has the wrong length: %d" s length ();
    addr

  let to_string t =
    let rec loop acc = function
      | a::b::rest ->
        let x = String.of_char_list [a; b] in
        loop (x :: acc) rest
      | [] -> List.rev acc |! String.concat ~sep:":"
      | _ -> assert false
    in
    loop [] (String.to_list t)

  let to_string_cisco t =
    let lst = String.to_list t in
    let a = List.take lst 4 |! String.of_char_list
    and b = List.take (List.drop lst 4) 4 |! String.of_char_list
    and c = List.drop lst 8 |! String.of_char_list in
    String.concat ~sep:"." [a; b; c]
  let t_of_sexp sexp = String.t_of_sexp sexp |! of_string
  let sexp_of_t t = to_string t |! String.sexp_of_t

  let _flag = Command.Spec.Arg_type.create of_string
end

TEST = Mac_address.to_string (Mac_address.of_string "00:1d:09:68:82:0f") = "00:1d:09:68:82:0f"
TEST = Mac_address.to_string (Mac_address.of_string "00-1d-09-68-82-0f") = "00:1d:09:68:82:0f"
TEST = Mac_address.to_string (Mac_address.of_string "001d.0968.820f") = "00:1d:09:68:82:0f"
TEST = Mac_address.to_string_cisco (Mac_address.of_string "00-1d-09-68-82-0f") = "001d.0968.820f"
