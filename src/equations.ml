(* -*- compile-command: "COQBIN=~/research/coq/trunk/bin/ make -k -C .. src/equations_plugin.cma src/equations_plugin.cmxs" -*- *)
(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(*i camlp4deps: "parsing/grammar.cma" i*)
(*i camlp4use: "pa_extend.cmo" i*)

(* $Id: equations.ml4 11996 2009-03-20 01:22:58Z letouzey $ *)

open Cases
open Util
open Names
open Nameops
open Term
open Termops
open Declarations
open Inductiveops
open Environ
open Sign
open Reductionops
open Typeops
open Type_errors
open Pp
open Proof_type

open Rawterm
open Retyping
open Pretype_errors
open Evarutil
open Evarconv
open List
open Libnames
open Topconstr

let find_constant contrib dir s =
  constr_of_global (Coqlib.find_reference contrib dir s)

let contrib_name = "Equations"
let init_constant dir s = find_constant contrib_name dir s
let init_reference dir s = Coqlib.find_reference contrib_name dir s

let equations_path = ["Equations";"Equations"]
let coq_dynamic_ind = lazy (init_constant equations_path "dynamic")
let coq_dynamic_constr = lazy (init_constant equations_path "Build_dynamic")
let coq_dynamic_type = lazy (init_constant equations_path "dynamic_type")
let coq_dynamic_obj = lazy (init_constant equations_path "dynamic_obj")

let functional_induction_class () =
  Option.get 
    (Typeclasses.class_of_constr
	(init_constant ["Equations";"FunctionalInduction"] "FunctionalInduction"))

let functional_elimination_class () =
  Option.get 
    (Typeclasses.class_of_constr
	(init_constant ["Equations";"FunctionalInduction"] "FunctionalElimination"))

let dependent_elimination_class () =
  Option.get 
    (Typeclasses.class_of_constr
	(init_constant ["Equations";"DepElim"] "DependentEliminationPackage"))

let below_path = ["Equations";"Below"]
let coq_have_class = lazy (init_constant below_path "Have")
let coq_have_meth = lazy (init_constant below_path "have")

let coq_subterm_class = lazy (init_constant ["Equations";"Subterm"] "SubtermRelation")
let coq_subterm_fam_class = lazy (init_constant ["Equations";"Subterm"] "SubtermFamRelation")
let coq_wffam_class = lazy (init_constant ["Equations";"Subterm"] "WfFam")
let coq_wellfounded = lazy (init_constant ["Coq";"Init";"Wf"] "well_founded")
let coq_relation = lazy (init_constant ["Coq";"Relations";"Relation_Definitions"] "relation")
let coq_clos_trans = lazy (init_constant ["Coq";"Relations";"Relation_Operators"] "clos_trans")
let coq_id = lazy (init_constant ["Coq";"Init";"Datatypes"] "id")

let list_path = ["Lists";"List"]
let coq_list_ind = lazy (init_constant list_path "list")
let coq_list_nil = lazy (init_constant list_path "nil")
let coq_list_cons = lazy (init_constant list_path "cons")

let coq_noconfusion_class = lazy (init_constant ["Equations";"DepElim"] "NoConfusionPackage")
  
let coq_inacc = lazy (init_constant ["Equations";"DepElim"] "inaccessible_pattern")
let coq_hide = lazy (init_constant ["Equations";"DepElim"] "hide_pattern")
let coq_add_pattern = lazy (init_constant ["Equations";"DepElim"] "add_pattern")
let coq_end_of_section_constr = lazy (init_constant ["Equations";"DepElim"] "the_end_of_the_section")
let coq_end_of_section = lazy (init_constant ["Equations";"DepElim"] "end_of_section")

let coq_notT = lazy (init_constant ["Coq";"Init";"Logic_Type"] "notT")
let coq_ImpossibleCall = lazy (init_constant ["Equations";"DepElim"] "ImpossibleCall")

let unfold_add_pattern = lazy
  (Tactics.unfold_in_concl [((false, []), EvalConstRef (destConst (Lazy.force coq_add_pattern)))])

let coq_dynamic_list = lazy (mkApp (Lazy.force coq_list_ind, [| Lazy.force coq_dynamic_ind |]))

let rec constrs_of_coq_dynamic_list c = 
  match kind_of_term c with
  | App (f, args) when f = Lazy.force coq_list_nil -> []
  | App (f, args) when f = Lazy.force coq_list_cons && 
      eq_constr args.(0) (Lazy.force coq_dynamic_ind) && 
      Array.length args = 3 -> 
      (match kind_of_term args.(1) with
      | App (f, args') when f = Lazy.force coq_dynamic_constr &&
	  Array.length args' = 2 ->
	  (args'.(0), args'.(1)) :: constrs_of_coq_dynamic_list args.(2)
      | _ -> raise (Invalid_argument "constrs_of_coq_dynamic_list"))
  | _ -> raise (Invalid_argument "constrs_of_coq_dynamic_list")

let coq_sigma = Lazy.lazy_from_fun Coqlib.build_sigma_type
let coq_unit = lazy (init_constant ["Coq";"Init";"Datatypes"] "unit")
let coq_tt = lazy (init_constant ["Coq";"Init";"Datatypes"] "tt")

let constrs_of_coq_sigma env sigma t alias = 
  let s = Lazy.force coq_sigma in
  let rec aux proj c ty =
    match kind_of_term c with
    | App (f, args) when eq_constr f s.Coqlib.intro && 
	Array.length args = 4 -> 
	(match kind_of_term args.(1) with
	| Lambda (n, b, t) ->
	    let projargs = [| args.(0); args.(1); proj |] in
	    let p1 = mkApp (s.Coqlib.proj1, projargs) in
	    let p2 = mkApp (s.Coqlib.proj2, projargs) in
	      (n, args.(2), p1, args.(0)) :: aux p2 args.(3) t
	| _ -> raise (Invalid_argument "constrs_of_coq_sigma"))
    | _ -> [(Anonymous, c, proj, ty)]
  in aux alias t (Typing.type_of env sigma t)

let decompose_coq_sigma t = 
  let s = Lazy.force coq_sigma in
    match kind_of_term t with
    | App (f, args) when eq_constr f s.Coqlib.typ && 
	Array.length args = 2 -> Some (args.(0), args.(1))
    | _ -> None

open Entries

open Tacmach
open Tacexpr
open Tactics
open Tacticals

let below_tactics_path =
  make_dirpath (List.map id_of_string ["Below";"Equations"])

let below_tac s =
  make_kn (MPfile below_tactics_path) (make_dirpath []) (mk_label s)

let rec_tac h h' = 
  TacArg(TacCall(dummy_loc, 
		ArgArg(dummy_loc, below_tac "rec"),
		[IntroPattern (dummy_loc, Genarg.IntroIdentifier h);
		 IntroPattern (dummy_loc, Genarg.IntroIdentifier h')]))

let tac_of_string str args =
  Tacinterp.interp (TacArg(TacCall(dummy_loc, Qualid (dummy_loc, qualid_of_string str), args)))

let equations_tac_expr () = 
  (TacArg(TacCall(dummy_loc, Qualid (dummy_loc, qualid_of_string "Equations.DepElim.equations"), [])))

let equations_tac () = tac_of_string "Equations.DepElim.equations" []

let set_eos_tac () = tac_of_string "Equations.DepElim.set_eos" []
    
let solve_rec_tac () = tac_of_string "Equations.Below.solve_rec" []

let solve_subterm_tac () = tac_of_string "Equations.Subterm.solve_subterm" []

let noconf_tac () = tac_of_string "Equations.NoConfusion.solve_noconf" []

let simpl_equations_tac () = tac_of_string "Equations.DepElim.simpl_equations" []

let solve_equation_tac c = tac_of_string "Equations.DepElim.solve_equation"
  [ConstrMayEval (ConstrTerm (CDynamic (dummy_loc, Pretyping.constr_in (constr_of_global c))))]

let impossible_call_tac c = Tacinterp.glob_tactic
  (TacArg(TacCall(dummy_loc, 
		 Qualid (dummy_loc, qualid_of_string "Equations.DepElim.impossible_call"),
		 [ConstrMayEval (ConstrTerm (CDynamic (dummy_loc, 
						      Pretyping.constr_in (constr_of_global c))))])))

let depelim_tac h = tac_of_string "Equations.DepElim.depelim"
  [IntroPattern (dummy_loc, Genarg.IntroIdentifier h)]

let do_empty_tac h = tac_of_string "Equations.DepElim.do_empty"
  [IntroPattern (dummy_loc, Genarg.IntroIdentifier h)]

let depelim_nosimpl_tac h = tac_of_string "Equations.DepElim.depelim_nosimpl"
  [IntroPattern (dummy_loc, Genarg.IntroIdentifier h)]

let simpl_dep_elim_tac () = tac_of_string "Equations.DepElim.simpl_dep_elim" []

let depind_tac h = tac_of_string "Equations.DepElim.depind"
  [IntroPattern (dummy_loc, Genarg.IntroIdentifier h)]
  
let mkEq t x y = 
  mkApp (Coqlib.build_coq_eq (), [| t; x; y |])

let mkNot t =
  mkApp (Coqlib.build_coq_not (), [| t |])

let mkNot t =
  mkApp (Coqlib.build_coq_not (), [| t |])
      
let mkProd_or_subst (na,body,t) c =
  match body with
    | None -> mkProd (na, t, c)
    | Some b -> subst1 b c

let mkProd_or_clear decl c =
  if not (dependent (mkRel 1) c) then
    subst1 mkProp c
  else mkProd_or_LetIn decl c

let it_mkProd_or_clear ty ctx = 
  fold_left (fun c d -> mkProd_or_clear d c) ty ctx
      
let mkLambda_or_subst (na,body,t) c =
  match body with
    | None -> mkLambda (na, t, c)
    | Some b -> subst1 b c

let mkLambda_or_subst_or_clear (na,body,t) c =
  match body with
  | None when dependent (mkRel 1) c -> mkLambda (na, t, c)
  | None -> subst1 mkProp c
  | Some b -> subst1 b c

let mkProd_or_subst_or_clear (na,body,t) c =
  match body with
  | None when dependent (mkRel 1) c -> mkProd (na, t, c)
  | None -> subst1 mkProp c
  | Some b -> subst1 b c

let it_mkProd_or_subst ty ctx = 
  nf_beta Evd.empty (whd_betalet Evd.empty
    (List.fold_left (fun c d -> mkProd_or_LetIn d c) ty ctx))

let it_mkLambda_or_subst ty ctx = 
  whd_betalet Evd.empty
    (List.fold_left (fun c d -> mkLambda_or_LetIn d c) ty ctx)

let it_mkLambda_or_subst_or_clear ty ctx = 
  (List.fold_left (fun c d -> mkLambda_or_subst_or_clear d c) ty ctx)

let it_mkProd_or_subst_or_clear ty ctx = 
  (List.fold_left (fun c d -> mkProd_or_subst_or_clear d c) ty ctx)


type pat =
  | PRel of int
  | PCstr of constructor * pat list
  | PInac of constr
  | PHide of int

type user_pat =
  | PUVar of identifier
  | PUCstr of constructor * int * user_pat list
  | PUInac of constr_expr

type user_pats = user_pat list

type context_map = rel_context * pat list * rel_context

let mkInac env c =
  mkApp (Lazy.force coq_inacc, [| Typing.type_of env Evd.empty c ; c |])

let mkHide env c =
  mkApp (Lazy.force coq_hide, [| Typing.type_of env Evd.empty c ; c |])

let rec pat_constr = function
  | PRel i -> mkRel i
  | PCstr (c, p) -> 
      let c' = mkConstruct c in
	mkApp (c', Array.of_list (map pat_constr p))
  | PInac r -> r
  | PHide c -> mkRel c
    
let rec constr_of_pat ?(inacc=true) env = function
  | PRel i -> mkRel i
  | PCstr (c, p) ->
      let c' = mkConstruct c in
	mkApp (c', Array.of_list (constrs_of_pats ~inacc env p))
  | PInac r ->
      if inacc then try mkInac env r with _ -> r else r
  | PHide i -> mkHide env (mkRel i)

and constrs_of_pats ?(inacc=true) env l = map (constr_of_pat ~inacc env) l

let rec pat_vars = function
  | PRel i -> Intset.singleton i
  | PCstr (c, p) -> pats_vars p
  | PInac _ -> Intset.empty
  | PHide _ -> Intset.empty

and pats_vars l =
  fold_left (fun vars p ->
    let pvars = pat_vars p in
    let inter = Intset.inter pvars vars in
      if inter = Intset.empty then
	Intset.union pvars vars
      else error ("Non-linear pattern: variable " ^
		     string_of_int (Intset.choose inter) ^ " appears twice"))
    Intset.empty l

let inaccs_of_constrs l = map (fun x -> PInac x) l

let rec pats_of_constrs l = map pat_of_constr l
and pat_of_constr c =
  match kind_of_term c with
  | Rel i -> PRel i
  | App (f, [| a ; c |]) when eq_constr f (Lazy.force coq_inacc) ->
      PInac c
  | App (f, [| a ; c |]) when eq_constr f (Lazy.force coq_hide) ->
      PHide (destRel c)
  | App (f, args) when isConstruct f ->
      let (ind,_ as cstr) = destConstruct f in
      let nparams, _ = inductive_nargs (Global.env ()) ind in
      let params, args = array_chop nparams args in
      PCstr (cstr, inaccs_of_constrs (Array.to_list params) @ pats_of_constrs (Array.to_list args))
  | Construct f -> PCstr (f, [])
  | _ -> PInac c

(** Specialize by a substitution. *)

let subst_pats_constr k s c = 
  let rec aux depth c =
    match kind_of_term c with
    | Rel n -> 
	let k = n - depth in 
	  if k > 0 then
	    try lift depth (pat_constr (nth s (pred k)))
	    with Failure "nth" -> c
	  else c
    | _ -> map_constr_with_binders succ aux depth c
  in aux k c

let subst_context s ctx =
  let (_, ctx') = fold_right
    (fun (id, b, t) (k, ctx') ->
      (succ k, (id, Option.map (subst_pats_constr k s) b, subst_pats_constr k s t) :: ctx'))
    ctx (0, [])
  in ctx'

let rec specialize s p = 
  match p with
  | PRel i -> (try nth s (pred i) with Failure "nth" -> p)
  | PCstr(c, pl) -> PCstr (c, specialize_pats s pl)
  | PInac r -> PInac (specialize_constr s r)
  | PHide i -> 
      (match nth s (pred i) (* FIXME *) with
      | PRel i -> PHide i
      | PHide i -> PHide i
      | _ -> assert(false))

and specialize_constr s c = subst_pats_constr 0 s c
and specialize_pats s = map (specialize s)

let mapping_constr (s : context_map) c = specialize_constr (pi2 s) c

(* Substitute a constr in a pattern. *)

let rec subst_constr_pat k t p = 
  match p with
  | PRel i -> 
      if i = k then PInac t
      else if i > k then PRel (pred i)
      else p
  | PCstr(c, pl) ->
      PCstr (c, subst_constr_pats k t pl)
  | PInac r -> PInac (substnl [t] (pred k) r)
  | PHide i -> PHide (destRel (substnl [t] (pred k) (mkRel i)))

and subst_constr_pats k t = map (subst_constr_pat k t)

(* Substitute a constr [cstr] in rel_context [ctx] for variable [k]. *)

let subst_rel_context k cstr ctx = 
  let (_, ctx') = fold_right 
    (fun (id, b, t) (k, ctx') ->
      (succ k, (id, Option.map (substnl [cstr] k) b, substnl [cstr] k t) :: ctx'))
    ctx (k, [])
  in ctx'

(* A telescope is a reversed rel_context *)

let subst_telescope cstr ctx = 
  let (_, ctx') = fold_left
    (fun (k, ctx') (id, b, t) ->
      (succ k, (id, Option.map (substnl [cstr] k) b, substnl [cstr] k t) :: ctx'))
    (0, []) ctx
  in rev ctx'

(* Substitute rel [n] by [c] in [ctx]
   Precondition: [c] is typable in [ctx] using variables 
   above [n] *)
    
let subst_in_ctx (n : int) (c : constr) (ctx : rel_context) : rel_context =
  let rec aux k after = function
    | [] -> []
    | (name, b, t as decl) :: before ->
	if k = n then (subst_rel_context 0 (lift (-k) c) (rev after)) @ before
	else aux (succ k) (decl :: after) before
  in aux 1 [] ctx

let set_in_ctx (n : int) (c : constr) (ctx : rel_context) : rel_context =
  let rec aux k after = function
    | [] -> []
    | (name, b, t as decl) :: before ->
	if k = n then (rev after) @ (name, Some (lift (-k) c), t) :: before
	else aux (succ k) (decl :: after) before
  in aux 1 [] ctx

(* Lifting patterns. *)

let rec lift_patn n k p = 
  match p with
  | PRel i ->
      if i >= k then PRel (i + n)
      else p
  | PCstr(c, pl) -> PCstr (c, lift_patns n k pl)
  | PInac r -> PInac (liftn n (succ k) r)
  | PHide r -> PHide (destRel (liftn n (succ k) (mkRel r)))
      
and lift_patns n k = map (lift_patn n k)

let lift_pat n p = lift_patn n 0 p
let lift_pats n p = lift_patns n 0 p

(* Lifting a [rel_context] by [n]. *)

let lift_rel_contextn k n sign =
  let rec liftrec k = function
    | (na,c,t)::sign ->
	(na,Option.map (liftn n k) c,liftn n k t)::(liftrec (k-1) sign)
    | [] -> []
  in
  liftrec (rel_context_length sign + k) sign

let lift_context n sign = lift_rel_contextn 0 n sign

type program = 
  signature * clause list

and signature = identifier * rel_context * constr
  
and clause = lhs * clause rhs
  
and lhs = user_pats

and 'a rhs = 
  | Program of constr_expr
  | Empty of identifier located
  | Rec of identifier located * 'a list
  | Refine of constr_expr * 'a list
  | By of (Tacexpr.raw_tactic_expr, Tacexpr.glob_tactic_expr) union * 'a list

type splitting = 
  | Compute of context_map * types * splitting_rhs
  | Split of context_map * int * types * splitting option array
  | Valid of context_map * types * identifier list * tactic *
      Proof_type.validation * (goal * constr list * context_map * splitting) list
  | RecValid of identifier * splitting
  | Refined of context_map * (identifier * constr * types) * types * int *
      existential_key * (constr * constr list) * context_map * context_map * types *
      splitting

and splitting_rhs = 
  | RProgram of constr
  | REmpty of int
      
and unification_result = 
  (context_map * int * constr * pat) option

type problem = identifier * lhs

let specialize_mapping_constr (m : context_map) c = 
  specialize_constr (pi2 m) c

let rels_of_tele tele = rel_list 0 (List.length tele)

let patvars_of_tele tele = map (fun c -> PRel (destRel c)) (rels_of_tele tele)

let pat_vars_list n = list_tabulate (fun i -> PRel (succ i)) n

let intset_of_list =
  fold_left (fun s x -> Intset.add x s) Intset.empty

let split_context n c =
  let after, before = list_chop n c in
    match before with
    | hd :: tl -> after, hd, tl
    | [] -> raise (Invalid_argument "split_context")

let split_tele n (ctx : rel_context) =
  let rec aux after n l =
    match n, l with
    | 0, decl :: before -> before, decl, List.rev after
    | n, decl :: before -> aux (decl :: after) (pred n) before
    | _ -> raise (Invalid_argument "split_tele")
  in aux [] n ctx

(* Compute the transitive closure of the dependency relation for a term in a context *)

let rels_above ctx x =
  let len = List.length ctx in
    intset_of_list (list_tabulate (fun i -> x + succ i) (len - x))

let is_fix_proto t =
  match kind_of_term t with
  | App (f, args) when eq_constr f (Lazy.force Subtac_utils.fix_proto) ->
      true
  | _ -> false

let fix_rels ctx =
  list_fold_left_i (fun i acc (_, _, t) -> 
    if is_fix_proto t then Intset.add i acc else acc)
    1 Intset.empty ctx

let rec dependencies_of_rel ctx k =
  let (n,b,t) = nth ctx (pred k) in
  let b = Option.map (lift k) b and t = lift k t in
  let bdeps = match b with Some b -> dependencies_of_term ctx b | None -> Intset.empty in
    Intset.union (Intset.singleton k) (Intset.union bdeps (dependencies_of_term ctx t))

and dependencies_of_term ctx t =
  let rels = free_rels t in
    Intset.fold (fun i -> Intset.union (dependencies_of_rel ctx i)) rels Intset.empty

let non_dependent ctx c =
  list_fold_left_i (fun i acc (_, _, t) -> 
    if not (dependent (lift (-i) c) t) then Intset.add i acc else acc)
    1 Intset.empty ctx
        
let strengthen ?(full=true) (ctx : rel_context) x (t : constr) =
  let rels = Intset.union (if full then rels_above ctx x else Intset.singleton x)
    (* (Intset.union *) (Intset.union (dependencies_of_term ctx t) (fix_rels ctx))
    (* (non_dependent ctx t)) *)
  in
  let len = length ctx in
  let nbdeps = Intset.cardinal rels in
  let lifting = len - nbdeps in (* Number of variables not linked to t *)
  let rec aux k n acc m rest s = function
    | decl :: ctx' ->
	if Intset.mem k rels then
	  let rest' = subst_telescope (mkRel (nbdeps + lifting - pred m)) rest in
	    aux (succ k) (succ n) (decl :: acc) m rest' (Inl n :: s) ctx'
	else aux (succ k) n (subst_telescope mkProp acc) (succ m) (decl :: rest) (Inr m :: s) ctx'
    | [] -> rev acc, rev rest, s
  in
  let (min, rest, subst) = aux 1 1 [] 1 [] [] ctx in
  let ctx' = rest @ min in
  let lenrest = length rest in
  let subst = rev subst in
  let reorder = list_map_i (fun i -> function Inl x -> (x + lenrest, i) | Inr x -> (x, i)) 1 subst in
  let subst = map (function Inl x -> PRel (x + lenrest) | Inr x -> PRel x) subst in
    (ctx', subst, ctx), reorder

let id_subst g = (g, rev (patvars_of_tele g), g)
	
let eq_named_context_nolet g d =
  try 
    List.fold_left2 (fun acc (na,_,t) (na',_,t') ->
      acc && na = na' && t = t') true g d
  with Invalid_argument "List.fold_left2" -> false

let compose_subst ((g',p',d') : context_map) ((g,p,d) : context_map) =
  assert (eq_named_context_nolet g d');
  g', specialize_pats p' p, d

let push_mapping_context (n, b, t as decl) (g,p,d) =
  ((n, Option.map (specialize_constr p) b, specialize_constr p t) :: g,
  (PRel 1 :: map (lift_pat 1) p), decl :: d)
    
let lift_subst (ctx : context_map) (g : rel_context) = 
  List.fold_right (fun decl acc -> push_mapping_context decl acc) g ctx
    
let single_subst x p g =
  let t = pat_constr p in
    if eq_constr t (mkRel x) then
      id_subst g
    else if noccur_between 1 x t then
      (* The term to substitute refers only to previous variables. *)
      let substctx = subst_in_ctx x t g in
      let pats = list_tabulate
      	(fun i -> let k = succ i in
      		    if k = x then (lift_pat (-1) p) else if k > x then PRel (pred k) else PRel k)
      	(List.length g)
      (* let substctx = set_in_ctx x t g in *)
      (* let pats = list_tabulate  *)
      (* 	(fun i -> let k = succ i in if k = x then p else PRel k) *)
      (* 	(List.length g) *)
      in substctx, pats, g
    else
      let (ctx, s, g), _ = strengthen g x t in
      let x' = match nth s (pred x) with PRel i -> i | _ -> error "Occurs check singleton subst"
      and t' = specialize_constr s t in
	(* t' is in ctx. Do the substitution of [x'] by [t] now 
	   in the context and the patterns. *)
      let substctx = subst_in_ctx x' t' ctx in
      let pats = list_map_i (fun i p -> subst_constr_pat x' (lift (-1) t') p) 1 s in
	substctx, pats, g
    
exception Conflict
exception Stuck

type 'a unif_result = UnifSuccess of 'a | UnifFailure | UnifStuck
      
let rec unify flex g x y =
  if eq_constr x y then id_subst g
  else
    match kind_of_term x with
    | Rel i -> 
	if Intset.mem i flex then
	  single_subst i (PInac y) g
	else raise Stuck
    | _ ->
	match kind_of_term y with
	| Rel i ->
	    if Intset.mem i flex then
	      single_subst i (PInac x) g
	    else raise Stuck
	| _ ->
	    let (c, l) = decompose_app x 
	    and (c', l') = decompose_app y in
	      if isConstruct c && isConstruct c' then
		if eq_constr c c' then
		  unify_constrs flex g l l'
		else raise Conflict
	      else raise Stuck

and unify_constrs flex g l l' = 
  match l, l' with
  | [], [] -> id_subst g
  | hd :: tl, hd' :: tl' ->
      let (d,s,_ as hdunif) = unify flex g hd hd' in
      let specrest = map (specialize_constr s) in
      let tl = specrest tl and tl' = specrest tl' in
      let tlunif = unify_constrs flex d tl tl' in
	compose_subst tlunif hdunif
  | _, _ -> raise Conflict

let flexible pats gamma =
  let (_, flex) =
    fold_left2 (fun (k,flex) pat decl ->
      match pat with
      | PInac _ -> (succ k, Intset.add k flex)
      | p -> (succ k, flex))
      (1, Intset.empty) pats gamma
  in flex

let rec accessible = function
  | PRel i -> Intset.singleton i
  | PCstr (c, l) -> accessibles l
  | PInac _ | PHide _ -> Intset.empty

and accessibles l =
  fold_left (fun acc p -> Intset.union acc (accessible p)) 
    Intset.empty l
  
let hidden = function PHide _ -> true | _ -> false

let rec match_pattern p c =
  match p, c with
  | PUVar i, t -> [i, t]
  | PUCstr (c, i, pl), PCstr (c', pl') -> 
      if c = c' then
	let params, args = list_chop i pl' in
	  match_patterns pl args
      else raise Conflict
  | PUInac _, _ -> []
  | _, _ -> raise Stuck

and match_patterns pl l =
  match pl, l with
  | [], [] -> []
  | hd :: tl, hd' :: tl' -> 
      let l = 
	try Some (match_pattern hd hd')
	with Stuck -> None
      in
      let l' = 
	try Some (match_patterns tl tl')
	with Stuck -> None
      in
	(match l, l' with
	| Some l, Some l' -> l @ l'
	| _, _ -> raise Stuck)
  | _ -> raise Conflict
      

open Constrintern

let matches (p : user_pats) ((phi,p',g') : context_map) = 
  try
    let p' = filter (fun x -> not (hidden x)) (rev p') in
      UnifSuccess (match_patterns p p')
  with Conflict -> UnifFailure | Stuck -> UnifStuck

let rec match_user_pattern p c =
  match p, c with
  | PRel i, t -> [i, t]
  | PCstr (c', pl'), PUCstr (c, i, pl) -> 
      if c = c' then
	let params, args = list_chop i pl' in
	  match_user_patterns args pl
      else raise Conflict
  | PCstr _, PUVar _ -> []
  | PInac _, _ -> []
  | _, _ -> raise Stuck

and match_user_patterns pl l =
  match pl, l with
  | [], [] -> []
  | hd :: tl, hd' :: tl' -> 
      let l = 
	try Some (match_user_pattern hd hd')
	with Stuck -> None
      in
      let l' = 
	try Some (match_user_patterns tl tl')
	with Stuck -> None
      in
	(match l, l' with
	| Some l, Some l' -> l @ l'
	| _, _ -> raise Stuck)
  | _ -> raise Conflict
      
let matches_user ((phi,p',g') : context_map) (p : user_pats) = 
  try UnifSuccess (match_user_patterns (filter (fun x -> not (hidden x)) (rev p')) p)
  with Conflict -> UnifFailure | Stuck -> UnifStuck
    
let interp_constr_in_rhs env evars (i,impls) ty s c =
  let ctxs,ctx,len = fold_left (fun (ctx',cs,k) (id, pat) -> 
    let c = pat_constr pat in
    let ty = Typing.type_of env !evars c in
      ((Name id, Some (lift k c), lift k ty) :: ctx', (c :: cs), succ k))
    ([],[],0) s 
  in
    match ty with
    | None -> 
	let c, _ = interp_constr_evars_impls ~evdref:evars ~fail_evar:false
	  (push_rel_context ctxs env) ~impls c 
	in
	let c' = substnl ctx 0 c in
	  evars := Typeclasses.resolve_typeclasses ~onlyargs:false env !evars;
	  let c' = nf_evar !evars c' in
	    c', Typing.type_of env !evars c'
	    
    | Some ty -> 
	let ty' = lift len ty in
	let ty' = nf_evar !evars ty' in
	let c, _ = interp_casted_constr_evars_impls ~evdref:evars ~fail_evar:false
	  (push_rel_context ctxs env) ~impls c ty'
	in
	  evars := Typeclasses.resolve_typeclasses ~onlyargs:false env !evars;
	  let c' = nf_evar !evars (substnl ctx 0 c) in
	    c', nf_evar !evars (substnl ctx 0 ty')
	  
let unify_type evars before id ty after =
  try
    let envids = ids_of_rel_context before @ ids_of_rel_context after in
    let envb = push_rel_context before (Global.env()) in
    let IndType (indf, args) = find_rectype envb !evars ty in
    let ind, params = dest_ind_family indf in
    let vs = map (Tacred.simpl envb !evars) args in
    let cstrs = Inductiveops.type_of_constructors envb ind in
    let cstrs = 
      Array.mapi (fun i ty ->
	let ty = prod_applist ty params in
	let ctx, ty = decompose_prod_assum ty in
	let ctx, ids = 
	  fold_right (fun (n, b, t) (acc, ids) ->
	    match n with
	    | Name id -> ((n, b, t) :: acc), (id :: ids)
	    | Anonymous ->
		let x = Namegen.id_of_name_using_hdchar
		  (push_rel_context acc envb) t Anonymous in
		let id = Namegen.next_name_away (Name x) ids in
		  ((Name id, b, t) :: acc), (id :: ids))
	    ctx ([], envids)
	in
	let env' = push_rel_context ctx (Global.env ()) in
	let IndType (indf, args) = find_rectype env' !evars ty in
	let ind, params = dest_ind_family indf in
	let constr = applist (mkConstruct (ind, succ i), params @ rels_of_tele ctx) in
	let q = inaccs_of_constrs (rels_of_tele ctx) in	
	let constrpat = PCstr ((ind, succ i), inaccs_of_constrs params @ patvars_of_tele ctx) in
	  env', ctx, constr, constrpat, q, args)
	cstrs
    in
    let res = 
      Array.map (fun (env', ctxc, c, cpat, q, us) -> 
	let _beforelen = length before and ctxclen = length ctxc in
	let fullctx = ctxc @ before in
	  try
	    let vs' = map (lift ctxclen) vs in
	    let p1 = lift_pats ctxclen (inaccs_of_constrs (rels_of_tele before)) in
	    let flex = flexible (p1 @ q) fullctx in
	    let s = unify_constrs flex fullctx vs' us in
	      UnifSuccess (s, ctxclen, c, cpat)
	  with Conflict -> UnifFailure | Stuck -> UnifStuck) cstrs
    in Some res
  with Not_found -> (* not an inductive type *)
    None

let blockers curpats ((_, patcs, _) : context_map) =
  let rec pattern_blockers p c =
    match p, c with
    | PUVar i, t -> []
    | PUCstr (c, i, pl), PCstr (c', pl') -> 
	if c = c' then patterns_blockers pl (snd (list_chop i pl'))
	else []
    | PUInac _, _ -> []
    | _, PRel i -> [i]
    | _, _ -> []

  and patterns_blockers pl l =
    match pl, l with
    | [], [] -> []
    | hd :: tl, PHide _ :: tl' -> patterns_blockers pl tl'
    | hd :: tl, hd' :: tl' -> 
	(pattern_blockers hd hd') @ (patterns_blockers tl tl')
    | _ -> []
	
  in patterns_blockers curpats (rev patcs)
    
open Termops

let pr_constr_pat env c =
  let pr = print_constr_env env c in
    match kind_of_term c with
    | App _ -> str "(" ++ pr ++ str ")"
    | _ -> pr

let pr_pat env c =
  let patc = constr_of_pat env c in
    pr_constr_pat env patc

let pr_context env c =
  let pr_decl env (id,b,t) = 
    let bstr = match b with Some b -> str ":=" ++ spc () ++ print_constr_env env b | None -> mt() in
    let idstr = match id with Name id -> pr_id id | Anonymous -> str"_" in
      idstr ++ bstr ++ str " : " ++ print_constr_env env t
  in
  let (_, pp) =
    match List.rev c with
    | decl :: decls -> 
	List.fold_left (fun (env, pp) decl ->
	  (push_rel decl env, pp ++ str ";" ++ spc () ++ pr_decl env decl))
	  (push_rel decl env, pr_decl env decl) decls
    | [] -> env, mt ()
  in pp

let ppcontext c = pp (pr_context (Global.env ()) c)

let pr_context_map env (delta, patcs, gamma) =
  let env' = push_rel_context delta env in
  let ctx = pr_context env delta in
  let ctx' = pr_context env gamma in
    (if delta = [] then ctx else str "[" ++ ctx ++ str "]" ++ spc ())
    ++ prlist_with_sep spc (pr_pat env') (List.rev patcs) ++
      str ": ["  ++ ctx' ++ str "]"

let ppcontext_map context_map = pp (pr_context_map (Global.env ()) context_map)

open Printer
open Ppconstr

let rec pr_user_pat env = function
  | PUVar i -> pr_id i
  | PUCstr (c, i, f) -> 
      let pc = pr_constructor env c in
	if f <> [] then str "(" ++ pc ++ spc () ++ pr_user_pats env f ++ str ")"
	else pc
  | PUInac c -> str "?(" ++ pr_constr_expr c ++ str ")"

and pr_user_pats env pats =
  prlist_with_sep spc (pr_user_pat env) pats

let pr_lhs = pr_user_pats

let pplhs lhs = pp (pr_lhs (Global.env ()) lhs)

let rec pr_rhs env = function
  | Empty (loc, var) -> spc () ++ str ":=!" ++ spc () ++ pr_id var
  | Rec ((loc, var), s) -> spc () ++ str "!" ++ spc () ++ pr_id var ++ spc () ++
      hov 1 (str "{" ++ pr_clauses env s ++ str "}")
  | Program rhs -> spc () ++ str ":=" ++ spc () ++ pr_constr_expr rhs
  | Refine (rhs, s) -> spc () ++ str "<=" ++ spc () ++ pr_constr_expr rhs ++ 
      spc () ++ str "=>" ++ spc () ++
      hov 1 (str "{" ++ pr_clauses env s ++ str "}")
  | By (Inl tac, s) -> spc () ++ str "by" ++ spc () ++ Pptactic.pr_raw_tactic env tac
      ++ spc () ++ hov 1 (str "{" ++ pr_clauses env s ++ str "}")
  | By (Inr tac, s) -> spc () ++ str "by" ++ spc () ++ Pptactic.pr_glob_tactic env tac
      ++ spc () ++ hov 1 (str "{" ++ pr_clauses env s ++ str "}")
      
and pr_clause env (lhs, rhs) =
  pr_lhs env lhs ++ pr_rhs env rhs

and pr_clauses env =
  prlist_with_sep fnl (pr_clause env)

let ppclause clause = pp(pr_clause (Global.env ()) clause)
    
let subst_matches_constr k s c = 
  let rec aux depth c =
    match kind_of_term c with
    | Rel n -> 
 	let k = n - depth in 
	  if k >= 0 then 
	    try lift depth (assoc k s)
	    with Not_found -> c
	  else c
    | _ -> map_constr_with_binders succ aux depth c
  in aux k c

let is_all_variables (delta, pats, gamma) =
  List.for_all (function PInac _ | PHide _ -> true | PRel _ -> true | PCstr _ -> false) pats

let do_renamings ctx =
  let avoid, ctx' =
    List.fold_right (fun (n, b, t) (ids, acc) ->
      match n with
      | Name id -> 
	  let id' = Namegen.next_ident_away id ids in
	  let decl' = (Name id', b, t) in
	    (id' :: ids, decl' :: acc)
      | Anonymous -> assert false)
      ctx ([], [])
  in ctx'

let split_var (env,evars) var delta =
  (* delta = before; id; after |- curpats : gamma *)	    
  let before, (id, _, ty as decl), after = split_tele (pred var) delta in
  let unify = unify_type evars before id ty after in
  let branch = function
    | UnifFailure -> None
    | UnifStuck -> assert false
    | UnifSuccess ((ctx',s,ctx), ctxlen, cstr, cstrpat) ->
	(* ctx' |- s : before ; ctxc *)
	    (* ctx' |- cpat : ty *)
	let cpat = specialize s cstrpat in
	let ctx' = do_renamings ctx' in
	(* ctx' |- spat : before ; id *)
	let spat =
	  let ctxcsubst, beforesubst = list_chop ctxlen s in
	    (ctx', cpat :: beforesubst, decl :: before)
	in
	  (* ctx' ; after |- safter : before ; id ; after = delta *)
	  Some (lift_subst spat after)
  in
    match unify with
    | None -> None
    | Some unify ->
	(* Some constructor's type is not refined enough to match ty *)
	if array_exists (fun x -> x = UnifStuck) unify then
	  None
	else Some (var, Array.map branch unify)

let split env vars delta =
  let split = fold_left (fun acc var ->
    match acc with 
    | None -> split_var env var delta 
    | _ -> acc) None vars
  in split

let find_empty env delta =
  let r = List.filter (fun v -> 
    match split_var env v delta with
    | None -> false
    | Some (v, r) -> array_for_all (fun x -> x = None) r)
    (list_tabulate (fun i -> succ i) (List.length delta))
  in match r with x :: _ -> Some x | _ -> None
    
open Evd
open Refiner

let rel_of_named_context ctx = 
  List.fold_right (fun (n,b,t) (ctx',subst) ->
    let decl = (Name n, Option.map (subst_vars subst) b, subst_vars subst t) in 
      (decl :: ctx', n :: subst)) ctx ([],[])
    
let variables_of_pats pats = 
  let rec aux acc pats = 
    List.fold_right (fun p acc ->
      match p with
      | PRel i -> (i, false) :: acc
      | PCstr (c, ps) -> aux [] (rev ps) @ acc
      | PInac _ -> acc
      | PHide i -> (i, true) :: acc)
      pats acc
  in aux [] pats

let pats_of_variables = map (fun (i, hide) ->
  if hide then PHide i else PRel i)

let lift_rel_declaration k (n, b, t) =
  (n, Option.map (lift k) b, lift k t)

let named_of_rel_context l =
  List.fold_right
    (fun (na, b, t) (subst, ctx) ->
      let id = match na with Anonymous -> raise (Invalid_argument "named_of_rel_context") | Name id -> id in
      let d = (id, Option.map (substl subst) b, substl subst t) in
	(mkVar id :: subst, d :: ctx))
    l ([], [])
    
let lookup_named_i id =
  let rec aux i = function
    | (id',_,_ as decl) :: _ when id=id' -> i, decl
    | _ :: sign -> aux (succ i) sign
    | [] -> raise Not_found
  in aux 1
	
let instance_of_pats env evars (ctx : rel_context) (pats : (int * bool) list) =
  let subst, nctx = named_of_rel_context ctx in
  let subst = map destVar subst in
  let ctx' =
    List.fold_right (fun (i, hide) ctx' ->
      let decl =
	let id = List.nth subst (pred i) in
  	let i, decl = lookup_named_i id nctx in
  	  decl
      in decl :: ctx')
      pats []
  in
  let pats' =
    list_map_i (fun i id ->
      let i', _ = lookup_named_i id ctx' in
	list_try_find (fun (i'', hide) ->
	  if i'' = i then if hide then PHide i' else PRel i'
	  else failwith "") pats)
      1 subst
  in
  let pats'' =
    list_map_i (fun i (id, b, t) ->
      let i', _ = lookup_named_i id nctx in
	list_try_find (fun (i'', hide) ->
	  if i'' = i' then if hide then PHide i else PRel i
	  else failwith "") pats)
      1 ctx'
  in fst (rel_of_named_context ctx'), pats', pats''

let push_rel_context_eos ctx env =
  if named_context env <> [] then
    let env' =
      push_named (id_of_string "eos", Some (Lazy.force coq_end_of_section_constr), 
		 Lazy.force coq_end_of_section) env
    in push_rel_context ctx env'
  else push_rel_context ctx env
    
let split_at_eos ctx =
  fst (list_split_when (fun (id, b, t) ->
    eq_constr t (Lazy.force coq_end_of_section)) ctx)

let rec covering_aux env evars data prev (clauses : clause list) (ctx,pats,ctx' as prob) ty =
  match clauses with
  | (lhs, rhs as clause) :: clauses' -> 
      (match matches lhs prob with
      | UnifSuccess s -> 
	  let prevmatch = List.filter (fun (lhs',rhs') -> matches lhs' prob <> UnifFailure) prev in
	    if prevmatch = [] then
	      let env' = push_rel_context_eos ctx env in
		match rhs with
		| Program c -> 
		    let c', _ = interp_constr_in_rhs env' evars data (Some ty) s c in
		      Some (Compute (prob, ty, RProgram c'))

		| Empty (loc,i) ->
		    (match assoc i s with
		    | PRel i -> Some (Compute (prob, ty, REmpty i))
		    | _ -> user_err_loc (loc, "equations", str"Unbound variable " ++ pr_id i))

		| Rec (v, s) ->
		    let tac = By (Inr (rec_tac (snd v) (fst data)), s) in
		      (match covering_aux env evars data [] [(lhs,tac)] prob ty with
		      | None -> None
		      | Some split -> Some (RecValid (fst data, split)))
					    
		| By (tac, s) ->
		    let sign, t', rels = push_rel_context_to_named_context env' ty in
		    let sign' = split_at_eos (named_context_of_val sign) in
		    let ids = List.map pi1 sign' in
		    let tac = match tac with
		      | Inl tac -> Tacinterp.interp_tac_gen [] ids Tactic_debug.DebugOff tac 
		      | Inr tac -> Tacinterp.eval_tactic tac
		    in
		    let goal = {it = make_evar sign t'; sigma = !evars} in
		    let gls, valid = tac goal in
		      if gls.it = [] then 
			let pftree = valid [] in
			let c, _ = extract_open_proof !evars pftree in
			  Some (Compute (prob, ty, RProgram c))
		      else
			let solve_goal evi =
			  let nctx = named_context_of_val evi.evar_hyps in
			  let nctx = split_at_eos nctx in
			  let rctx, subst = rel_of_named_context nctx in
			  let ty' = subst_vars subst evi.evar_concl in
			  let ty', prob, subst = match kind_of_term ty' with
			    | App (f, args) -> 
				if eq_constr f (Lazy.force coq_add_pattern) then
				  let comp = args.(1) and newpattern = pat_of_constr args.(2) 
				  and _newpatty = args.(0) in
				  let _newpatname = match kind_of_term args.(2) with 
				    | Rel n -> pi1 (lookup_rel n (push_rel_context rctx env))
				    | _ -> Name (id_of_string "newpattern")
				  in
				  let pats = rev_map pat_of_constr (snd (decompose_app comp)) in
				  let newprob = 
				    rctx, (newpattern :: pats), rctx
				    (* ((newpatname, None, newpatty) :: ctx') *)
				  in 
				  let ty' = 
				    match newpattern with
				    | PHide _ -> comp
				    | _ -> ty'
				  in ty', newprob, (rctx, pats, ctx)
				else 
				  let pats = rev_map pat_of_constr (Array.to_list args) in
				  let newprob = rctx, pats, ctx' in
				    ty', newprob, id_subst ctx'
			    | _ -> raise (Invalid_argument "covering_aux: unexpected output of tactic call")
			  in 
			    match covering_aux env evars data [] s prob ty' with
			      | None ->
				  anomalylabstrm "covering"
				    (str "Unable to find a covering for the result of a by clause:" 
				      ++ fnl () ++ pr_clause env clause ++
				      spc () ++ str"refining" ++ spc () ++ pr_context_map env prob)
			      | Some s ->
				  let args = rev (list_map_filter (fun (id,b,t) ->
				    if b = None then Some (mkVar id) else None) nctx) 
				  in evi, args, subst, s
			in Some (Valid (prob, ty, ids, tac, valid, map solve_goal gls.it))


		| Refine (c, cls) -> 
		    let vars = variables_of_pats pats in
		    let newctx, pats', pats'' = instance_of_pats env evars ctx vars in
		    let _s' = (ctx, vars, newctx) in
		    let revctx = (newctx, pats', ctx) in
		    let cconstr, cty = interp_constr_in_rhs env' evars data None s c in
		    let idref = Namegen.next_ident_away (id_of_string "refine") (ids_of_rel_context newctx) in
		    let decl = (Name idref, None, mapping_constr revctx cty) in
		    let extnewctx = decl :: newctx in
		      (* cmap : Δ -> ctx, cty *)
		    let cmap, strinv = strengthen ~full:true extnewctx 1
		      (lift 1 (mapping_constr revctx cconstr)) 
		    in
 		    let cconstr' = mapping_constr cmap cconstr in
		    let cty' = mapping_constr cmap cty in
		    let newprob = (extnewctx, PRel 1 :: lift_pats 1 pats'', extnewctx) in
		    let newprob = compose_subst cmap newprob in
		    let refterm = lift 1 (mapping_constr revctx cconstr) in
		    let newty = subst_term_occ all_occurrences refterm
		      (Tacred.simpl (push_rel_context extnewctx env) !evars (lift 1 (mapping_constr revctx ty)))
		    in
		    let newty = mapping_constr cmap newty in
		    let rec cls' n cls =
		      list_map_filter (fun (lhs, rhs) -> 
			let oldpats, newpats = list_chop (List.length lhs - n) lhs in
			  match matches_user prob oldpats with
			  | UnifSuccess s -> (* A substitution from the problem variables to user patterns *)
			      let newlhs = 
				list_map_filter 
				  (fun (i, hide) ->
				    if hide then None
				    else Some (List.assoc i s))
				  vars
			      in
			      let newrhs = match rhs with
				| Refine (c, cls) -> Refine (c, cls' (succ n) cls)
				| Rec (v, s) -> Rec (v, cls' n s)
				| By (v, s) -> By (v, cls' n s)
				| _ -> rhs
			      in
				Some (rev (rev newpats @ newlhs), newrhs)
			  | _ -> 
			      errorlabstrm "covering"
				(str "Non-matching clause in with subprogram:" ++ fnl () ++
				    str"Problem is " ++ spc () ++ pr_context_map env prob ++ 
				    str"And the user patterns are: " ++ fnl () ++
				    pr_user_pats env lhs)) cls
		    in
		    let cls' = cls' 1 cls in
		    let strength_app, refarg =
		      let sortinv = List.sort (fun (i, _) (i', _) -> i' - i) strinv in
		      let argref = ref 0 in
		      let args = 
			map (fun (i, j) (* i variable in strengthened context, 
					   j variable in the original one *) -> 
			  if j = 1 then (argref := (List.length strinv - i); 
					 cconstr)
			  else let (var, _) = List.nth vars (pred (pred j)) in
				 mkRel var) sortinv
		      in args, !argref
		    in
		    let evar = new_untyped_evar () in
		      match covering_aux env evars data [] cls' newprob newty with
		      | None -> None
		      | Some s -> 
			  Some (Refined (prob, (idref, cconstr', cty'),
					ty, refarg, evar,
					(mkEvar (evar, [||]), strength_app),
					revctx, newprob, newty, s))
	    else 
	      anomalylabstrm "covering"
		(str "Found overlapping clauses:" ++ fnl () ++ pr_clauses env prevmatch ++
		    spc () ++ str"refining" ++ spc () ++ pr_context_map env prob)

      | UnifFailure -> covering_aux env evars data (clause :: prev) clauses' prob ty
      | UnifStuck -> 
	  let blocks = blockers lhs prob in
	    fold_left (fun acc var ->
	      match acc with
	      | None -> 
		  (match split_var (env,evars) var (pi1 prob) with
		  | Some (var, s) ->
		      let coverrec s = covering_aux env evars data []
			(List.rev prev @ clauses) (compose_subst s prob)
			(specialize_constr (pi2 s) ty)
		      in
			(try 
			    let rest = Array.map (Option.map (fun x -> 
			      match coverrec x with
			      | None -> raise Not_found
			      | Some s -> s)) s 
			    in Some (Split (prob, var, ty, rest))
			  with Not_found -> None)
		  | None -> None) 
	      | _ -> acc) None blocks)
  | [] -> (* Every clause failed for the problem, it's either uninhabited or
	     the clauses are not exhaustive *)
      match find_empty (env,evars) (pi1 prob) with
      | Some i -> Some (Compute (prob, ty, REmpty i))
      | None ->
	  errorlabstrm "deppat"
	    (str "Non-exhaustive pattern-matching, no clause found for:" ++ fnl () ++
		pr_context_map env prob)

let covering env evars data (clauses : clause list) prob ty =
  match covering_aux env evars data [] clauses prob ty with
  | Some cov -> cov
  | None ->
      errorlabstrm "deppat"
	(str "Unable to build a covering for:" ++ fnl () ++
	    pr_context_map env prob)
    
open Evd
open Evarutil

let helper_evar isevar evar env typ src =
  let sign, typ', instance = push_rel_context_to_named_context env typ in
  let evm' = evar_declare sign evar typ' ~src !isevar in
    isevar := evm'; mkEvar (evar, Array.of_list instance)

let term_of_tree status isevar env (i, delta, ty) ann tree =
  let oblevars = ref Intset.empty in
  let helpers = ref [] in
  let rec aux = function
    | Compute ((ctx, _, _), ty, RProgram rhs) -> 
	let body = it_mkLambda_or_LetIn rhs ctx and typ = it_mkProd_or_subst ty ctx in
	  body, typ

    | Compute ((ctx, _, _), ty, REmpty split) ->
	let split = (Name (id_of_string "split"), 
		    Some (Class_tactics.coq_nat_of_int (succ (length ctx - split))),
		    Lazy.force Class_tactics.coq_nat)
	in
	let ty' = it_mkProd_or_LetIn ty ctx in
	let let_ty' = mkLambda_or_LetIn split (lift 1 ty') in
	let term = e_new_evar isevar env ~src:(dummy_loc, QuestionMark (Define true)) let_ty' in
	let ev = fst (destEvar term) in
	  oblevars := Intset.add ev !oblevars;
	  term, ty'
	   
    | RecValid (id, rest) -> aux rest

    | Refined ((ctx, _, _), (id, c, _), ty, rarg, ev, (f, args), revctx, newprob, newty, rest) ->
	let sterm, sty = aux rest in
	let term, ty = 
	  let term = mkLetIn (Name (id_of_string "prog"), sterm, sty, lift 1 sty) in
	  let term = helper_evar isevar ev (Global.env ()) term (dummy_loc, QuestionMark (Define false)) in
	    oblevars := Intset.add ev !oblevars;
	    helpers := (ev, rarg) :: !helpers;
	    term, ty
	in
	let term = applist (f, args) in
	let term = it_mkLambda_or_LetIn term ctx in
	let ty = it_mkProd_or_subst ty ctx in
	  term, ty

    | Valid ((ctx, _, _), ty, substc, tac, valid, rest) ->
	let goal_of_rest goal args (term, ty) = 
	  { open_subgoals = 0;
	    goal = goal;
	    ref = Some (Prim (Proof_type.Refine (applistc term args)), []) }
	in
	let pftree = valid (map (fun (goal, args, subst, x) -> goal_of_rest goal args (aux x)) rest) in
	let c, _ = extract_open_proof !isevar pftree in
	  it_mkLambda_or_LetIn (subst_vars substc c) ctx, it_mkProd_or_LetIn ty ctx

    | Split ((ctx, _, _), rel, ty, sp) -> 
	let before, decl, after = split_tele (pred rel) ctx in
	let branches = 
	  Array.map (fun split -> 
	    match split with
	    | Some s -> aux s
	    | None ->
		(* dead code, inversion will find a proof of False by splitting on the rel'th hyp *)
		Class_tactics.coq_nat_of_int rel, Lazy.force Class_tactics.coq_nat)
	    sp 
	in
	let branches_ctx =
	  Array.mapi (fun i (br, brt) -> (id_of_string ("m_" ^ string_of_int i), Some br, brt))
	    branches
	in
	let n, branches_lets =
	  Array.fold_left (fun (n, lets) (id, b, t) ->
	    (succ n, (Name id, Option.map (lift n) b, lift n t) :: lets))
	    (0, []) branches_ctx
	in
	let liftctx = lift_context (Array.length branches) ctx in
	let case =
	  let ty = it_mkProd_or_LetIn ty liftctx in
	  let ty = it_mkLambda_or_LetIn ty branches_lets in
	  let nbbranches = (Name (id_of_string "branches"),
			   Some (Class_tactics.coq_nat_of_int (length branches_lets)),
			   Lazy.force Class_tactics.coq_nat)
	  in
	  let nbdiscr = (Name (id_of_string "target"),
			Some (Class_tactics.coq_nat_of_int (length before)),
			Lazy.force Class_tactics.coq_nat)
	  in
	  let ty = it_mkLambda_or_LetIn (lift 2 ty) [nbbranches;nbdiscr] in
	  let term = e_new_evar isevar env ~src:(dummy_loc, QuestionMark status) ty in
	  let ev = fst (destEvar term) in
	    oblevars := Intset.add ev !oblevars;
	    term
	in       
	let casetyp = it_mkProd_or_subst ty ctx in
	  mkCast(case, DEFAULTcast, casetyp), casetyp
  in 
  let term, typ = aux tree in
    !helpers, !oblevars, term, typ

open Constrintern
open Decl_kinds

type pat_expr = 
  | PEApp of identifier located * pat_expr located list
  | PEWildcard
  | PEInac of constr_expr

type pre_equation = (identifier located * pat_expr located list *
			pre_equation rhs)

let next_ident_away s ids =
  let n' = Namegen.next_ident_away s !ids in
    ids := n' :: !ids; n'

let rec ids_of_pats pats =
  fold_left (fun ids (_,p) ->
    match p with
    | PEApp ((loc,f), l) -> (f :: ids_of_pats l) @ ids
    | PEWildcard -> ids
    | PEInac _ -> ids)
    [] pats
    
type rec_type = 
  | Structural
  | Logical of (constant * constr * constant) (* comp, comp applied to rels, comp projection *)

let lift_constrs n cs = map (lift n) cs

let list_try_find_i f i l =
  snd 
    (fold_left (fun (i, acc) x ->
      match acc with
      | None -> (succ i, f i x)
      | Some _ -> (i, acc))
	(i, None) l)
    
let array_remove_last a =
  Array.sub a 0 (Array.length a - 1)

let array_chop_last a =
  array_chop (Array.length a - 1) a

let abstract_rec_calls ?(do_subst=true) is_rec len protos c =
  let lenprotos = length protos in
  let proto_fs = map (fun (f, _, _, _) -> f) protos in
  let find_rec_call f =
    try Some (List.find (fun (f', alias, idx, arity) ->
      eq_constr (fst (decompose_app f')) f || alias = Some f) protos) 
    with Not_found -> None
  in
  let find_rec_call f args =
    match find_rec_call f with
    | Some (f', _, i, arity) -> 
	let args' = snd (array_chop (length (snd (decompose_app f'))) args) in
	Some (i, arity, args')
    | None -> 
	match is_rec with
	| Some (Logical (c, capp, proj)) when eq_constr (mkConst proj) f -> 
	    Some (lenprotos - 1, capp, array_remove_last args)
	| _ -> None
  in
  let rec aux n c =
    match kind_of_term c with
    | App (f', args) ->
	let (ctx, lenctx, args) = 
	  Array.fold_left (fun (ctx,len,c) arg -> 
	    let ctx', lenctx', arg' = aux n arg in
	    let len' = lenctx' + len in
	    let ctx'' = lift_context len ctx' in
	    let c' = (liftn len (succ lenctx') arg') :: map (lift lenctx') c in
	      (ctx''@ctx, len', c'))
	    ([],0,[]) args
	in
	let args = Array.of_list (List.rev args) in
	let f' = lift lenctx f' in
	  (match find_rec_call f' args with
	  | Some (i, arity, args') ->
	      let resty = substl (rev (Array.to_list args')) arity in
	      let result = (Name (id_of_string "recres"), Some (mkApp (f', args)), resty) in
	      let hypty = mkApp (mkApp (mkRel (i + len + lenctx + 2 + n), 
				       Array.map (lift 1) args'), [| mkRel 1 |]) 
	      in
	      let hyp = (Name (id_of_string "reccall"), None, hypty) in
		[hyp;result]@ctx, lenctx + 2, mkRel 2
	  | None -> (ctx, lenctx, mkApp (f', args)))

    (* | Cast (_, _, f) when is_comp f -> aux n f *)
	  
    | LetIn (na,b,t,c) ->
	let ctx',lenctx',b' = aux n b in
	let ctx'',lenctx'',c' = aux (succ n) c in
	let ctx'' = lift_rel_contextn 1 lenctx' ctx'' in
	let fullctx = ctx'' @ [na,Some b',lift lenctx' t] @ ctx' in
	  fullctx, lenctx'+lenctx''+1, liftn lenctx' (lenctx'' + 2) c'

    | Prod (na, d, c) when not (dependent (mkRel 1) c)  -> 
	let ctx',lenctx',d' = aux n d in
	let ctx'',lenctx'',c' = aux n (subst1 mkProp c) in
	  lift_context lenctx' ctx'' @ ctx', lenctx' + lenctx'', 
	mkProd (na, lift lenctx'' d', 
	       liftn lenctx' (lenctx'' + 2) 
		 (lift 1 c'))

    | Case (ci, p, c, br) ->
	let ctx', lenctx', c' = aux n c in
	let case' = mkCase (ci, lift lenctx' p, c', Array.map (lift lenctx') br) in
	  ctx', lenctx', substnl proto_fs (succ len + lenctx') case'

    | _ -> [], 0, if do_subst then (substnl proto_fs (len + n) c) else c
  in aux 0 c

let below_transparent_state () =
  Auto.Hint_db.transparent_state (Auto.searchtable_map "Below")

let simpl_star = 
  tclTHEN simpl_in_concl (onAllHyps (fun id -> simpl_in_hyp (id, InHyp)))

let eauto_with_below l =
  Class_tactics.typeclasses_eauto
    ~st:(below_transparent_state ()) (l@["subterm_relation"; "Below"])

let simp_eqns l =
  tclREPEAT (tclTHENLIST [Autorewrite.autorewrite tclIDTAC l;
			  (* simpl_star; Autorewrite.autorewrite tclIDTAC l; *)
			  tclTRY (eauto_with_below l)])

let simp_eqns_in clause l =
  tclREPEAT (tclTHENLIST 
		[simpl_star; Autorewrite.auto_multi_rewrite l clause;
		 tclTRY (eauto_with_below l)])

let autorewrites b = tclREPEAT (Autorewrite.autorewrite tclIDTAC [b])

let autorewrite_one b = Rewrite.cl_rewrite_clause_strat 
  (Rewrite.one_subterm (Rewrite.Strategies.hints b))
  None

type term_info = {
  base_id : string;
  helpers_info : (existential_key * int * identifier) list }

let find_helper_info info f =
  try List.find (fun (ev', arg', id') ->
    eq_constr (global_reference id') f) info.helpers_info
  with Not_found -> anomaly "Helper not found while proving induction lemma."

let find_helper_arg info f args =
  let (ev, arg, id) = find_helper_info info f in
    args.(arg)
      
let rec aux_ind_fun info = function
  | Split ((ctx,pats,_), var, _, splits) ->
      let before, (na, b, t), after = split_context (pred var) ctx in
      let id = out_name na in
      (* let splits = list_map_filter (fun x -> x) (Array.to_list splits) in *)
	tclTHEN_i (fun gl ->
	  try depelim_nosimpl_tac id gl
	  with _ -> 
	    depelim_nosimpl_tac (pi1 (List.nth (pf_hyps gl) (pred var))) gl) 
	  (fun i -> 
	    match splits.(pred i) with
	    | None -> simpl_dep_elim_tac ()
	    | Some s ->
		tclTHEN (simpl_dep_elim_tac ())
		  (aux_ind_fun info s))
	  
  | Valid ((ctx, _, _), ty, substc, tac, valid, rest) -> tclTHEN intros
      (tclTHEN_i tac (fun i -> let _, _, subst, split = nth rest (pred i) in
				 tclTHEN (Lazy.force unfold_add_pattern) 
				   (aux_ind_fun info split)))
      
  | RecValid (id, cs) -> aux_ind_fun info cs
      
  | Refined ((ctx, _, _), (id, c, ty), _, _, _, _, _, newprob, newty, s) -> 
      let elimtac gl =
	match kind_of_term (pf_concl gl) with
	| App (ind, args) ->
	    let last_arg = args.(Array.length args - 1) in
	    let f, args = destApp last_arg in
	    let elim = find_helper_arg info f args in
	      tclTHENLIST
		[letin_tac None (Name id) elim None allHypsAndConcl; 
		 clear_body [id]; aux_ind_fun info s] gl
	| _ -> tclFAIL 0 (str"Unexpected refinement goal in functional induction proof") gl
      in
      let cstrtac =
	tclTHENLIST [autorewrite_one info.base_id; any_constructor false None]
      in tclTHENLIST [ intros; tclTHENLAST cstrtac (tclSOLVE [elimtac]); solve_rec_tac ()]
	
  | Compute (_, _, _) ->
      tclTHENLIST [intros; simp_eqns [info.base_id]]
	
  (* | Compute ((ctx,_,_), _, REmpty id) -> *)
  (*     let (na,_,_) = nth ctx (pred id) in *)
  (*     let id = out_name na in *)
  (* 	do_empty_tac id *)

let ind_fun_tac is_rec f info fid split ind =
  if is_rec = Some Structural then
    let c = constant_value (Global.env ()) (destConst f) in
    let i = let (inds, _), _ = destFix c in inds.(0) in
    let recid = add_suffix fid "_rec" in
      (* tclCOMPLETE  *)
      (tclTHENLIST
	  [fix (Some recid) (succ i);
	   onLastDecl (fun (n,b,t) gl ->
	     let sort = pf_type_of gl t in
	     let fixprot = mkApp (Lazy.force Subtac_utils.fix_proto, [|sort; t|]) in
	       change_in_hyp None fixprot (n, InHyp) gl);
	   intros; aux_ind_fun info split])
  else tclCOMPLETE (aux_ind_fun info split)
    
let mapping_rhs s = function
  | RProgram c -> RProgram (mapping_constr s c)
  | REmpty i -> 
      try match nth (pi2 s) (pred i) with 
      | PRel i' -> REmpty i'
      | _ -> assert false
      with Not_found -> assert false

let map_rhs f g = function
  | RProgram c -> RProgram (f c)
  | REmpty i -> REmpty (g i)

let clean_clause (ctx, pats, ty, c) =
  (ctx, pats, ty, 
  map_rhs (nf_beta Evd.empty) (fun x -> x) c)

let map_evars_in_constr evar_map c = 
  evar_map (fun id -> 
    constr_of_global (Nametab.locate (Libnames.make_short_qualid id))) c

let map_split f split =
  let rec aux = function
    | Compute (lhs, ty, RProgram c) -> Compute (lhs, ty, RProgram (f c))
    | Split (lhs, y, z, cs) -> Split (lhs, y, z, Array.map (Option.map aux) cs)
    | RecValid (id, c) -> RecValid (id, aux c)
    | Valid (lhs, y, z, w, u, cs) ->
	Valid (lhs, y, z, w, u, List.map (fun (gl, cl, subst, s) -> (gl, cl, subst, aux s)) cs)
    | Refined (lhs, (id, c, cty), ty, arg, ev, (scf, scargs), revctx, newprob, newty, s) -> 
	Refined (lhs, (id, f c, f cty), ty, arg, ev,
		(f scf, List.map f scargs), revctx, newprob, newty, aux s)
    | Compute (_, _, REmpty _) as c -> c
  in aux split

let map_evars_in_split m = map_split (map_evars_in_constr m)

let subst_rec_split f prob s split = 
  let subst_rec cutprob s (ctx, _, _ as lhs) =
    let subst = 
      fold_left (fun (ctx, _, _ as lhs) (id, b) ->
	let n, _ = lookup_rel_id id ctx in
	let substf = single_subst n (PInac b) ctx in
	  compose_subst substf lhs) (id_subst ctx) s
    in
      subst, compose_subst subst (compose_subst lhs cutprob)
  in
  let rec aux cutprob s = function
    | Compute ((ctx,pats,del as lhs), ty, c) ->
	let subst, lhs' = subst_rec cutprob s lhs in	  
	  Compute (lhs', mapping_constr subst ty, mapping_rhs subst c)
	  
    | Split (lhs, x, y, cs) -> 
	let subst, lhs' = subst_rec cutprob s lhs in
	  Split (lhs', x, y, Array.map (Option.map (aux cutprob s)) cs)
	  
    | RecValid (id, c) ->
	RecValid (id, aux cutprob s c)
	  
    | Refined (lhs, (id, constr, cty), ty, arg, ev, (fev, args), revctx, newprob, newty, sp) -> 
	let subst, lhs' = subst_rec cutprob s lhs in
        let _, revctx' = subst_rec (id_subst (pi3 revctx)) s revctx in
	let cutnewprob = 
	  let (ctx, pats, ctx') = newprob in
	    (ctx, list_drop_last pats, list_drop_last ctx')
	in
	let subst', newprob' = subst_rec cutnewprob s newprob in
	let sc' = 
	  let recprots, args = list_chop (List.length s) args in
	    (mapping_constr subst (applist (fev, recprots)),
	    map (mapping_constr subst) args)
	in
	  Refined (lhs', (id, mapping_constr subst constr, mapping_constr subst cty),
		  mapping_constr subst ty, arg - List.length s, ev, sc', 
		  revctx',
		  newprob', mapping_constr subst' newty, 
		  aux cutnewprob s sp)

    | Valid (lhs, x, y, w, u, cs) -> 
	let subst, lhs' = subst_rec cutprob s lhs in
	  Valid (lhs', x, y, w, u, 
		List.map (fun (g, l, subst, sp) -> (g, l, subst, aux cutprob s sp)) cs)
  in aux prob s split

type statement = constr * types option
type statements = statement list

let subst_app f fn c = 
  let rec aux n c =
    match kind_of_term c with
    | App (f', args) when eq_constr f f' -> fn n f' args
    | _ -> map_constr_with_binders succ aux n c
  in aux 0 c
  
let subst_comp_proj f proj c =
  subst_app proj (fun n x args -> 
    mkApp (f, Array.sub args 0 (Array.length args - 1)))
    c

let subst_comp_proj_split f proj s =
  map_split (subst_comp_proj f proj) s

let reference_of_id s = 
  Ident (dummy_loc, s)

let clear_ind_assums ind ctx = 
  let rec clear_assums c =
    match kind_of_term c with
    | Prod (na, b, c) ->
	let t, _ = decompose_app b in
	  if eq_constr t ind then (
	    assert(not (dependent (mkRel 1) c));
	    clear_assums (subst1 mkProp c))
	  else mkProd (na, b, clear_assums c)
    | _ -> c
  in map_rel_context clear_assums ctx

let ind_elim_tac indid inds info = 
  let applyind gl =
    let hyps = pf_hyps gl in
    let last_hyps = list_lastn inds hyps in
    let app = applistc indid (rev_map (fun decl -> mkVar (pi1 decl)) last_hyps) in
      apply app gl
  in
    tclTHENLIST [intros; applyind;
		 Class_tactics.typeclasses_eauto [info.base_id]]

let declare_constant id body ty kind =
  let ce =
    { const_entry_body = body;
      const_entry_type = ty;
      const_entry_opaque = false;
      const_entry_boxed = false}
  in Declare.declare_constant id (DefinitionEntry ce, kind)
    
let declare_instance id ctx cl args =
  let c, t = Typeclasses.instance_constructor cl args in
  let cst = declare_constant id (it_mkLambda_or_LetIn c ctx)
    (Some (it_mkProd_or_LetIn t ctx)) (IsDefinition Instance)
  in 
  let inst = Typeclasses.new_instance cl None true (ConstRef cst) in
    Typeclasses.add_instance inst

let build_equations with_ind env id info data sign is_rec arity cst 
    f ?(alias:(constr * constr * splitting) option) prob split =
  let rec computations prob f = function
    | Compute (lhs, ty, c) ->
	let (ctx', pats', _) = compose_subst lhs prob in
	let c' = map_rhs (nf_beta Evd.empty) (fun x -> x) c in
	let patsconstrs = rev_map pat_constr pats' in
	  [ctx', patsconstrs, ty, f, c', None]
	    
    | Split (_, _, _, cs) -> Array.fold_left (fun acc c ->
	match c with None -> acc | Some c -> 
	  acc @ computations prob f c) [] cs

    | RecValid (id, cs) -> computations prob f cs
	
    | Refined (lhs, (id, c, t), ty, arg, ev, (f', args), revctx, newprob, newty, cs) ->
	let (ctx', pats', _) = compose_subst lhs prob in
	let patsconstrs = rev_map pat_constr pats' in
	  [ctx', patsconstrs, ty, f, RProgram (applist (f', args)),
	  Some (f', pi1 newprob, newty,
	       map (mapping_constr revctx) patsconstrs, [mapping_constr revctx c],
	       computations newprob f' cs)]
	    
    | Valid ((ctx,pats,del), _, _, _, _, cs) -> 
	List.fold_left (fun acc (_, _, subst, c) ->
	  acc @ computations (compose_subst subst prob) f c) [] cs
  in
  let comps = computations prob f split in
  let rec flatten_comp (ctx, pats, ty, f, c, rest) =
    let rest = match rest with
      | None -> []
      | Some (f, ctx, ty, pats, newargs, rest) ->
	  let nextlevel, rest = flatten_comps rest in
	    ((f, ctx, ty, pats, newargs), nextlevel) :: rest
    in (ctx, pats, ty, f, c), rest
  and flatten_comps r =
    fold_right (fun cmp (acc, rest) -> 
      let stmt, rest' = flatten_comp cmp in
	(stmt :: acc, rest' @ rest)) r ([], [])
  in
  let comps =
    let (top, rest) = flatten_comps comps in
      ((f, sign, arity, rev_map pat_constr (pi2 prob), []), top) :: rest
  in
  let protos = map fst comps in
  let lenprotos = length protos in
  let protos = 
    list_map_i (fun i (f', sign, arity, pats, args) -> 
      (f', (if f' = f then Option.map pi1 alias else None), lenprotos - i, arity))
      1 protos
  in
  let rec statement i f (ctx, pats, ty, f', c) =
    let comp = applistc f pats in
    let body =
      let b = match c with
	| RProgram c ->
	    mkEq ty comp (nf_beta Evd.empty c)
	| REmpty i ->
	    (* mkLetIn (Anonymous, comp, ty,  *)
	    mkApp (Lazy.force coq_ImpossibleCall, [| ty; comp |])
      in it_mkProd_or_LetIn b ctx
    in
    let cstr = 
      match c with
      | RProgram c ->
	  let len = List.length ctx in
	  let hyps, hypslen, c' = abstract_rec_calls is_rec len protos (nf_beta Evd.empty c) in
	    Some (it_mkProd_or_clear
		     (it_mkProd_or_subst
			 (applistc (mkRel (len + (lenprotos - i) + hypslen))
			     (lift_constrs hypslen pats @ [c']))
			 hyps) ctx)
      | REmpty i -> None
    in (body, cstr)
  in
  let statements i ((f', sign, arity, pats, args as fs), c) = 
    let fs, unftac = 
      if f' = f then 
	match alias with
	| Some (f', unf, split) -> 
	    (f', sign, arity, pats, args), Equality.rewriteLR unf
	| None -> fs, tclIDTAC
      else fs, tclIDTAC
    in fs, unftac, map (statement i f') c in
  let stmts = list_map_i statements 0 comps in
  let all_stmts = list_map_i (fun i (f, unf, c) -> i, f, unf, list_map_i (fun j x -> j, x) 1 c) 0 stmts in
  let declare_one_ind (i, (f, sign, arity, pats, refs), unf, stmts) = 
    let indid = add_suffix id (if i = 0 then "_ind" else ("_ind_" ^ string_of_int i)) in
    let constructors = list_map_filter (fun (_, (_, n)) -> n) stmts in
    let consnames = list_map_filter (fun (i, (_, n)) -> 
      Option.map (fun _ -> add_suffix indid ("_equation_" ^ string_of_int i)) n) stmts
    in
      { mind_entry_typename = indid;
	mind_entry_arity = it_mkProd_or_LetIn (mkProd (Anonymous, arity, mkProp)) sign;
	mind_entry_consnames = consnames;	      
	mind_entry_lc = constructors }
  in
  let declare_ind () =
    let inds = map declare_one_ind all_stmts in
    let inductive =
      { mind_entry_record = false;
	mind_entry_finite = true;
	mind_entry_params = []; (* (identifier * local_entry) list; *)
	mind_entry_inds = inds }
    in
    let k = Command.declare_mutual_inductive_with_eliminations false inductive [] in
    let ind = mkInd (k,0) in
    let _ =
      list_iter_i (fun i ind ->
	let constrs = list_map_i (fun j _ -> None, true, mkConstruct ((k,i),j)) 1 ind.mind_entry_lc in
	  Auto.add_hints false [info.base_id] (Auto.HintsResolveEntry constrs))
	inds
    in
    let indid = add_suffix id "_ind_fun" in
    let args = rel_list 0 (List.length sign) in
    let f, split = match alias with Some (f, _, split) -> f, split | None -> f, split in
    let app = applist (f, args) in
    let statement = it_mkProd_or_subst (applist (ind, args @ [app])) sign in
    let hookind _ gr = 
      let env = Global.env () in (* refresh *)
      let cgr = constr_of_global gr in
      Auto.add_hints false [info.base_id] (Auto.HintsImmediateEntry [cgr]);
      let _funind_stmt =
	let leninds = List.length inds in
	let elim =
	  if leninds > 1 then
	    (Indschemes.do_mutual_induction_scheme
		(list_map_i (fun i ind ->
		  let id = (dummy_loc, add_suffix ind.mind_entry_typename "_mut") in
		    (id, false, (k, i), RProp Null)) 0 inds);
	     let elimid = 
	       add_suffix (List.hd inds).mind_entry_typename "_mut"
	     in Smartlocate.global_with_alias (reference_of_id elimid))
	  else 
	    let elimid = add_suffix id "_ind_ind" in
	      Smartlocate.global_with_alias (reference_of_id elimid) 
	in
	let elimty = Global.type_of_global elim in
	let ctx, arity = decompose_prod_assum elimty in
	let newctx = list_skipn 2 ctx in
	let newarity = substl [mkProp; app] arity in
	let newctx' = clear_ind_assums ind newctx in
	let newctx' =
	  if leninds = 1 then newctx'
	  else
	    let methods, preds = list_chop (List.length newctx - leninds) newctx' in
	    let ppred, preds = list_sep_last preds in
	    let newpreds =
	      list_map2_i (fun i (n, b, t) (_, (f', sign, arity, pats, args), _, _) ->
		let signlen = List.length sign in
		let ctx = (Anonymous, None, arity) :: sign in
		let app = 
		  let papp =
		    applistc (lift (succ signlen) (mkRel 1) (* The preceding P *)) 
		      ((map (lift (List.length args + 1)) pats) @ [mkRel 1])
		  in
		  let refeqs =
		    list_map_i (fun i c -> 
		      let ty = lift (i + 2) (pi3 (List.nth sign i)) in
			mkEq ty (lift 2 c) (mkRel (i + 2)))
		      0 args
		  in
		  let app = fold_right
		    (fun c acc ->
		      mkProd (Anonymous, c, lift 1 acc))
		    refeqs papp
		  in
		  let indhyps =
		    concat 
		      (map (fun c ->
			let hyps, hypslen, c' = 
			  abstract_rec_calls ~do_subst:false
			    is_rec signlen protos (nf_beta Evd.empty (lift 2 c)) 
			in hyps) args)
		  in
		    it_mkLambda_or_LetIn
		      (it_mkProd_or_LetIn (lift (length indhyps) app) indhyps)
		      ctx
		in
		let ty = it_mkProd_or_LetIn mkProp ctx in
		  (n, Some app, ty)) 1 preds (rev (List.tl all_stmts))
	    in methods @ newpreds @ [ppred]
	in
	let hookelim _ elimgr =
	  let env = Global.env () in
	  let elimcgr = constr_of_global elimgr in
	  let cl = functional_elimination_class () in
	  let args = [Typing.type_of env Evd.empty f; f; 
		      Typing.type_of env Evd.empty elimcgr; elimcgr]
	  in
	  let instid = add_prefix "FunctionalElimination_" id in
	    declare_instance instid [] cl args 
	in
	  Subtac_obligations.add_definition (add_suffix id "_elim")
	    ~tactic:(ind_elim_tac (constr_of_global elim) leninds info)
	    ~hook:hookelim
	    (it_mkProd_or_LetIn newarity newctx') [||]
      in
      let cl = functional_induction_class () in
      let args = [Typing.type_of env Evd.empty f; f; 
		  Typing.type_of env Evd.empty cgr; cgr]
      in
      let instid = add_prefix "FunctionalInduction_" id in
	declare_instance instid [] cl args;
    in
      try ignore(Subtac_obligations.add_definition ~hook:hookind
		    indid statement ~tactic:(ind_fun_tac is_rec f info id split ind) [||])
      with e ->
	warn (str "Induction principle could not be proved automatically: " ++ fnl () ++
		 Cerrors.explain_exn e)
	  (* ignore(Subtac_obligations.add_definition ~hook:hookind indid statement [||]) *)
  in
  let proof (j, f, unf, stmts) =
    let eqns = Array.make (List.length stmts) false in
    let id = if j <> 0 then add_suffix id ("_helper_" ^ string_of_int j) else id in
    let proof (i, (c, n)) = 
      let ideq = add_suffix id ("_equation_" ^ string_of_int i) in
      let hook _ gr = 
	if n <> None then
	  Autorewrite.add_rew_rules info.base_id 
	    [dummy_loc, constr_of_global gr, true, Tacexpr.TacId []]
	else (Classes.declare_instance true (dummy_loc, Nametab.basename_of_global gr);
	      Auto.add_hints false [info.base_id] 
		(Auto.HintsExternEntry (0, None, impossible_call_tac (ConstRef cst))));
	eqns.(pred i) <- true;
	if array_for_all (fun x -> x) eqns then (
	  (* From now on, we don't need the reduction behavior of the constant anymore *)
	  Typeclasses.set_typeclass_transparency (EvalConstRef cst) false;
	  Conv_oracle.set_strategy (ConstKey cst) Conv_oracle.Opaque;
	  if with_ind && succ j = List.length all_stmts then declare_ind ())
      in
	ignore(Subtac_obligations.add_definition
		  ideq c ~tactic:(tclTHENLIST [intros; unf; solve_equation_tac (ConstRef cst)]) ~hook [||])
    in iter proof stmts
  in iter proof all_stmts

open Typeclasses

let rev_assoc k =
  let rec loop = function
    | [] -> raise Not_found | (v,k')::_ when k = k' -> v | _ :: l -> loop l 
  in
  loop

type equation_option = 
  | OInd | ORec | OComp | OEquations

let is_comp_obl comp t =
  let _, rest = decompose_prod_assum t in
  let f, _ = decompose_app rest in
    eq_constr f comp

let hintdb_set_transparency cst b db =
  Auto.add_hints false [db] 
    (Auto.HintsTransparencyEntry ([EvalConstRef cst], b))

let define_tree is_recursive impls status isevar env (i, sign, arity) ann split hook =
  let helpers, oblevs, t, ty = term_of_tree status isevar env (i, sign, arity) ann split in
  let _ = isevar := nf_evars !isevar in
  let undef = undefined_evars !isevar in
  let obls, (emap, cmap), t', ty' = 
    Eterm.eterm_obligations env i !isevar undef 0 ~status t (whd_betalet !isevar ty)
  in
  let obls = 
    Array.map (fun (id, ty, loc, s, d, t) ->
      let tac = 
	if Intset.mem (rev_assoc id emap) oblevs 
	then Some (equations_tac ()) 
	else Some (tclTHEN (tclTRY (solve_rec_tac ()))
		      (Subtac_obligations.default_tactic ()))
      in (id, ty, loc, s, d, tac)) obls
  in
  let term_info = map (fun (ev, arg) ->
    (ev, arg, List.assoc ev emap)) helpers
  in
  let hook = hook cmap term_info in
    if is_recursive = Some Structural then
      ignore(Subtac_obligations.add_mutual_definitions [(i, t', ty', impls, obls)] [] 
		~hook (Subtac_obligations.IsFixpoint [None, CStructRec]))
    else
      ignore(Subtac_obligations.add_definition ~hook
		~implicits:impls i ~term:t' ty' obls)

let conv_proj_call proj f_cst c =
  let rec aux n c =
    match kind_of_term c with
    | App (f, args) when eq_constr f proj ->
	mkApp (mkConst f_cst, array_remove_last args)
    | _ -> map_constr_with_binders succ aux n c
  in aux 0 c

let convert_projection proj f_cst = fun gl ->
  let concl = pf_concl gl in
  let concl' = conv_proj_call proj f_cst concl in
    if eq_constr concl concl' then tclIDTAC gl
    else convert_concl_no_check concl' DEFAULTcast gl

let unfold_constr c = 
  unfold_in_concl [(all_occurrences, EvalConstRef (destConst c))]

let prove_unfolding_lemma info sign proj f_cst funf_cst split gl =
  let depelim h = depelim_tac h in
  let simpltac = tclTHEN (tclREPEAT (Eauto.autounfold ["Below_recursors"] None)) 
    (simpl_equations_tac ())
  in
  let abstract tac = tclABSTRACT None tac in
  let rec aux = function
    | Split ((ctx,pats,_), var, _, splits) ->
	let before, (na, b, t), after = split_context (pred var) ctx in
	let id = out_name na in
	let splits = list_map_filter (fun x -> x) (Array.to_list splits) in
	  abstract (tclTHEN_i (depelim id)
		       (fun i -> let split = nth splits (pred i) in
				   aux split))
	    
    | Valid ((ctx, _, _), ty, substc, tac, valid, rest) -> 
	tclTHEN_i tac (fun i -> let _, _, subst, split = nth rest (pred i) in
				  tclTHEN (Lazy.force unfold_add_pattern) (aux split))

    | RecValid (id, cs) -> 
	tclTHEN simpltac (aux cs)
	
    | Refined ((ctx, _, _), (id, c, ty), _, arg, ev, _, _, newprob, newty, s) -> 
	let reftac gl = 
	  match kind_of_term (pf_concl gl) with
	  | App (f, [| ty; term1; term2 |]) ->
	      let f1, arg1 = destApp term1 and f2, arg2 = destApp term2 in
	      let a1 = find_helper_arg info f1 arg1 
	      and a2 = find_helper_arg info f2 arg2 in
		tclTHENLIST
		  [Equality.replace_by a1 a2
		      (tclTHENLIST [simpltac; reflexivity]);
		   letin_tac None (Name id) a2 None allHypsAndConcl; aux s] gl
	  | _ -> tclFAIL 0 (str"Unexpected unfolding lemma goal") gl
	in
	  abstract (tclTHENLIST [intros; simpltac; reftac])
	    
    | Compute (_, _, RProgram c) ->
	abstract (tclTHENLIST [intros; simpltac; 
			       reflexivity])

    | Compute ((ctx,_,_), _, REmpty id) ->
	let (na,_,_) = nth ctx (pred id) in
	let id = out_name na in
	  abstract (depelim id)
  in
  let unfolds = unfold_in_concl 
    [((true, [1]), EvalConstRef f_cst); ((true, [1]), EvalConstRef funf_cst)]
  in
    tclORELSE
      (tclTHENLIST [set_eos_tac (); intros; unfolds;
		    (fun gl -> 
		      Conv_oracle.set_strategy (ConstKey f_cst) Conv_oracle.Opaque;
		      Conv_oracle.set_strategy (ConstKey funf_cst) Conv_oracle.Opaque;
		      aux split gl)])
      (fun gl -> 
	Conv_oracle.set_strategy (ConstKey f_cst) Conv_oracle.Expand;
	Conv_oracle.set_strategy (ConstKey funf_cst) Conv_oracle.Expand;
	tclIDTAC gl) gl
      
let update_split is_rec cmap f prob id split =
  let split' = map_evars_in_split cmap split in
    match is_rec with
    | Some Structural -> subst_rec_split f prob [(id, f)] split'
    | Some (Logical (comp, compapp, proj)) ->
	subst_comp_proj_split f (mkConst proj) split'
    | _ -> split'

let interp_eqn i is_rec isevar env impls sign arity recu eqn =
  let avoid = ref [] in
  let rec interp_pat (loc, p) =
    match p with
    | PEApp ((loc,f), l) -> 
	(try match Nametab.extended_locate (make_short_qualid f) with
	| TrueGlobal (ConstructRef c) -> 
	    let (ind,_) = c in
	    let nparams, _ = inductive_nargs env ind in
	    let nargs = constructor_nrealargs env c in
	    let len = List.length l in
	    let l' =
	      if len < nargs then 
		list_make (nargs - len) (loc,PEWildcard) @ l
	      else l
	    in 
	      Dumpglob.add_glob loc (ConstructRef c);
	      PUCstr (c, nparams, map interp_pat l')
	| _ -> 
	    if l <> [] then 
	      user_err_loc (loc, "interp_pats",
			   str "Pattern variable " ++ pr_id f ++ str" cannot be applied ")
	    else PUVar f
	  with Not_found -> PUVar f)
    | PEInac c -> PUInac c
    | PEWildcard -> let n = next_ident_away (id_of_string "wildcard") avoid in
		      avoid := n :: !avoid; PUVar n
  in
  let rec aux ((loc,id), pats, rhs) =
    avoid := !avoid @ ids_of_pats pats;
    if id <> i then
      user_err_loc (loc, "interp_pats",
		   str "Expecting a pattern for " ++ pr_id i);
    Dumpglob.dump_reference loc "<>" (string_of_id id) "def";
    (*   if List.length pats <> List.length sign then *)
    (*     user_err_loc (loc, "interp_pats", *)
    (* 		 str "Patterns do not match the signature " ++  *)
    (* 		   pr_rel_context env sign); *)
    let pats = map interp_pat pats in
      match is_rec with
      | Some Structural -> (PUVar i :: pats, interp_rhs None rhs)
      | Some (Logical (_, _, compproj)) -> (pats, interp_rhs (Some (ConstRef compproj)) rhs)
      | None -> (pats, interp_rhs None rhs)
  and interp_rhs compproj = function
    | Refine (c, eqs) -> Refine (interp_constr_expr compproj !avoid c, map aux eqs)
    | Program c -> Program (interp_constr_expr compproj !avoid c)
    | Empty i -> Empty i
    | Rec (i, s) -> Rec (i, map aux s)
    | By (x, s) -> By (x, map aux s)
  and interp_constr_expr compproj ids c = 
    match c, compproj with
    (* |   | CAppExpl of loc * (proj_flag * reference) * constr_expr list *)
    | CApp (loc, (None, CRef (Ident (loc',id'))), args), Some compproj when i = id' ->
	let qidproj = Nametab.shortest_qualid_of_global Idset.empty compproj in
	  CApp (loc, (None, CRef (Qualid (loc', qidproj))), args)
    | _ -> map_constr_expr_with_binders (fun id l -> id :: l) 
	(interp_constr_expr compproj) ids c
  in aux eqn
	
let define_by_eqs opts i (l,ann) t nt eqs =
  let with_comp, with_rec, with_eqns, with_ind =
    let try_opt default opt =
      try List.assoc opt opts with Not_found -> default
    in
      try_opt true OComp, try_opt true ORec, 
    try_opt true OEquations, try_opt true OInd
  in
  let env = Global.env () in
  let isevar = ref (create_evar_defs Evd.empty) in
  let (env', sign), impls = interp_context_evars isevar env l in
  let arity = interp_type_evars isevar env' t in
  let sign = nf_rel_context_evar ( !isevar) sign in
  let arity = nf_evar ( !isevar) arity in
  let arity, comp = 
    if with_comp then
      let compid = add_suffix i "_comp" in
      let body = it_mkLambda_or_LetIn arity sign in
      let ce =
	{ const_entry_body = body;
	  const_entry_type = None;
	  const_entry_opaque = false;
	  const_entry_boxed = false}
      in
      let comp =
	Declare.declare_constant compid (DefinitionEntry ce, IsDefinition Definition)
      in (*Typeclasses.add_constant_class c;*)
      let compapp = mkApp (mkConst comp, rel_vect 0 (length sign)) in
      let projid = add_suffix i "_comp_proj" in
      let compproj = 
	let body = it_mkLambda_or_LetIn (mkRel 1)
	  ((Name (id_of_string "comp"), None, compapp) :: sign)
	in
	let ce =
	  { const_entry_body = body;
	    const_entry_type = None;
	    const_entry_opaque = false;
	    const_entry_boxed = false}
	in Declare.declare_constant projid (DefinitionEntry ce, IsDefinition Definition)
      in
	Impargs.declare_manual_implicits true (ConstRef comp) impls;
	Impargs.declare_manual_implicits true (ConstRef compproj) 
	  (impls @ [ExplByPos (succ (List.length sign), None), (true, false, true)]);
	hintdb_set_transparency comp false "Below";
	hintdb_set_transparency comp false "subterm_relation";
	compapp, Some (comp, compapp, compproj)
    else arity, None
  in
  let env = Global.env () in (* To find the comp constant *)
  let ty = it_mkProd_or_LetIn arity sign in
  let data = Constrintern.compute_full_internalization_env
    env Constrintern.Recursive [] [i] [ty] [impls] 
  in
  let sort = Retyping.get_type_of env !isevar ty in
  let fixprot = mkApp (Lazy.force Subtac_utils.fix_proto, [|sort; ty|]) in
  let fixdecls = [(Name i, None, fixprot)] in
  let is_recursive =
    let rec occur_eqn (_, _, rhs) =
      match rhs with
      | Program c -> occur_var_constr_expr i c
      | Refine (c, eqs) -> occur_var_constr_expr i c || exists occur_eqn eqs
      | _ -> false
    in
      if with_rec && exists occur_eqn eqs then Some Structural 
      else if not with_rec then Option.map (fun c -> Logical c) comp
      else None
  in
  let equations = 
    States.with_heavy_rollback (fun () -> 
      Option.iter (Metasyntax.set_notation_for_interpretation data) nt;
      map (interp_eqn i is_recursive isevar env data sign arity None) eqs) ()
  in
  let sign = nf_rel_context_evar ( !isevar) sign in
  let arity = nf_evar ( !isevar) arity in
  let fixdecls = nf_rel_context_evar ( !isevar) fixdecls in
    (*   let ce = check_evars fixenv Evd.empty !isevar in *)
    (*   List.iter (function (_, _, Program rhs) -> ce rhs | _ -> ()) equations; *)
  let prob = 
    if is_recursive = Some Structural then
      id_subst (sign @ fixdecls)
    else id_subst sign
  in
  let split = covering env isevar (i,data) equations prob arity in
    (* if valid_tree prob split then *)
  let status = (* if is_recursive then Expand else *) Define false in
  let baseid = string_of_id i in
  let (ids, csts) = full_transparent_state in
  Auto.create_hint_db false baseid (ids, Cpred.remove (Subtac_utils.fix_proto_ref ()) csts) true;
  let hook cmap helpers _ gr = 
    let info = { base_id = baseid; helpers_info = helpers } in
    let f_cst = match gr with ConstRef c -> c | _ -> assert false in
    let env = Global.env () in
    let f = constr_of_global gr in
      if with_eqns or with_ind then
	match is_recursive with
	| Some Structural ->
	    let cutprob, norecprob = 
	      let (ctx, pats, ctx' as ids) = id_subst sign in
	      let fixdecls' = [Name i, Some f, fixprot] in
		(ctx @ fixdecls', pats, ctx'), ids
	    in
	    let split = update_split is_recursive cmap f cutprob i split in
	      build_equations with_ind env i info data sign is_recursive arity 
		f_cst (constr_of_global gr) norecprob split
	| None ->
	    let split = update_split is_recursive cmap f prob i split in
	    build_equations with_ind env i info data sign is_recursive arity 
	      f_cst (constr_of_global gr) prob split
	| Some (Logical (comp, capp, compproj)) ->
	    let split = update_split is_recursive cmap f prob i split in
	    (* We first define the unfolding and show the fixpoint equation. *)
	    isevar := Evd.empty;
	    let unfoldi = add_suffix i "_unfold" in
	    (* let unfold_baseid = string_of_id unfoldi in *)
	    (* Auto.create_hint_db false unfold_baseid (ids, Cpred.remove (Subtac_utils.fix_proto_ref ()) csts) true; *)
	    let rec unfold_eqs eqs =
	      concat (map
			 (fun ((loc,id), pats, rhs) ->
			   match rhs with
			   | Rec (v, eqs) -> unfold_eqs eqs
			   | Refine (ce, eqs) -> [((loc, unfoldi), pats, Refine (ce, unfold_eqs eqs))]
			   | _ -> [((loc, unfoldi), pats, rhs)])
			 eqs)
	    in
	    let unfold_equations = 
	      map (interp_eqn unfoldi None isevar env data sign arity None)
		(unfold_eqs eqs)
	    in
	    let data = ([], []) in
	    let unfold_split = covering env isevar (unfoldi, data) unfold_equations prob arity in
	    let hook_unfold cmap helpers' _ gr' = 
	      let info = { base_id = baseid; helpers_info = helpers @ helpers' } in
	      let funf_cst = match gr' with ConstRef c -> c | _ -> assert false in
	      let funfc =  mkConst funf_cst in
	      let unfold_split = update_split None cmap funfc prob unfoldi unfold_split in
	      let hook_eqs _ grunfold =
		Conv_oracle.set_strategy (ConstKey funf_cst) Conv_oracle.transparent;
		build_equations with_ind env i info data sign None arity
		  funf_cst funfc ~alias:(f, constr_of_global grunfold, split) prob unfold_split
	      in
	      let stmt = it_mkProd_or_LetIn 
		(mkEq arity (mkApp (f, extended_rel_vect 0 sign))
		    (mkApp (mkConst funf_cst, extended_rel_vect 0 sign))) sign 
	      in
	      let tac = prove_unfolding_lemma info sign (mkConst compproj) f_cst funf_cst unfold_split in
	      let unfold_eq_id = add_suffix unfoldi "_eq" in
		ignore(Subtac_obligations.add_definition ~hook:hook_eqs
			  ~implicits:impls unfold_eq_id stmt ~tactic:tac [||])
	    in
	      define_tree None impls status isevar env (unfoldi, sign, arity) ann unfold_split hook_unfold
      else ()
  in define_tree is_recursive impls status isevar env (i, sign, arity) ann split hook

module Gram = Pcoq.Gram
module Vernac = Pcoq.Vernac_
module Tactic = Pcoq.Tactic

module DeppatGram =
struct
  let gec s = Gram.Entry.create ("Deppat."^s)

  let deppat_equations : pre_equation list Gram.Entry.e = gec "deppat_equations"

  let equation_options : (equation_option * bool) list Gram.Entry.e = gec "equation_options"

  let binders_let2 : (local_binder list * (identifier located option * recursion_order_expr)) Gram.Entry.e = gec "binders_let2"

(*   let where_decl : decl_notation Gram.Entry.e = gec "where_decl" *)

end

open Rawterm
open DeppatGram
open Util
open Pcoq
open Prim
open Constr
open G_vernac

GEXTEND Gram
  GLOBAL: (* deppat_gallina_loc *) deppat_equations binders_let2 equation_options;
 
  deppat_equations:
    [ [ l = LIST1 equation SEP ";" -> l ] ]
  ;

  binders_let2:
    [ [ l = binders_let_fixannot -> l ] ]
  ;

  equation:
    [ [ id = identref; pats = LIST1 patt; r=rhs -> 
      (id, pats, r) ] ]
  ;

  patt:
    [ [ id = identref -> loc, PEApp (id, [])
      | "_" -> loc, PEWildcard
      | "("; p = lpatt; ")" -> p
      | "?("; c = Constr.lconstr; ")" -> loc, PEInac c
    ] ]
  ;

  lpatt:
    [ [ id = identref; pats = LIST0 patt -> loc, PEApp (id, pats)
      | p = patt -> p
    ] ]
  ;

  rhs:
    [ [ ":=!"; id = identref -> Empty id
      |":="; c = Constr.lconstr -> Program c
      | "<="; c = Constr.lconstr; "=>"; e = equations -> Refine (c, e)
      | "<-"; "(" ; t = Tactic.tactic; ")"; e = equations -> By (Inl t, e)
      | "!"; id = identref ; "=>"; e = deppat_equations -> Rec (id, e)
    ] ]
  ;

  equations:
    [ [ "{"; l = deppat_equations; "}" -> l 
    ] ]
  ;

  equation_option:
    [ [ IDENT "noind" -> OInd, false
      | IDENT "ind" -> OInd, true
      | IDENT "struct" -> ORec, true
      | IDENT "nostruct" -> ORec, false
      | IDENT "comp" -> OComp, true
      | IDENT "nocomp" -> OComp, false
      | IDENT "eqns" -> OEquations, true
      | IDENT "noeqns" -> OEquations, false
    ] ]
  ;
  
  equation_options:
    [ [ "(" ; l = LIST1 equation_option; ")" -> l
      | -> [] ] ]
  ;
  END

type 'a deppat_equations_argtype = (pre_equation list, 'a) Genarg.abstract_argument_type

let (wit_deppat_equations : Genarg.tlevel deppat_equations_argtype),
  (globwit_deppat_equations : Genarg.glevel deppat_equations_argtype),
  (rawwit_deppat_equations : Genarg.rlevel deppat_equations_argtype) =
  Genarg.create_arg "deppat_equations"

type 'a equation_options_argtype = ((equation_option * bool) list, 'a) Genarg.abstract_argument_type

let (wit_equation_options : Genarg.tlevel equation_options_argtype),
  (globwit_equation_options : Genarg.glevel equation_options_argtype),
  (rawwit_equation_options : Genarg.rlevel equation_options_argtype) =
  Genarg.create_arg "equation_options"

type 'a binders_let2_argtype = (local_binder list * (identifier located option * recursion_order_expr), 'a) Genarg.abstract_argument_type

let (wit_binders_let2 : Genarg.tlevel binders_let2_argtype),
  (globwit_binders_let2 : Genarg.glevel binders_let2_argtype),
  (rawwit_binders_let2 : Genarg.rlevel binders_let2_argtype) =
  Genarg.create_arg "binders_let2"

type 'a decl_notation_argtype = (Vernacexpr.decl_notation option, 'a) Genarg.abstract_argument_type

let (wit_decl_notation : Genarg.tlevel decl_notation_argtype),
  (globwit_decl_notation : Genarg.glevel decl_notation_argtype),
  (rawwit_decl_notation : Genarg.rlevel decl_notation_argtype) =
  Genarg.create_arg "decl_notation"

type 'a identref_argtype = (identifier located, 'a) Genarg.abstract_argument_type

let (wit_identref : Genarg.tlevel identref_argtype),
  (globwit_identref : Genarg.glevel identref_argtype),
  (rawwit_identref : Genarg.rlevel identref_argtype) =
  Genarg.create_arg "identref"

let with_rollback f x =
  let st = States.freeze () in
    try f x with e -> msg (Cerrors.explain_exn e); States.unfreeze st

let equations opts (loc, i) l t nt eqs =
  Dumpglob.dump_definition (loc, i) false "def";
  with_rollback (define_by_eqs opts i l t nt) eqs

VERNAC COMMAND EXTEND Define_equations
| [ "Equations" equation_options(opt) identref(i) binders_let2(l) 
      ":" lconstr(t) ":=" deppat_equations(eqs)
      decl_notation(nt) ] ->
    [ equations opt i l t nt eqs ]
      END

let rec int_of_coq_nat c = 
  match kind_of_term c with
  | App (f, [| arg |]) -> succ (int_of_coq_nat arg)
  | _ -> 0

let gclause_none =
  { onhyps=Some []; concl_occs=no_occurrences_expr }

let solve_equations_goal destruct_tac tac gl =
  let concl = pf_concl gl in
  let targetn, branchesn, targ, brs, b =
    match kind_of_term concl with
    | LetIn (Name target, targ, _, b) ->
	(match kind_of_term b with
	| LetIn (Name branches, brs, _, b) ->
	    target, branches, int_of_coq_nat targ, int_of_coq_nat brs, b
	| _ -> error "Unnexpected goal")
    | _ -> error "Unnexpected goal"
  in
  let branches, b =
    let rec aux n c =
      if n = 0 then [], c
      else match kind_of_term c with
      | LetIn (Name id, br, brt, b) ->
	  let rest, b = aux (pred n) b in
	    (id, br, brt) :: rest, b
      | _ -> error "Unnexpected goal"
    in aux brs b
  in
  let ids = targetn :: branchesn :: map pi1 branches in
  let cleantac = tclTHEN (intros_using ids) (thin ids) in
  let dotac = tclDO (succ targ) intro in
  let letintac (id, br, brt) = 
    tclTHEN (letin_tac None (Name id) br (Some brt) gclause_none) tac 
  in
  let subtacs =
    tclTHENS destruct_tac (map letintac branches)
  in tclTHENLIST [cleantac ; dotac ; subtacs] gl

TACTIC EXTEND solve_equations
  [ "solve_equations" tactic(destruct) tactic(tac) ] -> [ solve_equations_goal (snd destruct) (snd tac) ]
    END


let coq_prod = lazy (Coqlib.coq_constant "mkHEq" ["Init";"Datatypes"] "prod")
let coq_pair = lazy (Coqlib.coq_constant "mkHEq" ["Init";"Datatypes"] "pair")


let db_of_constr c = match kind_of_term c with
  | Const c -> string_of_label (con_label c)
  | _ -> assert false

let dbs_of_constrs = map db_of_constr

open Extraargs

TACTIC EXTEND simp
| [ "simp" ne_preident_list(l) in_arg_hyp(c) ] -> 
    [ simp_eqns_in (glob_in_arg_hyp_to_clause c) l ]
| [ "simpc" constr_list(l) in_arg_hyp(c) ] -> 
    [ simp_eqns_in (glob_in_arg_hyp_to_clause c) (dbs_of_constrs l) ]
END

let depcase (mind, i as ind) =
  let indid = Nametab.basename_of_global (IndRef ind) in
  let mindb, oneind = Global.lookup_inductive ind in
  let inds = List.rev (Array.to_list (Array.mapi (fun i oib -> mkInd (mind, i)) mindb.mind_packets)) in
  let ctx = oneind.mind_arity_ctxt in
  let nparams = mindb.mind_nparams in
  let args, params = list_chop (List.length ctx - nparams) ctx in
  let nargs = List.length args in
  let liftconstr = nargs + 1 in
  let indapp = mkApp (mkInd ind, extended_rel_vect 0 ctx) in
  let pred = it_mkProd_or_LetIn (new_Type ()) 
    ((Anonymous, None, indapp) :: args)
  in
  let nconstrs = Array.length oneind.mind_nf_lc in
  let branches = 
    array_map2_i (fun i id cty ->
      let substcty = substl inds cty in
      let (args, arity) = decompose_prod_assum substcty in
      let _, indices = decompose_app arity in
      let _, indices = list_chop nparams indices in
      let ncargs = List.length args - nparams in
      let realargs, pars = list_chop ncargs args in
      let realargs = lift_rel_context (i + 1) realargs in
      let arity = applistc (mkRel (ncargs + i + 1)) 
	(indices @ [mkApp (mkConstruct (ind, succ i), 
			  Array.append (extended_rel_vect (ncargs + i + 1) params)
			    (extended_rel_vect 0 realargs))])
      in
      let body = mkRel (liftconstr + nconstrs - i) in
      let br = it_mkProd_or_LetIn arity realargs in
	(Name (id_of_string ("P" ^ string_of_int i)), None, br), body)
      oneind.mind_consnames oneind.mind_nf_lc
  in
  let ci = {
    ci_ind = ind;
    ci_npar = nparams;
    ci_cstr_nargs = oneind.mind_consnrealdecls;
    ci_pp_info = { ind_nargs = oneind.mind_nrealargs; style = RegularStyle; } }
  in
  let obj i =
    mkApp (mkInd ind,
	  (Array.append (extended_rel_vect (nargs + nconstrs + i) params)
	      (extended_rel_vect 0 args)))
  in
  let ctxpred = (Anonymous, None, obj (2 + nargs)) :: args in
  let app = mkApp (mkRel (nargs * 2 + nconstrs + 3),
		  (extended_rel_vect 0 ctxpred))
  in
  let ty = it_mkLambda_or_LetIn app ctxpred in
  let case = mkCase (ci, ty, mkRel 1, Array.map snd branches) in
  let xty = obj 1 in
  let xid = Namegen.named_hd (Global.env ()) xty Anonymous in
  let body = 
    it_mkLambda_or_LetIn case 
      ((xid, None, obj 1) 
	:: ((lift_rel_context 1 args) 
	     @ (List.rev (Array.to_list (Array.map fst branches))) 
	     @ ((Name (id_of_string "P"), None, pred) :: params)))
  in
  let ce =
    { const_entry_body = body;
      const_entry_type = None;
      const_entry_opaque = false;
      const_entry_boxed = false}
  in
  let kn = 
    Declare.declare_constant (add_suffix indid "_case") 
      (DefinitionEntry ce, IsDefinition Scheme)
  in ctx, indapp, kn

let derive_dep_elimination i loc =
  let ctx, ty, kn = depcase i in
  let indid = Nametab.basename_of_global (IndRef i) in
  let id = add_prefix "DependentElimination_" indid in
  let cl = dependent_elimination_class () in
  let env = Global.env () in
  let casety = type_of_constant env kn in
    declare_instance id ctx cl [ty; casety; mkConst kn]

VERNAC COMMAND EXTEND Derive_DependentElimination
| [ "Derive" "DependentElimination" "for" constr_list(c) ] -> [ 
    List.iter (fun c ->
      let c' = interp_constr Evd.empty (Global.env ()) c in
	match kind_of_term c' with
	| Ind i -> derive_dep_elimination i (constr_loc c)
	| _ -> error "Expected an inductive type")
      c
  ]
END

let mkcase env c ty constrs =
  let cty = Typing.type_of env Evd.empty c in
  let ind, origargs = decompose_app cty in
  let mind, ind = match kind_of_term ind with
    | Ind (mu, n as i) -> mu, i
    | _ -> assert false
  in
  let mindb, oneind = Global.lookup_inductive ind in
  let inds = List.rev (Array.to_list (Array.mapi (fun i oib -> mkInd (mind, i)) mindb.mind_packets)) in
  let ctx = oneind.mind_arity_ctxt in
  let _len = List.length ctx in
  let params = mindb.mind_nparams in
  let origparams, _ = list_chop params origargs in
  let ci = {
    ci_ind = ind;
    ci_npar = params;
    ci_cstr_nargs = oneind.mind_consnrealdecls;
    ci_pp_info = { ind_nargs = oneind.mind_nrealargs; style = RegularStyle; } }
  in
  let brs = 
    array_map2_i (fun i id cty ->
      let (args, arity) = decompose_prod_assum (substl inds cty) in
      let realargs, pars = list_chop (List.length args - params) args in
      let args = substl (List.rev origparams) (it_mkProd_or_LetIn arity realargs) in
      let args, arity = decompose_prod_assum args in
      let res = constrs ind i id params args arity in
	it_mkLambda_or_LetIn res args)
      oneind.mind_consnames oneind.mind_nf_lc
  in
    mkCase (ci, ty, c, brs)
      


let mkEq t x y = 
  mkApp (Coqlib.build_coq_eq (), [| refresh_universes t; x; y |])
    
let mkRefl t x = 
  mkApp ((Coqlib.build_coq_eq_data ()).Coqlib.refl, [| refresh_universes t; x |])

let mkHEq t x u y =
  mkApp (Coqlib.coq_constant "mkHEq" ["Logic";"JMeq"] "JMeq",
	[| refresh_universes t; x; refresh_universes u; y |])
    
let mkHRefl t x =
  mkApp (Coqlib.coq_constant "mkHEq" ["Logic";"JMeq"] "JMeq_refl",
	[| refresh_universes t; x |])

let mk_term_eq env sigma ty t ty' t' =
  if Reductionops.is_conv env sigma ty ty' then
    mkEq ty t t', mkRefl ty' t'
  else
    mkHEq ty t ty' t', mkHRefl ty' t'

let mk_eqs env args args' pv = 
  let prf =
    List.fold_right2 (fun x y c -> 
      let tyx = Typing.type_of env Evd.empty x 
      and tyy = Typing.type_of env Evd.empty y in
      let hyp, prf = mk_term_eq env Evd.empty tyx x tyy y in
	mkProd (Anonymous, hyp, lift 1 c))
      args args' pv
  in mkProd (Anonymous, prf, pv)
	
let derive_no_confusion ind =
  let mindb, oneind = Global.lookup_inductive ind in
  let ctx = oneind.mind_arity_ctxt in
  let len = List.length ctx in
  let params = mindb.mind_nparams in
  let args = oneind.mind_nrealargs in
  let argsvect = rel_vect 0 len in
  let paramsvect, rest = array_chop params argsvect in
  let indty = mkApp (mkInd ind, argsvect) in
  let pid = (id_of_string "P") in
  let pvar = mkVar pid in
  let xid = id_of_string "x" and yid = id_of_string "y" in
  let xdecl = (Name xid, None, lift 1 indty) in
  let binders = xdecl :: (Name pid, None, new_Type ()) :: ctx in
  let ydecl = (Name yid, None, lift 2 indty) in
  let fullbinders = ydecl :: binders in
  let arity = it_mkProd_or_LetIn (new_Type ()) fullbinders in
  let env = push_rel_context binders (Global.env ()) in
  let ind_with_parlift n =
    mkApp (mkInd ind, Array.append (Array.map (lift n) paramsvect) rest) 
  in
  let lenargs = List.length ctx - params in
  let pred =
    let elim =
      let app = ind_with_parlift (args + 2) in
	it_mkLambda_or_LetIn 
	  (mkProd_or_LetIn (Anonymous, None, lift 1 app) (new_Type ()))
	  ((Name xid, None, ind_with_parlift (2 + lenargs)) :: list_firstn lenargs ctx)
    in
      mkcase env (mkRel 1) elim (fun ind i id nparams args arity ->
	let ydecl = (Name yid, None, arity) in
	let env' = push_rel_context (ydecl :: args) env in
	let decl = (Name yid, None, ind_with_parlift (lenargs + List.length args + 3)) in
	  mkLambda_or_LetIn ydecl
	    (mkcase env' (mkRel 1) 
		(it_mkLambda_or_LetIn (new_Type ()) (decl :: list_firstn lenargs ctx))
		(fun _ i' id' nparams args' arity' ->
		  if i = i' then 
		    mk_eqs (push_rel_context args' env')
		      (rel_list (List.length args' + 1) (List.length args))
		      (rel_list 0 (List.length args')) pvar
		  else pvar)))
  in
  let app = it_mkLambda_or_LetIn (replace_vars [(pid, mkRel 2)] pred) binders in
  let ce =
    { const_entry_body = app;
      const_entry_type = Some arity;
      const_entry_opaque = false;
      const_entry_boxed = false} 
  in
  let indid = Nametab.basename_of_global (IndRef ind) in
  let id = add_prefix "NoConfusion_" indid
  and noid = add_prefix "noConfusion_" indid
  and packid = add_prefix "NoConfusionPackage_" indid in
  let cstNoConf = Declare.declare_constant id (DefinitionEntry ce, IsDefinition Definition) in
  let stmt = it_mkProd_or_LetIn
    (mkApp (mkConst cstNoConf, rel_vect 1 (List.length fullbinders)))
    ((Anonymous, None, mkEq (lift 3 indty) (mkRel 2) (mkRel 1)) :: fullbinders)
  in
  let hook _ gr = 
    let tc = class_info (global_of_constr (Lazy.force coq_noconfusion_class)) in
    let b, ty = instance_constructor tc [indty; mkApp (mkConst cstNoConf, argsvect) ; 
					 mkApp (constr_of_global gr, argsvect) ] in
    let ce = { const_entry_body = it_mkLambda_or_LetIn b ctx;
	       const_entry_type = Some (it_mkProd_or_LetIn ty ctx); 
	       const_entry_opaque = false; const_entry_boxed = false }
    in
    let inst = Declare.declare_constant packid (DefinitionEntry ce, IsDefinition Instance) in
      Typeclasses.add_instance (Typeclasses.new_instance tc None true (ConstRef inst))
  in
    ignore(Subtac_obligations.add_definition ~hook noid stmt ~tactic:(noconf_tac ()) [||])
     

VERNAC COMMAND EXTEND Derive_NoConfusion
| [ "Derive" "NoConfusion" "for" constr_list(c) ] -> [ 
    List.iter (fun c ->
      let c' = interp_constr Evd.empty (Global.env ()) c in
	match kind_of_term c' with
	| Ind i -> derive_no_confusion i
	| _ -> error "Expected an inductive type")
      c
  ]
END

let list_map_filter_i f l = 
  let rec aux i = function
    | hd :: tl -> 
	(match f i hd with
	| Some x -> x :: aux (succ i) tl
	| None -> aux (succ i) tl)
    | [] -> []
  in aux 0 l


let decompose_indapp f args =
  match kind_of_term f with
  | Construct (ind,_) 
  | Ind ind ->
      let (mib,mip) = Global.lookup_inductive ind in
      let first = mib.Declarations.mind_nparams_rec in
      let pars, args = array_chop first args in
	mkApp (f, pars), args
  | _ -> f, args

open Coqlib

let sigmaize env sigma f =
  let ty = Retyping.get_type_of env sigma f in
  let ctx, concl = decompose_prod_assum ty in
  let argtyp, letbinders, make = Subtac_command.telescope ctx in
  let tyargs =
    [| argtyp; mkLambda (Name (id_of_string "index"), argtyp, 
			it_mkProd_or_LetIn 
			  (mkApp (lift (succ (List.length letbinders)) f, 
				 rel_vect 0 (List.length letbinders)))
			  letbinders) |]
  in
  let tysig = mkApp ((Lazy.force coq_sigma).typ, tyargs) in
  let indexproj = mkApp ((Lazy.force coq_sigma).proj1, tyargs) in
  let valproj = mkApp ((Lazy.force coq_sigma).proj2, tyargs) in
  let indices = 
    (* let subst = subst_rel_context 0 (mkApp (indexproj, [| mkRel 1 |])) in *)
      List.map (fun (_, b, _) -> Option.get b) letbinders 
  in
  let valsig args v = 
    mkApp ((Lazy.force coq_sigma).intro, 
	  Array.append tyargs [| substl (rev args) make; v |])
  in indices, indexproj, valproj, valsig, tysig
    
let mk_pack env sigma ty =
  match kind_of_term ty with
  | App (f, args) ->
      let f, args = decompose_indapp f args in
      let args = Array.to_list args in
	(match args with
	| [] -> ((fun v -> v), f)
	| _ -> 
	    let _, _, _, valsig, tysig = sigmaize env sigma f in
	      valsig args, tysig)
  | _ -> ((fun v -> v), ty)
      
let subterm_relation_base = "subterm_relation"

let derive_subterm ind =
  let global = true in
  let sigma = Evd.empty in
  let mind, oneind = Global.lookup_inductive ind in
  let ctx = oneind.mind_arity_ctxt in
  let len = List.length ctx in
  let params = mind.mind_nparams in
  let ctx = map_rel_context refresh_universes ctx in
  let lenargs = len - params in
  let argbinders, parambinders = list_chop lenargs ctx in
  let indapp = mkApp (mkInd ind, extended_rel_vect 0 parambinders) in
  let getargs t = snd (list_chop params (snd (decompose_app t))) in
  let inds = 
    let branches = Array.mapi (fun i ty ->
      let args, concl = decompose_prod_assum (substl [mkInd ind] ty) in
      let lenargs = List.length args in
      let args', params' = list_chop (lenargs - params) args in
      let recargs = list_map_filter_i (fun i (n, _, t) ->
	match kind_of_term (fst (decompose_app t)) with
	| Ind ind' when ind' = ind -> 
	    Some (mkRel (succ i), getargs (lift (succ i) t))
	| _ -> None) args'
      in
      let constr = mkApp (mkConstruct (ind, succ i), extended_rel_vect 0 args) in
      let constrargs = getargs concl in
      let branches = list_map_i
	(fun j (r, rargs) ->
	  let subargs = 
	    Array.of_list ((extended_rel_list (List.length args') parambinders) 
			    @ rargs @ constrargs @ [r ; constr])
	  in (i, j, it_mkProd_or_LetIn (mkApp (mkRel (succ lenargs), subargs)) args'))
	1 recargs
      in branches) oneind.mind_nf_lc
    in branches
  in
  let branches = Array.fold_right (fun x acc -> x @ acc) inds [] in
  let declare_one_ind i ind branches =
    let indid = Nametab.basename_of_global (IndRef ind) in
    let subtermid = add_suffix indid "_direct_subterm" in
    let constructors = map (fun (i, j, constr) -> constr) branches in
    let consnames = map (fun (i, j, _) ->
      add_suffix subtermid ("_" ^ string_of_int i ^ "_" ^ string_of_int j))
      branches 
    in
    let lenargs = List.length argbinders in
    let liftedbinders = lift_rel_context lenargs argbinders in
    let binders = liftedbinders @ argbinders in
    let appparams = mkApp (mkInd ind, extended_rel_vect (2 * lenargs) parambinders) in
    let arity = it_mkProd_or_LetIn
      (mkProd (Anonymous, mkApp (appparams, extended_rel_vect lenargs argbinders),
	      mkProd (Anonymous, lift 1 (mkApp (appparams, extended_rel_vect 0 argbinders)),
		     mkProp)))
      binders
    in
      { mind_entry_typename = subtermid;
	mind_entry_arity = arity;
	mind_entry_consnames = consnames;	      
	mind_entry_lc = constructors }
  in
  let declare_ind () =
    let inds = [declare_one_ind 0 ind branches] in
    let inductive =
      { mind_entry_record = false;
	mind_entry_finite = true;
	mind_entry_params = map (fun (n, b, t) -> 
	  match b with
	  | Some b -> (out_name n, LocalDef (refresh_universes b)) 
	  | None -> (out_name n, LocalAssum (refresh_universes t)))
	  parambinders;
	mind_entry_inds = inds }
    in
    let k = Command.declare_mutual_inductive_with_eliminations false inductive [] in
    let subind = mkInd (k,0) in
    let constrhints = 
      list_map_i (fun i entry -> 
	list_map_i (fun j _ -> None, true, mkConstruct ((k,i),j)) 1 entry.mind_entry_lc)
	0 inds 
    in Auto.add_hints false ["subterm_relation"] 
      (Auto.HintsResolveEntry (List.concat constrhints));
      (* Proof of Well-foundedness *)
      let id = add_prefix "well_founded_" (List.hd inds).mind_entry_typename in
      let evm = ref Evd.empty in
      let env = Global.env () in
      let env' = push_rel_context parambinders env in
      let subindapp = mkApp (subind, extended_rel_vect lenargs parambinders) in
      let kl, body, ty =
	if argbinders = [] then
	  (* Standard homogeneous well-founded relation *)
	  let kl = Option.get (class_of_constr (Lazy.force coq_subterm_class)) in
	  let evar = e_new_evar evm env'
	    (mkApp (Lazy.force coq_wellfounded, [| indapp; subindapp |]))
	  in
	  let constr, ty = instance_constructor kl [ indapp; subindapp; evar ] in
	    kl, constr, ty
	else
	  (* Construct a family relation by packaging all indexes into 
	     a sigma type *)
	  let kl = Option.get (class_of_constr (Lazy.force coq_subterm_class)) in
	  let indices, indexproj, valproj, valsig, typesig = sigmaize env' sigma indapp in
	  let subrel = 
	    let valproj = lift 2 valproj in
	    let liftindices = map (liftn 2 2) indices in
	    let yindices = map (subst1 (mkApp (lift 2 indexproj, [| mkRel 1 |]))) liftindices in
	    let xindices = map (subst1 (mkApp (lift 2 indexproj, [| mkRel 2 |]))) liftindices in
	    let apprel = 
	      applistc subind (extended_rel_list 2 parambinders @
				  (xindices @ yindices @
				      [mkApp (valproj, [| mkRel 2 |]); mkApp (valproj, [| mkRel 1 |])]))
	    in 
	      mkLambda (Name (id_of_string "x"), typesig,
		       mkLambda (Name (id_of_string "y"), lift 1 typesig,
				apprel))
	  in
	  let typesig = Tacred.simpl env' !evm typesig in
	  let subrel = Tacred.simpl env' !evm subrel in
	  let relation = 
	    let id = add_suffix (Nametab.basename_of_global (IndRef ind)) "_subterm" in
	    let def = it_mkLambda_or_LetIn 
	      (mkApp (Lazy.force coq_clos_trans, [| typesig; subrel |]))
	      parambinders 
	    in
	    let ty = Some (it_mkProd_or_LetIn
			      (mkApp (Lazy.force coq_relation, [| typesig |]))
			      parambinders) 
	    in
	    let cst = declare_constant id def ty (IsDefinition Definition) in
	      Auto.add_hints false ["subterm_relation"] 
		(Auto.HintsUnfoldEntry [EvalConstRef cst]);
	      mkApp (mkConst cst, extended_rel_vect 0 parambinders)
	  in
	  let evar = e_new_evar evm env'
	    (mkApp (Lazy.force coq_wellfounded, [| typesig; relation |]))
	  in
	  let constr, ty = instance_constructor kl [ typesig; relation; evar ] in
	    kl, constr, ty
      in
      let ty = it_mkProd_or_LetIn ty parambinders in
      let body = it_mkLambda_or_LetIn body parambinders in
      let hook vis gr =
	let cst = match gr with ConstRef kn -> kn | _ -> assert false in
	let inst = Typeclasses.new_instance kl None global (ConstRef cst) in
	  Typeclasses.add_instance inst
      in
      let obls, _, constr, typ = Eterm.eterm_obligations env id !evm !evm 0 body ty in
	Subtac_obligations.add_definition id ~term:constr typ
	  ~kind:(Global,false,Instance) ~hook ~tactic:(solve_subterm_tac ()) obls
  in ignore(declare_ind ())
    
VERNAC COMMAND EXTEND Derive_Subterm
| [ "Derive" "Subterm" "for" constr(c) ] -> [ 
    let c' = interp_constr Evd.empty (Global.env ()) c in
      match kind_of_term c' with
      | Ind i -> derive_subterm i
      | _ -> error "Expected an inductive type"
  ]
END

let derive_below ind =
  let mind, oneind = Global.lookup_inductive ind in
  let ctx = oneind.mind_arity_ctxt in
  let len = List.length ctx in
  let params = mind.mind_nparams in
  let argsvect = rel_vect 0 len in
  let indty = mkApp (mkInd ind, argsvect) in
  let binders = (Name (id_of_string "c"), None, indty) :: ctx in
  let argbinders, parambinders = list_chop (succ len - params) binders in
  let arity = it_mkProd_or_LetIn (new_Type ()) argbinders in
  let aritylam = it_mkLambda_or_LetIn (new_Type ()) argbinders in
  let paramsvect = Array.map (lift 1) (rel_vect (succ len - params) params) in
  let argsvect = rel_vect 0 (succ len - params) in
  let pid = id_of_string "P" in
  let pdecl = Name pid, None, arity in
  let stepid = id_of_string "step" in
  let recid = id_of_string "rec" in
  let belowid = id_of_string "below" in
  let paramspargs = Array.append (Array.append paramsvect [| mkVar pid |]) argsvect in
  let tyb = mkApp (mkVar belowid, paramspargs) in
  let arityb = it_mkProd_or_LetIn tyb argbinders in
  let aritylamb = it_mkLambda_or_LetIn tyb argbinders in
  let termB, termb = 
    let branches = Array.mapi (fun i ty ->
      let nargs = constructor_nrealargs (Global.env ()) (ind, succ i) in
      let recarg = mkVar recid in
      let args, _ = decompose_prod_assum (substl [mkInd ind] ty) in
      let args, _ = list_chop (List.length args - params) args in
      let ty' = substl [recarg] ty in
      let args', _ = decompose_prod_assum ty' in
      let arg_tys = fst (List.fold_left (fun (acc, n) (_,_,t) ->
	((mkRel n, lift n t) :: acc, succ n)) ([], 1) args')
      in
      let fold_unit f args =
	let res = 
	  List.fold_left (fun acc x ->
	    match acc with
	    | Some (c, ty) -> f (fun (c', ty') -> 
		mkApp (Lazy.force coq_pair, [| ty' ; ty ; c' ; c |]),
		mkApp (Lazy.force coq_prod, [| ty' ; ty |])) x
	    | None -> f (fun x -> x) x)
	    None args
	in Option.cata (fun x -> x) (Lazy.force coq_tt, Lazy.force coq_unit) res
      in
      let bodyB =
	let _, res =
	  fold_unit (fun g (c, t) -> 
	    let t, args = decompose_app t in
	    let args = Array.of_list (args @ [ c ]) in
	      if t = recarg then 
		Some (g (mkRel 0, 
			mkApp (Lazy.force coq_prod, 
			      [| mkApp (mkVar pid, args) ; 
				 mkApp (mkVar recid, args) |])))
	      else None) arg_tys
	in res
      and bodyb =
	fold_unit (fun g (c, t) -> 
	  let t, args = decompose_app t in
	  let args = Array.of_list (args @ [ c ]) in
	    if t = recarg then 
	      let reccall = mkApp (mkVar recid, args) in
	      let ty = mkApp (Lazy.force coq_prod, 
			     [| mkApp (mkVar pid, args) ; 
				mkApp (mkVar belowid, Array.append [| mkVar pid |] args) |])
	      in
		Some (g (mkApp (Lazy.force coq_pair, 
			       [| mkApp (mkVar pid, args) ; 
				  mkApp (mkVar belowid, Array.append [| mkVar pid |] args) ;
				  mkApp (mkApp (mkVar stepid, args), [| reccall |]);
				  reccall |]), ty))
	    else None) arg_tys
      in (nargs, it_mkLambda_or_LetIn bodyB args, it_mkLambda_or_LetIn (fst bodyb) args)) oneind.mind_nf_lc
    in
    let caseB =
      mkCase ({
	ci_ind = ind;
	ci_npar = params;
	ci_cstr_nargs = Array.map pi1 branches;
	ci_pp_info = { ind_nargs = oneind.mind_nrealargs; style = RegularStyle }
      }, aritylam, mkRel 1, Array.map pi2 branches)
    and caseb =
      mkCase ({
	ci_ind = ind;
	ci_npar = params;
	ci_cstr_nargs = Array.map pi1 branches;
	ci_pp_info = { ind_nargs = oneind.mind_nrealargs; style = RegularStyle }
      }, aritylamb, mkRel 1, Array.map pi3 branches)
    in 
      it_mkLambda_or_LetIn caseB binders, it_mkLambda_or_LetIn caseb binders
  in
  let fixB = mkFix (([| len |], 0), ([| Name recid |], [| arity |], [| subst_vars [recid; pid] termB |])) in
  let bodyB = it_mkLambda_or_LetIn fixB (pdecl :: parambinders) in
  let ce =
    { const_entry_body = bodyB;
      const_entry_type = None;
      const_entry_opaque = false;
      const_entry_boxed = false} 
  in
  let id = add_prefix "Below_" (Nametab.basename_of_global (IndRef ind)) in
  let below = Declare.declare_constant id (DefinitionEntry ce, IsDefinition Definition) in
  let fixb = mkFix (([| len |], 0), ([| Name recid |], [| arityb |], 
				    [| subst_vars [recid; stepid] termb |])) in
  let stepdecl = 
    let stepty = mkProd (Anonymous, mkApp (mkConst below, paramspargs),
			mkApp (mkVar pid, Array.map (lift 1) argsvect))
    in Name stepid, None, it_mkProd_or_LetIn stepty argbinders
  in
  let bodyb = 
    it_mkLambda_or_LetIn (subst_vars [pid] (mkLambda_or_LetIn stepdecl fixb)) (pdecl :: parambinders)
  in
  let bodyb = replace_vars [belowid, mkConst below] bodyb in
  let id = add_prefix "below_" (Nametab.basename_of_global (IndRef ind)) in
  let ce =
    { const_entry_body = bodyb;
      const_entry_type = None;
      const_entry_opaque = false;
      const_entry_boxed = false} 
  in ignore(Declare.declare_constant id (DefinitionEntry ce, IsDefinition Definition))
    
    VERNAC COMMAND EXTEND Derive_Below
| [ "Derive" "Below" "for" constr(c) ] -> [ 
    let c' = interp_constr Evd.empty (Global.env ()) c in
      match kind_of_term c' with
      | Ind i -> derive_below i
      | _ -> error "Expected an inductive type"
  ]
    END

let rec head_of_constr t =
  let t = strip_outer_cast(collapse_appl t) in
    match kind_of_term t with
    | Prod (_,_,c2)  -> head_of_constr c2 
    | LetIn (_,_,_,c2) -> head_of_constr c2
    | App (f,args)  -> head_of_constr f
    | _      -> t
      
TACTIC EXTEND decompose_app
[ "decompose_app" ident(h) ident(h') constr(c) ] -> [ fun gl ->
    let f, args = decompose_app c in
    let fty = pf_type_of gl f in
    let flam = mkLambda (Name (id_of_string "f"), fty, mkApp (mkRel 1, Array.of_list args)) in
      tclTHEN (letin_tac None (Name h) f None allHyps)
	(letin_tac None (Name h') flam None allHyps) gl
  ]
END

open Pfedit
open Proof_trees

let check_guard gl =
  let pts = get_pftreestate () in
  let pf = proof_of_pftreestate pts in
  let (pfterm,_) = extract_open_pftreestate pts in
    try
      Inductiveops.control_only_guard (Evd.evar_env (goal_of_proof pf))
	pfterm; tclIDTAC gl
    with UserError(_,s) ->
      tclFAIL 0 (str ("Condition violated: ") ++s) gl
	
TACTIC EXTEND guarded
[ "guarded"  ] -> [ check_guard ]
END

TACTIC EXTEND abstract_match
[ "abstract_match" ident(hyp) constr(c) ] -> [
  match kind_of_term c with
  | Case (_, _, c, _) -> letin_tac None (Name hyp) c None allHypsAndConcl
  | _ -> tclFAIL 0 (str"Not a case expression")
]
END

let pattern_sigma c hyp gl =
  let terms = constrs_of_coq_sigma (pf_env gl) (project gl) c (mkVar hyp) in
  let projs = map (fun (x, t, p, rest) -> (t, p)) terms in
  let projabs = tclTHENLIST (map (fun (t, p) -> change (Some (all_occurrences, t)) p onConcl) projs) in
    projabs gl
      
TACTIC EXTEND pack
[ "pack" hyp(id) "as" ident(packid) ] -> [ fun gl ->
  let (valsig, typesig) = mk_pack (pf_env gl) (project gl) (pf_get_hyp_typ gl id) in
  let simpl = Tacred.simpl (pf_env gl) (project gl) in
  let typesig = simpl typesig in
  let term = simpl (valsig (mkVar id)) in
    tclTHENLIST [letin_tac None (Name packid) term (Some typesig) allHypsAndConcl;
		 pattern_sigma term packid] gl ]
END

let curry_hyp c t =
  let na, dom, concl = destProd t in
    match decompose_coq_sigma dom with
    | None -> None
    | Some (ty, pred) ->
	let (n, idx, dom) = destLambda pred in
	let newctx = [(na, None, dom); (n, None, idx)] in
	let tuple = mkApp ((Lazy.force coq_sigma).intro,
			  [| lift 2 ty; lift 2 pred; mkRel 2; mkRel 1 |])
	in
	let term = it_mkLambda_or_LetIn (mkApp (c, [| tuple |])) newctx in
	let typ = it_mkProd_or_LetIn (subst1 tuple concl) newctx in
	  Some (term, typ)
	    
TACTIC EXTEND curry
[ "curry" hyp(id) ] -> [ fun gl ->
  match curry_hyp (mkVar id) (pf_get_hyp_typ gl id) with
  | Some (prf, typ) -> 
      (cut_replacing id typ
	  (fun x gl -> refine_no_check prf gl)) gl
  | None -> tclFAIL 0 (str"No currying to do in" ++ pr_id id) gl ]
END

TACTIC EXTEND pattern_tele
[ "pattern_tele" constr(c) ident(hyp) ] -> [ fun gl ->
  let settac = letin_tac None (Name hyp) c None onConcl in
    tclTHENLIST [settac; pattern_sigma c hyp] gl ]
END
  
(* TACTIC EXTEND pattern_call *)
(* [ "pattern_call" constr(c) ] -> [ fun gl -> *)
(*   match kind_of_term c with *)
(*   | App (f, [| arg |]) -> *)
(*       let concl = pf_concl gl in *)
(*       let replcall = replace_term c (mkRel 1) concl in *)
(*       let replarg = replace_term arg (mkRel 2) replcall in *)
(*       let argty = pf_type_of gl arg and cty = pf_type_of gl c in *)
(*       let rels = [(Name (id_of_string "call"), None, replace_term arg (mkRel 1) cty); *)
(* 		  (Name (id_of_string "arg"), None, argty)] in *)
(*       let newconcl = mkApp (it_mkLambda_or_LetIn replarg rels, [| arg ; c |]) in *)
(* 	convert_concl newconcl DEFAULTcast gl  *)
(*   | _ -> tclFAIL 0 (str "Not a recognizable call") gl ] *)
(* END *)

let pattern_call ?(pattern_term=true) c gl =
  let cty = pf_type_of gl c in
  let deps =
    match kind_of_term c with
    | App (f, args) -> Array.to_list args
    | _ -> []
  in
  let varname c = match kind_of_term c with
    | Var id -> id
    | _ -> id_of_string (Namegen.hdchar (pf_env gl) c)
  in
  let mklambda ty (c, id, cty) =
    let conclvar = subst_term_occ all_occurrences c ty in
      mkNamedLambda id cty conclvar
  in
  let subst = 
    let deps = List.rev_map (fun c -> (c, varname c, pf_type_of gl c)) deps in
      if pattern_term then (c, varname c, cty) :: deps
      else deps
  in
  let concllda = List.fold_left mklambda (pf_concl gl) subst in
  let conclapp = applistc concllda (List.rev_map pi1 subst) in
    convert_concl_no_check conclapp DEFAULTcast gl

TACTIC EXTEND pattern_call
[ "pattern_call" constr(c) ] -> [ pattern_call c ]
END
