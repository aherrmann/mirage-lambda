(*
 * Copyright (c) 2018 Thomas Gazagnaire <thomas@gazagnaire.org>
 * and Romain Calascibetta <romain.calascibetta@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

let pp_infix ~infix pp_a pp_b ppf (a, b) =
  Fmt.pf ppf "@[<1>(@[%a@]@ %s @[%a@])@]" pp_a a infix pp_b b

module Type = struct

  type abstract = A: 'a Eq.witness -> abstract

  type t =
    | Unit
    | Int
    | Int32
    | Int64
    | Bool
    | String
    | Lwt
    | List of t
    | Array of t
    | Option of t
    | Apply of t * t
    | Arrow of t * t
    | Pair of t * t
    | Either of t * t
    | Result of t * t
    | Abstract of abstract

  let equal_abstract (A a) (A b) =
    a.name = b.name && match Eq.Witness.eq a.wit b.wit with
    | Some Eq.Refl -> true
    | _ -> false

  let rec equal x y = match x, y with
    | Unit, Unit | Bool, Bool | Int, Int | Int32, Int32 | Int64, Int64
    | String, String | Lwt, Lwt -> true
    | Arrow (a, b), Arrow (c, d)
    | Pair (a, b), Pair (c, d)
    | Either (a, b), Either (c, d)
    | Result (a, b), Result (c, d)
    | Apply (a, b), Apply (c, d) -> equal a c && equal b d
    | List a, List b | Option a, Option b
    | Array a, Array b -> equal a b
    | Abstract a, Abstract b -> equal_abstract a b
    | (Unit|Int|Bool|String|Lwt|Apply _|Abstract _|Arrow _
      |Pair _|Either _|Int32|Int64|Option _|List _
      |Array _|Result _), _ -> false

  let pp_abstract ppf (A a) = Fmt.string ppf a.name

  let rec pp ppf = function
    | Unit          -> Fmt.string ppf "unit"
    | Int           -> Fmt.string ppf "int"
    | Int32         -> Fmt.string ppf "int32"
    | Int64         -> Fmt.string ppf "int64"
    | Bool          -> Fmt.string ppf "bool"
    | String        -> Fmt.string ppf "string"
    | Lwt           -> Fmt.pf ppf "Lwt.t"
    | List a        -> Fmt.pf ppf "%a list" pp a
    | Array a       -> Fmt.pf ppf "%a array" pp a
    | Option a      -> Fmt.pf ppf "%a option" pp a
    | Abstract a    -> Fmt.pf ppf "@[%a@]" pp_abstract a
    | Apply (a, b)  -> Fmt.pf ppf "@[(%a %a)@]" pp a pp b
    | Arrow (a, b)  -> Fmt.pf ppf "%a" (pp_infix ~infix:"->" pp pp) (a, b)
    | Pair (a, b)   -> Fmt.pf ppf "%a" (pp_infix ~infix:"*" pp pp) (a, b)
    | Either (a, b) -> Fmt.pf ppf "%a" (pp_infix ~infix:"|" pp pp) (a, b)
    | Result (a, b) -> Fmt.pf ppf "(%a, %a) result" pp a pp b

  let unit = Unit
  let int = Int
  let int32 = Int32
  let int64 = Int64
  let bool = Bool
  let string = String
  let lwt = Lwt

  let list a = List a
  let option a = Option a
  let array a = Array a

  let arrow a b = Arrow (a, b)
  let either a b = Either (a, b)
  let abstract a = Abstract (A a)
  let apply a b = Apply (a, b)
  let result a b = Result (a, b)

  let ( ** ) a b = Pair (a, b)
  let ( @->) = arrow
  let ( || ) = either

end

type typ = Type.t

type value = V: { v: 'a; t: 'a T.t; pp: 'a Fmt.t } -> value

let pp_value ppf (V t) = t.pp ppf t.v

type arithmetic = [ `Add | `Sub | `Mul | `Div ]

type primitive =
  { name : string
  ; args : typ list
  ; ret  : typ
  ; exp  : value list -> value }
and binop =
  [ arithmetic | `Pair | `Eq ]
and unop =
  | Fst | Snd | L of typ | R of typ | Ok of typ | Error of typ
and expr =
  | Val of value
  | Prm of primitive
  | Lst of typ option * expr list
  | Arr of typ option * expr array
  | Opt of typ option * expr option
  | Var of var
  | Lam of typ * string * expr
  | Rec of { r: typ; p: string * typ; e: expr }
  | App of expr * expr
  | Bin of binop * expr * expr
  | Uno of unop * expr
  | Let of typ * string * expr * expr
  | Swt of { a : expr
           ; b : expr
           ; s : expr }
  | If  of expr * expr * expr
and var = {
  id : int;
}

let dump_var ppf v = Fmt.pf ppf "$%d" v.id

let pp_params ppf ts =
  let aux ppf (n, t) = Fmt.pf ppf "%s: %a" n Type.pp t in
  Fmt.pf ppf "@[<2>(%a)@]" Fmt.(list ~sep:(unit ",@ ") aux) ts

let nth ctx n =
  try List.nth ctx n.id
  with Failure _ ->
    Fmt.failwith "$%d not bound in %a" n.id Fmt.(Dump.list string) ctx

let pp ppf t =
  let pp_typ_opt = Fmt.(option ~none:(unit "?") Type.pp) in
  let rec aux ctx ppf t =
    let pp = aux ctx in
    match t with
    | Var n -> Fmt.pf ppf "%s$%d" (nth ctx n) n.id
    | Val c -> pp_value ppf c
    | Lst (t, [])     -> Fmt.pf ppf "([]: %a list)" pp_typ_opt t
    | Lst (_, l)      -> Fmt.Dump.list pp ppf l
    | Arr (t, [||])   -> Fmt.pf ppf "([||]: %a array)" pp_typ_opt t
    | Arr (_, a)      -> Fmt.Dump.array pp ppf a
    | Opt (_, Some x) -> Fmt.Dump.option pp ppf (Some x)
    | Opt (t, None  ) -> Fmt.pf ppf "(None: %a option)" pp_typ_opt t
    | Prm { name; _ } -> Fmt.string ppf name
    | Lam (t, name, e) ->
      let pp = aux (name :: ctx) in
      Fmt.pf ppf "@[<2>(fun @[(%s:@ %a)@]@ -> @[<2>%a@])@]"
        name Type.pp t pp e
    | Rec r ->
      let pp = aux (fst r.p :: ctx) in
      Fmt.pf ppf "@[<2>(rec %a: %a@ ->@ @[<2>%a@])@]"
        pp_params [r.p] Type.pp r.r pp r.e
    | App (f, a) ->
      Fmt.pf ppf "@[(@[%a@]@ @[%a@])@]" pp f pp a
    | Bin (`Add, a, b) ->
      Fmt.pf ppf "%a" (pp_infix ~infix:"+" pp pp) (a, b)
    | Bin (`Sub, a, b) ->
      Fmt.pf ppf "%a" (pp_infix ~infix:"-" pp pp) (a, b)
    | Bin (`Mul, a, b) ->
      Fmt.pf ppf "%a" (pp_infix ~infix:"*" pp pp) (a, b)
    | Bin (`Div, a, b) ->
      Fmt.pf ppf "%a" (pp_infix ~infix:"/" pp pp) (a, b)
    | Bin (`Eq, a, b) ->
      Fmt.pf ppf "%a" (pp_infix ~infix:"=" pp pp) (a, b)
    | Bin (`Pair, a, b) ->
      Fmt.pf ppf "%a" (Fmt.Dump.pair pp pp) (a, b)
    | Uno (Fst, a) ->
      Fmt.pf ppf "@[<2>(fst@ @[%a@])@]" pp a
    | Uno (Snd, a) ->
      Fmt.pf ppf "@[<2>(snd@ @[%a@])@]" pp a
    | Uno (L t, a) ->
      Fmt.pf ppf "@[<2>L@ @[(%a)@] @[(%a)@]@]" pp a Type.pp t
    | Uno (R t, a) ->
      Fmt.pf ppf "@[<2>R@ @[(%a)@] @[(%a)@]@]" Type.pp t pp a
    | Uno (Ok t, a) ->
      Fmt.pf ppf "@[<2>Ok@ @[(%a)@] @[(%a)@]@]" pp a Type.pp t
    | Uno (Error t, a) ->
      Fmt.pf ppf "@[<2>Error@ @[(%a)@] @[(%a)@]@]" Type.pp t pp a
    | Let (t, n, v, f) ->
      let pp' = aux (n :: ctx) in
      Fmt.pf ppf "@[<v>@[<v2>let @[%s: %a@] =@ @[%a@]@]@ in@ @[<2>%a@]@]"
        n (Fmt.hvbox Type.pp) t (Fmt.hvbox pp) v (Fmt.hvbox pp') f
    | Swt { a; b; s; } ->
      Fmt.pf ppf "@[<2>@[match %a with@\n| @[<2>@[L $1@] ->@ \
                  @[%a@]@]@\n| @[<2>@[R $1@] ->@ @[%a@]@]@]@]"
        pp s pp a pp b
    | If (t, a, b) ->
      Fmt.pf ppf "@[<v>@[<v2>if %a then@,(%a)@]@,@[<v2>else@,(%a)@]@]"
        pp t pp a pp b
  in
  aux [] ppf t

let value v t pp = Val (V {v; t; pp})
let prim p = Prm p

let unit = value () Unit (fun ppf () -> Fmt.pf ppf "()")
let int n = value n Int Fmt.int
let int32 n = value n Int32 Fmt.int32
let int64 n = value n Int64 Fmt.int64
let string s = value s String (fun ppf s -> Fmt.pf ppf "%S" s)

let list ?typ l = Lst (typ, l)
let array ?typ l = Arr (typ, l)
let option ?typ l = Opt (typ, l)
let none typ = option ~typ None
let some e = option (Some e)
let ok t e = Uno (Ok t, e)
let error t e = Uno (Error t, e)
let pair a b = Bin (`Pair, a, b)
let apply f a = App (f, a)
let var id = Var { id }
let match_ s a b = Swt {a; b; s}
let bool b = value b Bool Fmt.bool
let true_ = bool true
let false_ = bool false

let fix p r e = Rec {r; p; e}

let lambda args e =
  List.fold_right (fun (name, t) acc -> Lam (t, name, acc)) args e

let if_ t a b = If (t, a, b)
let left rtyp x = Uno (L rtyp, x)
let right ltyp x = Uno (R ltyp, x)
let fst x = Uno (Fst, x)
let snd x = Uno (Snd, x)

let let_var t n x y = Let (t, n, x, y)

let let_fun t n args e body =
  let t = List.fold_right (fun (_, t) acc -> Type.Arrow (t, acc)) args t in
  let e = lambda args e in
  Let (t, n, e, body)

let let_rec t n ((_, i) as a) e body =
  let ty = Type.Arrow (i, t) in
  Let (ty, n, fix a t e, body)

let primitive name args ret exp = Prm {name; args; ret; exp}

let equal_param (a, b) (c, d) = String.equal a c && Type.equal b d

let equal a b =
  let rec aux k a b = match a, b with
    | Var a    , Var b     -> k (a.id = b.id)
    | Val (V a), Val (V b) ->
      (match T.eq a.t b.t with
       | Some Eq.Refl -> k (a.v = b.v)
       | None          -> k false)
    | Prm a, Prm b -> k (a.name = b.name && a.args = b.args && a.ret = b.ret)
    | Lst (_, a), Lst (_, b) ->
      List.length a = List.length b && List.for_all2 (aux k) a b
    | Arr (_, a), Arr (_, b) ->
      Array.length a = Array.length b
      && List.for_all2 (aux k) (Array.to_list a) (Array.to_list b)
    | Opt (_, a), Opt (_, b) ->
      (match a, b with
       | Some a, Some b -> aux k a b
       | None  , None   -> true
       | _ -> false)
    | Lam (a, b, c), Lam (d, e, f) ->
      aux (fun x -> k (x && a=d && b=e)) c f
    | App (a, b), App (c, d) ->
      aux (fun x -> aux (fun y -> k @@ x && y) a c) b d
    | Bin (a, b, c), Bin (d, e, f) ->
      aux (fun x -> aux (fun y -> k @@ x && y && a=d) b e) c f
    | Uno (a, b), Uno (c, d) ->
      aux (fun x -> x && k (a=c)) b d
    | Let (a, n, b, c), Let (d, m, e, f) ->
      aux (fun x -> aux (fun y -> k @@ x && y && a=d && n=m) b e) c f
    | Swt a, Swt b ->
      aux (fun x ->
          aux (fun y ->
              aux (fun z -> x && k @@ x && y && z) a.a b.a
            ) a.b b.b
        ) a.s b.s
    | Rec a, Rec b ->
      aux (fun x ->
          k @@ x && Type.equal a.r b.r
          && equal_param a.p b.p
        ) a.e b.e
    | If (a, b, c), If (d, e, f) ->
      aux (fun x -> aux (fun y ->
          aux (fun z -> k @@ x && y && z) a d
        ) b e) c f
    | Lst _, x -> Fmt.epr "XXX2 %a\n%!" pp x; false
    | Var _, _ | Val _, _ | Prm _, _ | Lam _, _ | App _, _
    | Bin _, _ | Uno _, _ | Let _, _ | Swt _, _ | Rec _, _
    | If _, _ | Arr _, _ | Opt _, _ -> false
  in
  aux (fun x -> x) a b

let ( = ) a b = Bin (`Eq, a, b)
let ( + ) a b = Bin (`Add, a, b)
let ( * ) a b = Bin (`Mul, a, b)
let ( - ) a b = Bin (`Sub, a, b)
let ( / ) a b = Bin (`Div, a, b)
