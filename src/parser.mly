%{

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

  exception Internal of string

  let error fmt = Fmt.kstrf (fun s -> raise (Internal s)) fmt

  let err_unbound v prims ctx =
    error "The variable %s is not bound in %a"
          v Fmt.(Dump.list string) (List.map fst prims @ ctx)

  let index v l =
    let rec aux i = function
      | []   -> None
      | h::t -> if String.equal h v then Some i else aux (i+1) t
    in
    aux 0 l

  let resolve_name v prims ctx =
    match index v ctx with
    | Some i -> Parsetree.var i
    | None   ->
       if List.mem_assoc v prims then List.assoc v prims
       else err_unbound v prims ctx

  let add_ctx a ctx = List.rev_map fst a @ ctx

  open Parsetree
%}

%token <int> INT
%token <string> VAR STRING
%token <bool> BOOL

%token PLUS MINUS
%token TIMES
%token EQ SEMICOLON COLON
%token EOF
%token LPAR RPAR LCUR RCUR
%token FUN
%token COMMA
%token APP
%token DOLLAR

%token S_INT S_BOOL S_STRING
%token ARROW BAR

%left SEMICOLON
%left ARROW

%nonassoc VAR INT STRING LPAR BOOL S_INT S_BOOL S_STRING
%nonassoc APP

%left EQ
%left PLUS MINUS
%left TIMES
%left BAR

%start main
%type <(string * Parsetree.expr) list -> (Parsetree.expr, string) result> main
%type <(string * Parsetree.expr) list -> string list -> Parsetree.expr> expr

%%

main:
  | e=expr EOF { fun prims ->
                 try Ok (e prims [])
                 with Internal s -> Error s }

expr:
  | LPAR e=expr RPAR        { e }
  | i=INT                   { fun _ _   -> int i }
  | s=STRING                { fun _ _   -> string s }
  | b=BOOL                  { fun _ _   -> if b then true_ else false_ }
  | t=typ v=VAR EQ e=expr SEMICOLON b=expr
    { fun prims ctx ->
        let e = e prims ctx in
        let b = b prims (v::ctx) in
        let_var t v e b }
  | t=typ n=VAR LPAR a=args RPAR LCUR e=expr RCUR SEMICOLON b=expr
    { fun prims ctx ->
        let e = e prims (add_ctx a ctx) in
        let b = b prims (n :: ctx) in
        let_fun t n a e b
    }
  | LPAR FUN LPAR a=args RPAR LCUR e=expr RCUR RPAR
    { fun prims ctx ->
        let e = e prims (add_ctx a ctx) in
        lambda a e }
  | v=VAR                   { resolve_name v }
  | v=VAR DOLLAR i=INT      {
      fun prims ctx ->
        let id = index v ctx in
        if Pervasives.(id = Some i) then resolve_name v prims ctx
        else error "%s$%d should have id %a" v i Fmt.(option int) id }
  | a=expr f=binop b=expr   {
      fun prims ctx ->
      let a = a prims ctx in
      let b = b prims ctx in
      f a b }
  | f=expr x=expr %prec APP {
      fun prims ctx ->
      let f = f prims ctx in
      let x = x prims ctx in
      apply f x }

%inline binop:
  | PLUS  { ( + ) }
  | MINUS { ( - ) }
  | TIMES { ( * ) }
  | EQ    { ( = ) }

typ:
  | S_INT             { Type.int }
  | S_BOOL            { Type.bool }
  | S_STRING          { Type.string }
  | a=typ ARROW b=typ { Type.(a @-> b) }
  | a=typ TIMES b=typ { Type.(a ** b) }
  | a=typ BAR b=typ   { Type.(a || b) }
  | LPAR a=typ RPAR   { a }

args:
  | x=separated_nonempty_list(COMMA, arg) {x}

arg:
  | v=VAR COLON t=typ { (v, t) }