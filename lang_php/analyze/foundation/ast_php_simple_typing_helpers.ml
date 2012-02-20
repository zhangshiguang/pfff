(* Julien Verlaguet
 *
 * Copyright (C) 2011 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)

open Ast_php_simple
open Env_typing_php

module Pp = Pp2

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(*****************************************************************************)
(* Modules *)
(*****************************************************************************)

let has_marker env s =
  let marker_size = String.length env.marker in
  String.length s >= marker_size &&
  String.sub s (String.length s - marker_size) marker_size = env.marker

let get_marked_id env s =
  let marker_size = String.length env.marker in
  let s = String.sub s 0 (String.length s - marker_size) in
  s

module Classes: sig
  val add: env -> string -> Ast_php_simple.class_def -> unit
  val get: env -> string -> Ast_php_simple.class_def
  val mem: env -> string -> bool
  val remove: env -> string -> unit
  val iter: env -> (Ast_php_simple.class_def -> unit) -> unit
end = struct

  let add env n x =
    let x = Marshal.to_string x [] in
    env.classes := SMap.add n x !(env.classes)

  let get env n =
    let x = SMap.find n !(env.classes) in
    let x = Marshal.from_string x 0 in
    x

  let remove env x =
    env.classes := SMap.remove x !(env.classes)

  let mem env n = SMap.mem n !(env.classes)
  let iter env f = SMap.iter (fun n _ -> f (get env n)) !(env.classes)
end

module Functions: sig
  val add: env -> string -> Ast_php_simple.func_def -> unit
  val get: env -> string -> Ast_php_simple.func_def
  val mem: env -> string -> bool
  val remove: env -> string -> unit
  val iter: env -> (Ast_php_simple.func_def -> unit) -> unit
end = struct

  let add env n x =
    let x = Marshal.to_string x [] in
    env.funcs := SMap.add n x !(env.funcs)

  let get env n =
    let x = SMap.find n !(env.funcs) in
    let x = Marshal.from_string x 0 in
    x

  let remove env x =
    env.funcs := SMap.remove x !(env.funcs)

  let mem env n = SMap.mem n !(env.funcs)
  let iter env f = SMap.iter (fun n _ -> f (get env n)) !(env.funcs)


end


module TEnv = struct
  let get env x = try IMap.find x !(env.tenv) with Not_found -> Tsum []
  let set env x y = env.tenv := IMap.add x y !(env.tenv)
  let mem env x = IMap.mem x !(env.tenv)
end


module GEnv: sig

  type genv

  val get_class: env -> string -> t
  val set_class: env -> string -> t -> unit

  val get_fun: env -> string -> t
  val set_fun: env -> string -> t -> unit

  val get_global: env -> string -> t

  val mem_class: env -> string -> bool
  val mem_fun: env -> string -> bool

  val remove_class: env -> string -> unit
  val remove_fun: env -> string -> unit

  val iter: env -> (string -> t -> unit) -> unit

  val save: env -> out_channel -> unit
  val load: in_channel -> (string -> unit) -> env

end = struct

  type genv = t SMap.t SMap.t * t SMap.t

  let get env x =
    try SMap.find x !(env.genv)
    with Not_found -> Tvar (fresh())

  let set env x t = env.genv := SMap.add x t !(env.genv)
  let unset env x = env.genv := SMap.remove x !(env.genv)
  let mem env x = SMap.mem x !(env.genv)

  let get_class env x = get env ("^Class:"^x)
  let get_fun env x = get env ("^Fun:"^x)

  let get_global env x =
    let x = "^Global:"^x in
    if SMap.mem x !(env.genv)
    then get env x
    else
      let v = Tvar (fresh()) in
      set env x v;
      v

  let set_class env x t = set env ("^Class:"^x) t
  let set_fun env x t = set env ("^Fun:"^x) t

  let mem_class env x = mem env ("^Class:"^x)
  let mem_fun env x = mem env ("^Fun:"^x)

  let iter env f = SMap.iter f !(env.genv)
  let save env oc =
    Marshal.to_channel oc env []

  let load ic o =
    let env = Marshal.from_channel ic in
    env

  let remove env x = env.genv := SMap.remove x !(env.genv)
  let remove_class env x = remove env ("^Class:"^x)
  let remove_fun env x = remove env ("^Fun:"^x)

end

module Env = struct
  let set env x t = env.env := SMap.add x t !(env.env)
  let unset env x = env.env := SMap.remove x !(env.env)
  let mem env x = SMap.mem x !(env.env)

  let get env x =
    try SMap.find x !(env.env) with Not_found ->
      let n = Tvar (fresh()) in
      set env x n;
      n
end

module Subst = struct

  let set env x y = env.subst := IMap.add x y !(env.subst)
  let mem env x = IMap.mem x !(env.subst)

  let rec get env x =
    let x' = try IMap.find x !(env.subst) with Not_found -> x in
    if x = x'
    then x
    else
      let x'' = get env x' in
      set env x x'';
      x''

  let rec replace env stack x y =
    if ISet.mem x stack
    then ()
    else if mem env x
    then
      let x' = get env x in
      set env x y;
      replace env (ISet.add x stack) x' y
    else
      set env x y

  let replace env x y = replace env ISet.empty x y

end

module Fun = struct

  let rec is_fun env stack = function
    | Tvar n ->
        let n = Subst.get env n in
        if ISet.mem n stack
        then false
        else is_fun env (ISet.add n stack) (TEnv.get env n)
    | Tsum l ->
        (try List.iter (function Tfun _ -> raise Exit | _ -> ()) l; false
        with Exit -> true)

  let rec get_args env stack t =
    match t with
    | Tvar n ->
        let n = Subst.get env n in
        if ISet.mem n stack then [] else
        let stack = ISet.add n stack in
        get_args env stack (TEnv.get env n)
    | Tsum l -> get_prim_args env stack l

  and get_prim_args env stack = function
    | [] -> []
    | Tfun (l, _) :: _ -> l
    | _ :: rl -> get_prim_args env stack rl

end


module Builtins = struct

  let id =
    let v = Tvar (fresh()) in
    fun_ [v] v

  let array_fill =
    let v = Tvar (fresh()) in
    fun_ [int; int; v] (array (int, v))

  let array_merge =
    let v = array (Tvar (fresh()), Tvar (fresh())) in
    fun_ [v;v;v;v;v;v;v;v;v;v;v;v;v] v

  let preg_match =
    fun_ [string; string; array (int, string); int; int] int

  let strpos =
    fun_ [string; string; int] (or_ [pint; pstring])

  let array_keys =
    let v1 = Tvar (fresh()) in
    let v2 = Tvar (fresh()) in
    fun_ [array (v1, v2); v2; bool] v1

  let implode =
    fun_ [string; array (any, string)] string

  let preg_replace =
    fun_ [string; string; string; int; int] string

  let array_change_key_case =
    let v = Tvar (fresh()) in
    let ien = SSet.add "CASE_UPPER" (SSet.add "CASE_LOWER" SSet.empty) in
    let ien = Tsum [Tienum ien] in
    fun_ [array (string, v); ien] (array (string, v))

  let array_chunk =
    let v = Tvar (fresh()) in
    fun_ [array (int, v); int; bool] (array (int, array(int, v)))

  let array_combine =
    let k = Tvar (fresh()) in
    let v = Tvar (fresh()) in
    fun_ [k; v] (array (k, v))

  let array_count_values =
    let v = Tvar (fresh()) in
    fun_ [array (int, v)] (array (v, int))

  let array_fill_keys =
    let v = Tvar (fresh()) in
    let x = Tvar (fresh()) in
    fun_ [array (int, v); x] (array (v, x))

  let array_filter =
    let k = Tvar (fresh()) in
    let v = Tvar (fresh()) in
    fun_ [array (k, v); any] (array (k, v))

  let array_flip =
    let k = Tvar (fresh()) in
    let v = Tvar (fresh()) in
    fun_ [array (k, v)] (array (v, k))

  let array_key_exists =
    let k = Tvar (fresh()) in
    let v = Tvar (fresh()) in
    fun_ [k; array (k, v)] bool

  let array_keys =
    let k = Tvar (fresh()) in
    let v = Tvar (fresh()) in
    fun_ [array (k, v); v; bool] (array (int, k))

  let array_map =
    let k = Tvar (fresh()) in
    fun_ [any; array (k, any)] (array (k, any))

  let array_merge_recursive =
    let k = Tvar (fresh()) in
    let v = Tvar (fresh()) in
    let x = array (k, v) in
    fun_ [x;x;x;x;x;x;x;x;x;x;x;x] x

  let array_multisort = id

  let array_pad =
    let k = Tvar (fresh()) in
    let v = Tvar (fresh()) in
    fun_ [array(k, v); int; v] (array(k, v))

  let array_pop =
    let v = Tvar (fresh()) in
    fun_ [array (int, v)] v

  let array_product =
    fun_ [array (int, int)] int

  let array_push =
    let v = Tvar (fresh()) in
    fun_ [array (int, v)] (array (int, v))

  let array_rand =
    let v = Tvar (fresh()) in
    fun_ [array (int, v); int] v

  let array_reduce =
    let v = Tvar (fresh()) in
    fun_ [array (int, v); any; v] v

  let array_reverse =
    let v = Tvar (fresh()) in
    fun_ [array (int, v)] (array (int, v))

  let array_search =
    let k = Tvar (fresh()) in
    let v = Tvar (fresh()) in
    fun_ [array (k, v); v; bool] k

  let array_shift =
    let v = Tvar (fresh()) in
    fun_ [array (int, v)] (array (int, v))

  let array_slice =
    let v = Tvar (fresh()) in
    fun_ [array (int, v); int; int] (array (int, v))

  let array_splice =
    let v = Tvar (fresh()) in
    fun_ [array (int, v); int; int; v] (array (int, v))

  let array_sum =
    let v = Tvar (fresh()) in
    fun_ [array (int, v)] v

  let array_unique =
    let k = Tvar (fresh()) in
    let v = Tvar (fresh()) in
    let x = array (k, v) in
    fun_ [x] x

  let array_unshift =
    let v = Tvar (fresh()) in
    fun_ [array (int, v);v;v;v;v;v;v;v;v;v;v;v] v

  let array_values =
    let v = Tvar (fresh()) in
    fun_ [array (any, v)] (array (int, v))

  let array_walk_recursive =
    let k = Tvar (fresh()) in
    fun_ [array (k, any); any; any] (array (k, any))

  let array_walk = array_walk_recursive

  let array_shuffle =
    let v = Tvar (fresh()) in
    let x = (array (int, v)) in
    fun_ [x] x

  let current =
    let v = Tvar (fresh()) in
    fun_ [array (any, v)] v

  let next =
    fun_ [array (any, any)] null

  let pos = current
  let prev = next
  let reset = next
  let end_ = next

  let in_array =
    let v = Tvar (fresh()) in
    fun_ [array (any, v)] bool

  let key =
    let k = Tvar (fresh()) in
    fun_ [array (k, any)] k

  let range =
    let v = Tvar (fresh()) in
    fun_ [v; v; v] (array (int, v))

  let array_diff =
    let k = Tvar (fresh()) in
    let v = Tvar (fresh()) in
    let x = array (k, v) in
    fun_ [x;x] x

  let sort =
    let v = Tvar (fresh()) in
    fun_ [array (int, v); int; bool] (array (int, v))

  let list =
    let v = Tvar (fresh()) in
    let a = array (int, v) in
    fun_ [a;a;a;a;a;a;a;a;a] any

  let super_globals =
    let h = Hashtbl.create 23 in
    let add x = Hashtbl.add h x true in
    add "$GLOBALS";
    add "$_SERVER";
    add "$_GET";
    add "$_POST";
    add "$_FILES";
    add "$_COOKIE";
    add "$_SESSION";
    add "$_REQUEST";
    add "$_ENV";
    h

  let make env =
    let add_name x = env.builtins := SSet.add ("^Fun:"^x) !(env.builtins) in
    let add x y = add_name x; GEnv.set_fun env x y in
    add "int" int;
    add "bool" bool;
    add "float" float;
    add "string" string;
    add "u" (fun_ [string] string);
    add "null" null;
    add "isset" (fun_ [any] bool);
    add "count" (fun_ [any] int);
    add "sizeof" (fun_ [any] int);
    add "id" id;
    add "array_fill" array_fill;
    add "sprintf" (fun_ [string] string);
    add "substr" (fun_ [string; int; int] string);
    add "intval" (fun_ [any] int);
    add "starts_with" (fun_ [string;string] bool);
    add "ends_with" (fun_ [string;string] bool);
    add "array_merge" array_merge;
    add "preg_match" preg_match;
    add "preg_replace" preg_replace;
    add "strpos" strpos;
    add "time" (fun_ [] int);
    add "array_keys" array_keys;
    add "implode" implode;
    add "empty" (fun_ [any] bool);
    add "unset" (fun_ [any] null);
    add "trim" (fun_ [string; string] string);
    add "get_class" (fun_ [any] string);
    add "str_replace" (fun_ [string; string; string] string);
    add "strlen" (fun_ [string] int);
    add "is_array" (fun_ [array (any, any)] bool);
    add "is_string" (fun_ [string] bool);
    add "is_bool" (fun_ [bool] bool);
    add "is_int" (fun_ [int] int);
    add "is_float" (fun_ [float] bool);
    add "is_scalar" (fun_ [or_ [pint;pfloat;pbool]] bool);
    add "is_object" (fun_ [Tsum [Tobject (SMap.empty)]] bool);
    add "is_numeric" (fun_ [or_ [pint;pfloat]] bool);
    add "array_change_key_case" array_change_key_case;
    add "array_chunk" array_chunk;
    add "array_combine" array_combine;
    add "array_count_values" array_count_values;
    add "array_fill_keys" array_fill_keys;
    add "array_filter" array_filter;
    add "array_flip" array_flip;
    add "array_key_exists" array_key_exists;
    add "array_keys" array_keys;
    add "array_map" array_map;
    add "array_merge_recursive" array_merge_recursive;
    add "array_multisort" array_multisort;
    add "array_pad" array_pad;
    add "array_pop" array_pop;
    add "array_product" array_product;
    add "array_push" array_push;
    add "array_rand" array_rand;
    add "array_reduce" array_reduce;
    add "array_reverse" array_reverse;
    add "array_search" array_search;
    add "array_shift" array_shift;
    add "array_slice" array_slice;
    add "array_splice" array_splice;
    add "array_sum" array_sum;
    add "array_unique" array_unique;
    add "array_unshift" array_unshift;
    add "array_values" array_values;
    add "array_walk_recursive" array_walk_recursive;
    add "array_walk" array_walk;
    add "array_shuffle" array_shuffle;
    add "current" current;
    add "next" next;
    add "pos" pos;
    add "prev" prev;
    add "reset" reset;
    add "end" end_;
    add "in_array" in_array;
    add "key" key;
    add "range" range;
    add "array_diff" array_diff;
    add "explode" (fun_ [string; string; int] (array (int, string)));
    add "max" (fun_ [] any);
    add "chr" (fun_ [int] string);
    add "strtoupper" (fun_ [string] string);
    add "floor" (fun_ [float] int);
    add "strtotime" (fun_ [string; int] int);
    add "microtime" (fun_ [bool] (or_ [pint; pfloat]));
    add "echo" (fun_ [string] null);
    add "exit" (fun_ [int] null);
    add "print" (fun_ [string] null);
    add "json_encode" (fun_ [string] string);
    add "date" (fun_ [string; int] string);
    add "strftime" (fun_ [string; int] string);
    add "sort" sort;
    add "round" (fun_ [float] int);
    add "join" implode;
    add "htmlize" (fun_ [thtml] string);
    add "txt2html" (fun_ [thtml; bool] string);
    add "list" list;

end

module FindCommonAncestor = struct

  exception Found of string

  let rec class_match env cand acc id =
    Classes.mem env id &&
    let c = Classes.get env id in
    match c.c_extends with
    | [] -> false
    | l when List.mem cand l -> true
    | l -> List.fold_left (class_match env cand) acc l

  let rec get_candidates env acc id =
    let acc = SSet.add id acc in
    if not (Classes.mem env id) then acc else
    let c = Classes.get env id in
    List.fold_left (get_candidates env) acc c.c_extends

  let go env ss =
    let l = SSet.fold (fun x y -> x :: y) ss [] in
    let cands = List.fold_left (get_candidates env) SSet.empty l in
    try SSet.iter (
    fun cand ->
      let all_match = List.fold_left (class_match env cand) false l in
      if all_match then raise (Found cand)
   ) cands;
    None
    with Found c -> Some c

end

module Print2 = struct

  let rec ty env penv stack depth x =
    match x with
    | Tvar n ->
        let n = Subst.get env n in
        let t = TEnv.get env n in
        if ISet.mem n stack then begin
          Pp.print penv (string_of_int n);
          Pp.print penv "&";
        end
        else begin
          let stack = ISet.add n stack in
          ty env penv stack depth t
        end
    | Tsum [] -> Pp.print penv "_"
    | Tsum [x] -> prim_ty env penv stack depth x
    | Tsum l ->
        Pp.list penv (fun penv -> prim_ty env penv stack depth) "(" l " |" ")"

  and prim_ty env penv stack depth = function
    | Tabstr s -> Pp.print penv s
    | Tsstring s -> Pp.print penv "string"
    | Tienum _
    | Tsenum _ ->
(*        let l = SSet.fold (fun x acc -> Tabstr x :: acc) s [] in *)
        Pp.print penv "enum"
    | Trecord m ->
        let depth = depth + 1 in
        Pp.print penv "array";
        if depth >= 2
        then Pp.print penv "(...)"
        else
          let l = SMap.fold (fun x y l -> (x, y) :: l) m [] in
          Pp.list penv
            (fun penv ->
              print_field env " => " penv stack depth)
            "(" l ";" ")";
    | Tarray (_, t1, t2) ->
        Pp.print penv "array(";
        Pp.nest penv (fun penv ->
          ty env penv stack depth t1;
          Pp.print penv " => ";
          Pp.nest penv (fun penv ->
            ty env penv stack depth t2));
        Pp.print penv ")";
    | Tfun (tl, t) ->
        Pp.print penv "fun ";
        Pp.list penv (
        fun penv (s, x) ->
          ty env penv stack depth x;
          if s = "" then () else
          (Pp.print penv " ";
           Pp.print penv s)
       ) "(" tl "," ")";
        Pp.print penv " -> ";
        Pp.nest penv (fun penv ->
          ty env penv stack depth t)
    | Tobject m ->
        let depth = depth + 1 in
        Pp.print penv "object";
        if depth >= 3
        then Pp.print penv "(...)"
        else
          let l = SMap.fold (fun x y l -> (x, y) :: l) m [] in
          Pp.list penv (fun penv -> print_field env ": " penv stack depth) "(" l ";" ")";
    | Tclosed (s, _) ->
        if SSet.cardinal s = 1 then Pp.print penv (SSet.choose s) else
        (match FindCommonAncestor.go env s with
        | None ->
            let l = SSet.fold (fun x acc -> x :: acc) s [] in
            Pp.list penv (Pp.print) "(" l "|" ")";
        | Some s -> Pp.print penv s)

  and print_field env sep penv stack depth (s, t) =
    Pp.print penv s;
    Pp.print penv sep;
    Pp.nest penv (fun penv ->
      ty env penv stack depth t)

  let genv env =
    let penv = Pp.empty print_string in
    GEnv.iter env (
    fun x t ->
      if not (SSet.mem x !(env.builtins)) then begin
        Pp.print penv x; Pp.print penv " = ";
        ty env penv ISet.empty 0 t;
        Pp.newline penv;
      end
       )

  let penv env =
    genv env

  let args o env t =
    match Fun.get_args env ISet.empty t with
    | [] -> ()
    | tl ->
        let penv = Pp.empty o in
        let stack = ISet.empty in
        let depth = 1000 in
        Pp.list penv (
        fun penv (s, x) ->
          if s = "" then
            ty env penv stack depth x
          else begin
            if x = Tsum [] then () else ty env penv stack depth x;
            (Pp.print penv " ";
             Pp.print penv s)
          end
       ) "(" tl "," ")"

  let rec get_fields vim_mode env stack acc = function
    | Tvar n ->
        let n = Subst.get env n in
        if ISet.mem n stack then SSet.empty else
        let stack = ISet.add n stack in
        let t = TEnv.get env n in
        get_fields vim_mode env stack acc t
    | Tsum l -> List.fold_left (get_prim_fields vim_mode env stack) acc l

  and get_prim_fields vim_mode env stack acc = function
    | Tabstr _ -> acc
    | Tsstring s -> SSet.union s acc
    | Tienum s
    | Tsenum s -> SSet.union s acc
    | Tobject m ->
        SMap.fold (
        fun x t acc ->
          if x = "__obj" then acc else
          let x =
            if vim_mode || true then
              if Fun.is_fun env ISet.empty t
              then
                (match Fun.get_args env ISet.empty t with
                | [] -> x^"()"
                | _ ->
                    x^"("
                )
              else x
            else (* not vim_mode *)
              let buf = Buffer.create 256 in
              let o = Buffer.add_string buf in
              let penv = Pp.empty o in
              ty env penv stack 0 t;
              x^"\t"^(Buffer.contents buf)
          in
          SSet.add x acc
       ) m acc
    | Tclosed (s, m) ->
        let acc =
          try
            if SSet.cardinal s = 1
            then (match GEnv.get_class env (SSet.choose s) with
            | Tsum [Tobject m] ->
                get_fields vim_mode env stack acc (SMap.find "__obj" m)
            | _ -> acc)
            else acc
          with _ -> acc
        in
        get_prim_fields vim_mode env stack acc (Tobject m)
    | Trecord m ->
        SMap.fold (fun x _ acc -> SSet.add x acc) m acc
    | Tarray (s, t, _) ->
        let acc = SSet.union s acc in
        let acc = get_fields vim_mode env stack acc t in
        acc
    | Tfun _ -> acc


  let get_fields vim_mode env t =
    let acc = get_fields vim_mode env ISet.empty SSet.empty t in
    acc

end

module Print = struct

  let rec print o env stack = function
    | Tvar n ->
        let n = Subst.get env n in
        if IMap.mem n stack
        then if env.debug then (o "rec["; o (string_of_int n); o "]") else o "rec"
        else if TEnv.mem env n
        then begin
          if env.debug then (o "["; o (string_of_int n); o "]");
          let stack = IMap.add n true stack in
          print o env stack (TEnv.get env n)
        end
        else
            (o "`"; o (string_of_int n))
    | Tsum [] -> o "*"
    | Tsum l ->
        sum o env stack l

  and print_prim o env stack = function
    | Tabstr x -> o x
    | Tienum s -> o "ienum{"; SSet.iter (fun x -> o " | "; o x) s; o " | }"
    | Tsstring s -> o "cstring{"; SSet.iter (fun x -> o " | "; o x) s; o " | }"
    | Tsenum s -> o "senum{"; SSet.iter (fun x -> o " | "; o x) s; o " | }"
    | Trecord m ->
        o "r{";
        SMap.iter (
        fun x t ->
          o x;
          if env.debug then
            (o ":"; print o env stack t);
          o ","
       ) m;
        o "}";
    | Tarray (_, t1, t2) ->
        o "array(";
        print o env stack t1;
        o " => ";
        print o env stack t2;
        o ")"
    | Tfun (l, t) ->
        o "(";
        list o env stack l;
        o " -> ";
        print o env stack t;
        o ")"
    | Tobject m ->
        o "obj"; print_prim o env stack (Trecord m)
    | Tclosed (_, m) -> print_prim o env stack (Tobject m)

  and list o env stack l =
    match l with
    | [] -> o "()"
    | [_, x] -> print o env stack x
    | (_, x) :: rl -> print o env stack x; o ", "; list o env stack rl

  and sum o env stack l =
    match l with
    | [] -> ()
    | [x] -> print_prim o env stack x
    | x :: rl -> print_prim o env stack x; o " | "; sum o env stack rl

  let dd env x =
    print print_string env IMap.empty x;
    print_string "\n"

  let genv env =
    GEnv.iter env (
    fun x t ->
      if not (SSet.mem x !(env.builtins)) then begin
        print_string x; print_string " = ";
        print print_string env IMap.empty t;
        print_string "\n";
      end
       ) ; flush stdout

  let penv env =
    Printf.printf "*******************************\n";
    genv env;
    if env.debug then
      SMap.iter (
      fun x t ->
        if not (SSet.mem x !(env.builtins)) then begin
          print_string x; print_string " = ";
          print print_string env IMap.empty t;
          print_string "\n";
        end
     ) !(env.env);
    flush stdout

  let show_type env o t =
    Print2.ty env (Pp.empty o) ISet.empty 0 t;
    o "\n"
end

module Instantiate = struct

  let rec get_vars env stack subst = function
    | Tvar n ->
        let n = Subst.get env n in
        (match TEnv.get env n with
        | _ when ISet.mem n stack ->
            ISet.add n subst
        | Tsum [] -> ISet.add n subst
        | t -> get_vars env (ISet.add n stack) subst t
        )
    | Tsum l -> List.fold_left (get_prim_vars env stack) subst l

  and get_prim_vars env stack subst = function
    | Trecord m ->
        SMap.fold (
        fun _ t subst ->
          get_vars env stack subst t
       ) m subst
    | Tarray (_, t1, t2) ->
        let subst = get_vars env stack subst t1 in
        let subst = get_vars env stack subst t2 in
        subst
    | _ -> subst

  let rec replace_vars env stack subst is_left = function
    | Tvar n ->
        let n = Subst.get env n in
        if IMap.mem n subst then Tvar (IMap.find n subst) else
        (match TEnv.get env n with
        | _ when ISet.mem n stack -> Tsum []
        | t -> replace_vars env (ISet.add n stack) subst is_left t
        )
    | Tsum l when List.length l > 1 -> Tsum []
    | Tsum l -> Tsum (List.map (replace_prim_vars env stack subst is_left) l)

  and replace_prim_vars env stack subst is_left = function
    | Trecord m -> Trecord (SMap.map (replace_vars env stack subst is_left) m)
    | Tarray (s, t1, t2) ->
        let t1 = replace_vars env stack subst is_left t1 in
        let t2 = replace_vars env stack subst is_left t2 in
        Tarray (s, t1, t2)
    | x -> x

  let rec ty env stack t =
    match t with
    | Tvar x ->
        let x = Subst.get env x in
        let t = TEnv.get env x in
        if ISet.mem x stack then Tvar x else
        let stack = ISet.add x stack in
        TEnv.set env x (ty env stack t);
        Tvar x
    | Tsum tyl -> Tsum (List.map (prim_ty env stack) tyl)

  and prim_ty env stack = function
    | Tfun (tl, t) ->
        let argl = List.map snd tl in
        let vars = List.fold_left (get_vars env ISet.empty) ISet.empty argl in
        let vars = ISet.fold (fun x acc -> IMap.add x (fresh()) acc) vars IMap.empty in
        Tfun (List.map (fun (s, x) -> s, replace_vars env ISet.empty vars true x) tl,
              replace_vars env ISet.empty vars false t)
    | x -> x

  let rec approx env stack t =
    match t with
    | Tvar x ->
        let x = Subst.get env x in
        let t = TEnv.get env x in
        if ISet.mem x stack then Tvar x else
        let stack = ISet.add x stack in
        approx env stack t
    | Tsum [x] -> Tsum (approx_prim_ty env stack x)
    | _ -> Tsum []

  and approx_prim_ty env stack = function
    | Tarray (s, t1, t2) -> [Tarray (s, approx env stack t1, approx env stack t2)]
    | Tobject _
    | Tfun _ -> []
    | x -> [x]

end

module Generalize = struct

  let rec ty env stack = function
    | Tvar n ->
        let n = Subst.get env n in
        if ISet.mem n stack then Tsum [] else
        (match TEnv.get env n with
        | Tsum [Tabstr "null"]
        | Tsum [] -> Tvar n
        | t ->
            ty env (ISet.add n stack) t
        )
    | Tsum l -> Tsum (List.map (prim_ty env stack) l)

  and prim_ty env stack = function
    | Tarray (s, t1, t2) -> Tarray (s, ty env stack t1, ty env stack t2)
    | Tfun (tl, t) -> Tfun (List.map (fun (s, x) -> s, ty env stack x) tl, ty env stack t)
    | x -> x

end

(* This module normalizes a type, that is gets rid of the type variables
 * The problem is, a type can have many equivalents modulo alpha-conversion
   (alpha-conversion is when one renames type variables).
   For instance, f: forall 'a, 'a -> 'a is equivalent to forall 'b, 'b -> 'b
   The normalization gets rid of all these type variables.
   Of course, it is wrong, since every type variable is renamed to (-1).
   But it doesn't matter, we use this function to check the equality of 2 types
   in the unit tests. Since all these types are instantiated, we don't really
   care about the type variables.
*)
module Normalize = struct

  let rec normalize stack env = function
    | Tvar n ->
        let n = Subst.get env n in
        if ISet.mem n stack
        then Tvar (-1)
        else if TEnv.mem env n
        then normalize (ISet.add n stack) env (TEnv.get env n)
        else Tvar (-1)
    | Tsum l -> Tsum (List.map (prim_ty stack env) l)

  and prim_ty stack env t =
    let k = normalize stack env in
    match t with
    | Tsstring _
    | Tabstr _
    | Tienum _
    | Tsenum _ as x -> x
    | Trecord m -> Trecord (SMap.map k m)
    | Tarray (s, t1, t2) -> Tarray (s, k t1, k t2)
    | Tfun (l, t) -> Tfun (List.map (fun (_, t) -> "", k t) l, k t)
    | Tobject obj -> Tobject (SMap.map k obj)
    | Tclosed (s, m) -> Tclosed (s, SMap.map k m)

  let normalize = normalize ISet.empty

end
