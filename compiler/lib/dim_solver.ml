(** Dimension constraint solver using sum-of-products canonical form.

    Based on the approach from GHC's ghc-typelits-natnormalise plugin
    (Baaij, PhD thesis 2015). Dimension expressions are normalized to
    a canonical sum-of-products form where commutativity, associativity,
    distributivity, and identity are automatically handled.

    References:
    - Baaij, "Digital Circuit Design in CλaSH" (PhD thesis, U. Twente 2015)
    - Henriksen et al., "Size Types, Semantics and Pragmatics" (FHPC 2021)
    - Vazou et al., "Refinement Types for Haskell" (ICFP 2014)
*)

open Ast

type monomial = {
  coeff : int;
  vars : string list;
      (** Sorted variable names. Empty = pure constant (shouldn't appear in terms). *)
}
(** A monomial: coefficient × sorted list of variable names.
    Examples:
    - 3 × #N         → {coeff=3; vars=["#N"]}
    - #M × #N        → {coeff=1; vars=["#M"; "#N"]}
    - standalone 5    → represented in the constant field, not here *)

type canonical = { const : int; terms : monomial list }
(** Canonical form: constant + sum of monomials (sorted, no zero coefficients).
    Examples:
    - #N + 3         → {const=3; terms=[{coeff=1; vars=["#N"]}]}
    - 2×#N + #M      → {const=0; terms=[{coeff=1; vars=["#M"]}; {coeff=2; vars=["#N"]}]}
    - #M×#N + 1      → {const=1; terms=[{coeff=1; vars=["#M";"#N"]}]}
    - 7              → {const=7; terms=[]} *)

(** Compare monomials by variable list (lexicographic on sorted var names). *)
let compare_monomial a b = compare a.vars b.vars

(** Merge a list of monomials: sort by vars, combine same-var terms by adding
    coefficients, remove zero-coefficient terms. *)
let merge_terms terms =
  let sorted = List.sort compare_monomial terms in
  let rec merge = function
    | [] -> []
    | [ t ] -> if t.coeff = 0 then [] else [ t ]
    | a :: b :: rest when a.vars = b.vars ->
        merge ({ coeff = a.coeff + b.coeff; vars = a.vars } :: rest)
    | a :: rest -> if a.coeff = 0 then merge rest else a :: merge rest
  in
  merge sorted

(** Negate a canonical form. *)
let negate c =
  {
    const = -c.const;
    terms = List.map (fun m -> { m with coeff = -m.coeff }) c.terms;
  }

(** Add two canonical forms. *)
let add c1 c2 =
  { const = c1.const + c2.const; terms = merge_terms (c1.terms @ c2.terms) }

(** Subtract: c1 - c2. *)
let sub c1 c2 = add c1 (negate c2)

(** Multiply two canonical forms (full distribution). *)
let mul c1 c2 =
  (* Constant × constant *)
  let const_part = c1.const * c2.const in
  (* Constant × terms *)
  let cross1 =
    if c2.const = 0 then []
    else List.map (fun m -> { m with coeff = m.coeff * c2.const }) c1.terms
  in
  let cross2 =
    if c1.const = 0 then []
    else List.map (fun m -> { m with coeff = m.coeff * c1.const }) c2.terms
  in
  (* Term × term (produces product monomials) *)
  let products =
    List.concat_map
      (fun m1 ->
        List.map
          (fun m2 ->
            {
              coeff = m1.coeff * m2.coeff;
              vars = List.sort String.compare (m1.vars @ m2.vars);
            })
          c2.terms)
      c1.terms
  in
  { const = const_part; terms = merge_terms (cross1 @ cross2 @ products) }

(** Try to divide canonical form by a constant. Returns None if any term
    doesn't divide evenly. *)
let try_div_const c divisor =
  if divisor = 0 then None
  else if c.const mod divisor <> 0 then None
  else
    let divided_terms =
      List.filter_map
        (fun m ->
          if m.coeff mod divisor <> 0 then None
          else Some { m with coeff = m.coeff / divisor })
        c.terms
    in
    if List.length divided_terms <> List.length c.terms then None
    else Some { const = c.const / divisor; terms = divided_terms }

(** Convert a type expression to canonical form. Resolves bound TyMeta via
    the provided lookup function. Unbound metas are treated as variables. *)
let rec to_canonical ~(lookup_meta : int -> type_expr option) (ty : type_expr) :
    canonical =
  match ty with
  | TyConstInt n -> { const = n; terms = [] }
  | TyVar name -> { const = 0; terms = [ { coeff = 1; vars = [ name ] } ] }
  | TyMeta m -> (
      match lookup_meta m with
      | Some t -> to_canonical ~lookup_meta t
      | None ->
          (* Unbound meta: use a unique name *)
          let name = Printf.sprintf "?m%d" m in
          { const = 0; terms = [ { coeff = 1; vars = [ name ] } ] })
  | TyDimOp (DimAdd, a, b) ->
      add (to_canonical ~lookup_meta a) (to_canonical ~lookup_meta b)
  | TyDimOp (DimSub, a, b) ->
      sub (to_canonical ~lookup_meta a) (to_canonical ~lookup_meta b)
  | TyDimOp (DimMul, a, b) ->
      mul (to_canonical ~lookup_meta a) (to_canonical ~lookup_meta b)
  | TyDimOp (DimDiv, a, b) -> (
      let ca = to_canonical ~lookup_meta a in
      let cb = to_canonical ~lookup_meta b in
      (* Only handle division by constant *)
      match cb with
      | { const = divisor; terms = [] } when divisor > 0 -> (
          match try_div_const ca divisor with
          | Some result -> result
          | None ->
              (* Can't divide evenly — represent as opaque *)
              {
                const = 0;
                terms =
                  [
                    {
                      coeff = 1;
                      vars =
                        [
                          Printf.sprintf "__div(%s,%d)" (canonical_to_debug ca)
                            divisor;
                        ];
                    };
                  ];
              })
      | _ ->
          (* Division by non-constant — represent as opaque *)
          {
            const = 0;
            terms =
              [
                {
                  coeff = 1;
                  vars =
                    [
                      Printf.sprintf "__div(%s,%s)" (canonical_to_debug ca)
                        (canonical_to_debug cb);
                    ];
                };
              ];
          })
  | _ ->
      (* Not a dimension expression — treat as an opaque variable.
         Use a simple string repr to avoid depending on Types module. *)
      let opaque_name = Printf.sprintf "__opaque_%d" (Hashtbl.hash ty) in
      { const = 0; terms = [ { coeff = 1; vars = [ opaque_name ] } ] }

and canonical_to_debug c =
  let terms_str =
    List.map
      (fun m ->
        let vars_str = String.concat "*" m.vars in
        if m.coeff = 1 then vars_str
        else Printf.sprintf "%d*%s" m.coeff vars_str)
      c.terms
  in
  let all =
    if c.const <> 0 then string_of_int c.const :: terms_str else terms_str
  in
  match all with [] -> "0" | _ -> String.concat "+" all

(** Reconstruct a type_expr from a canonical variable name.
    Meta variables (named "?mN") become TyMeta; all others become TyVar. *)
let var_name_to_ty v =
  if String.length v > 2 && v.[0] = '?' && v.[1] = 'm' then
    match int_of_string_opt (String.sub v 2 (String.length v - 2)) with
    | Some id -> TyMeta id
    | None -> TyVar v
  else TyVar v

(** Convert canonical form back to a type expression. *)
let from_canonical (c : canonical) : type_expr =
  let const_ty = if c.const <> 0 then Some (TyConstInt c.const) else None in
  let term_to_ty m =
    let base =
      match m.vars with
      | [] ->
          TyConstInt
            m.coeff (* shouldn't happen — pure constants go in .const *)
      | [ v ] ->
          if m.coeff = 1 then var_name_to_ty v
          else TyDimOp (DimMul, TyConstInt m.coeff, var_name_to_ty v)
      | v :: rest ->
          let product =
            List.fold_left
              (fun acc v -> TyDimOp (DimMul, acc, var_name_to_ty v))
              (var_name_to_ty v) rest
          in
          if m.coeff = 1 then product
          else TyDimOp (DimMul, TyConstInt m.coeff, product)
    in
    base
  in
  let term_tys = List.map term_to_ty c.terms in
  let all_tys =
    match const_ty with Some t -> t :: term_tys | None -> term_tys
  in
  match all_tys with
  | [] -> TyConstInt 0
  | [ t ] -> t
  | t :: rest -> List.fold_left (fun acc ty -> TyDimOp (DimAdd, acc, ty)) t rest

(** Check if two canonical forms are equal. *)
let equal c1 c2 =
  c1.const = c2.const
  && List.length c1.terms = List.length c2.terms
  && List.for_all2
       (fun a b -> a.coeff = b.coeff && a.vars = b.vars)
       c1.terms c2.terms

(** Result of solving a dimension equation. *)
type solve_result =
  | Solved  (** Both sides are equal *)
  | BindMeta of int * type_expr  (** Bind meta variable to a dimension *)
  | BindVar of string * type_expr  (** Bind type variable to a dimension *)
  | Contradiction  (** Impossible equation (e.g., 3 = 5) *)
  | Stuck  (** Can't solve (multiple unknowns, nonlinear) *)

(** Helper: check if a type is a solvable variable (meta or dim var). *)
let is_solvable_var ~lookup_meta = function
  | TyMeta m -> ( match lookup_meta m with Some _ -> false | None -> true)
  | TyVar name -> String.length name > 0 && name.[0] = '#'
  | _ -> false

(** Helper: create a bind result for a variable or meta. *)
let bind_result var value =
  match var with
  | TyMeta m -> BindMeta (m, value)
  | TyVar name -> BindVar (name, value)
  | _ -> Stuck

(** Solve the equation lhs = rhs by normalizing both sides, subtracting,
    and checking the result. Handles special cases (division by variable)
    before canonical form, since those can't be represented as polynomials. *)
let solve ~(lookup_meta : int -> type_expr option) (lhs : type_expr)
    (rhs : type_expr) : solve_result =
  (* Pre-canonical special cases for division expressions.
     Division can't always be represented in sum-of-products form,
     so we handle it by algebraic transformation before canonicalization. *)
  let try_div_special () =
    let check dividend divisor rhs_expr =
      (* Case 1: c / var = n → var = c / n (exact division required) *)
      let try_divisor_var () =
        if is_solvable_var ~lookup_meta divisor then
          let c_dividend = to_canonical ~lookup_meta dividend in
          let c_rhs = to_canonical ~lookup_meta rhs_expr in
          match (c_dividend, c_rhs) with
          | { const = c; terms = [] }, { const = n; terms = [] }
            when n > 0 && c mod n = 0 ->
              Some (bind_result divisor (TyConstInt (c / n)))
          | _ -> None
        else None
      in
      (* Case 2: var / c = expr → var = expr * c
         Transforms division into multiplication, then solves via canonical form. *)
      let try_dividend_var () =
        match divisor with
        | TyConstInt c when c > 0 -> (
            (* Multiply rhs by divisor: dividend = rhs * c *)
            let c_rhs = to_canonical ~lookup_meta rhs_expr in
            let product = mul c_rhs { const = c; terms = [] } in
            let c_dividend = to_canonical ~lookup_meta dividend in
            let diff = sub c_dividend product in
            (* Now solve the multiplication-free equation *)
            match diff.terms with
            | [] -> if diff.const = 0 then Some Solved else Some Contradiction
            | [ { coeff; vars = [ single_var ] } ] ->
                let is_meta =
                  String.length single_var > 2
                  && single_var.[0] = '?'
                  && single_var.[1] = 'm'
                in
                let is_dim =
                  String.length single_var > 0 && single_var.[0] = '#'
                in
                if not (is_meta || is_dim) then None
                else if coeff = 0 then
                  if diff.const = 0 then Some Solved else Some Contradiction
                else if diff.const mod coeff <> 0 then None
                else
                  let value = -diff.const / coeff in
                  if value <= 0 then None
                  else
                    let result_ty = TyConstInt value in
                    if is_meta then
                      match
                        int_of_string_opt
                          (String.sub single_var 2
                             (String.length single_var - 2))
                      with
                      | Some id -> Some (BindMeta (id, result_ty))
                      | None -> Some (BindVar (single_var, result_ty))
                    else Some (BindVar (single_var, result_ty))
            | _ -> None)
        | _ -> None
      in
      match try_divisor_var () with
      | Some _ as r -> r
      | None -> try_dividend_var ()
    in
    match (lhs, rhs) with
    | TyDimOp (DimDiv, dividend, divisor), _ -> check dividend divisor rhs
    | _, TyDimOp (DimDiv, dividend, divisor) -> check dividend divisor lhs
    | _ -> None
  in
  match try_div_special () with
  | Some result -> result
  | None -> (
      let cl = to_canonical ~lookup_meta lhs in
      let cr = to_canonical ~lookup_meta rhs in
      if equal cl cr then Solved
      else
        let diff = sub cl cr in
        match diff.terms with
        | [] ->
            (* Only a constant remains: equation is const = 0, which fails if const != 0 *)
            if diff.const = 0 then Solved else Contradiction
        | [ { coeff; vars = [ single_var ] } ] ->
            (* Single variable: coeff * var + const = 0 → var = -const / coeff.
           Only bind solvable variables: metas (?mN) and dim vars (#N).
           Opaque terms (__div, __opaque) must not be bound. *)
            let is_meta_name =
              String.length single_var > 2
              && single_var.[0] = '?'
              && single_var.[1] = 'm'
            in
            let is_dim_var_name =
              String.length single_var > 0 && single_var.[0] = '#'
            in
            if not (is_meta_name || is_dim_var_name) then Stuck
            else if coeff = 0 then
              if diff.const = 0 then Solved else Contradiction
            else if diff.const mod coeff <> 0 then
              Stuck (* non-integer solution *)
            else
              let value = -diff.const / coeff in
              if value <= 0 then Stuck (* dimensions must be >= 1 *)
              else
                let result_ty = TyConstInt value in
                if is_meta_name then
                  let id_str =
                    String.sub single_var 2 (String.length single_var - 2)
                  in
                  match int_of_string_opt id_str with
                  | Some id -> BindMeta (id, result_ty)
                  | None -> BindVar (single_var, result_ty)
                else BindVar (single_var, result_ty)
        | _ ->
            (* Multiple terms. Try to isolate a single-variable linear term and
           solve for it in terms of the remaining terms.
           Prefers meta variables, but also handles dim vars (#N).
           This enables solving e.g. ?m5 + 1 = ?m2 + 2 → ?m5 = ?m2 + 1. *)
            let is_meta_name t =
              String.length t > 2 && t.[0] = '?' && t.[1] = 'm'
            in
            let bind_var_or_meta name result_ty =
              if is_meta_name name then
                match
                  int_of_string_opt (String.sub name 2 (String.length name - 2))
                with
                | Some id -> BindMeta (id, result_ty)
                | None -> BindVar (name, result_ty)
              else BindVar (name, result_ty)
            in
            let is_solvable_name name =
              is_meta_name name || (String.length name > 0 && name.[0] = '#')
            in
            (* Try isolating each single-variable term (only solvable vars) *)
            let try_isolate candidate rest_terms =
              match candidate.vars with
              | [ single_var ]
                when candidate.coeff <> 0 && is_solvable_name single_var -> (
                  (* candidate.coeff * var + rest + const = 0
                 var = -(rest + const) / candidate.coeff *)
                  let rest_canonical =
                    { const = diff.const; terms = rest_terms }
                  in
                  let negated = negate rest_canonical in
                  match try_div_const negated candidate.coeff with
                  | Some result ->
                      let result_ty = from_canonical result in
                      Some (bind_var_or_meta single_var result_ty)
                  | None -> None)
              | _ -> None
            in
            (* Try each term, preferring metas *)
            let meta_terms, other_terms =
              List.partition
                (fun m -> List.exists is_meta_name m.vars)
                diff.terms
            in
            let candidates = meta_terms @ other_terms in
            (* metas first *)
            let rec try_each = function
              | [] -> Stuck
              | t :: rest_candidates -> (
                  let rest_terms =
                    List.filter
                      (fun m -> m.vars <> t.vars || m.coeff <> t.coeff)
                      diff.terms
                  in
                  match try_isolate t rest_terms with
                  | Some result -> result
                  | None -> try_each rest_candidates)
            in
            try_each candidates)
