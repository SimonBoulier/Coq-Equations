(**********************************************************************)
(* Equations                                                          *)
(* Copyright (c) 2009-2019 Matthieu Sozeau <matthieu.sozeau@inria.fr> *)
(**********************************************************************)
(* This file is distributed under the terms of the                    *)
(* GNU Lesser General Public License Version 2.1                      *)
(**********************************************************************)

Require Import Coq.Unicode.Utf8_core.
From Coq Require Import Extraction.
Require Export Coq.Program.Basics Coq.Program.Tactics Coq.Program.Utils.

Declare ML Module "equations_plugin".

(** A notation scope for equations declarations.

  The general mechanism of notations forces us to define
  notations in this scope in separate modules that we can
  avoid to export to remain compatible with user developments.
*)

Declare Scope equations_scope.
Delimit Scope equations_scope with equations.
Local Open Scope equations_scope.

Global Unset Auto Template Polymorphism.

(** A marker for fixpoint prototypes in the context *)
Definition fixproto := tt.

(** A constant to avoid displaying large let-defined terms
    in the context. *)
Definition hidebody {A : Type} {a : A} := a.

Ltac hidebody H :=
  match goal with
    [ H := ?b |- _ ] => change (@hidebody _ b) in (value of H)
  end.

Ltac destruct_rec_calls ::=
  match goal with
    | [ H : let _ := fixproto in _ |- _ ] => red in H; destruct_calls H ; clear H
  end.

(* Redefine to avoid the [simpl] tactic before clearing fixpoint prototypes *)
Ltac program_simplify ::=
  intros; destruct_all_rec_calls; simpl in *; repeat (destruct_conjs; simpl proj1_sig in * );
  subst*; autoinjections ; try discriminates ;
    try (solve [ red ; intros ; destruct_conjs ; autoinjections ; discriminates ]).

Ltac solve_wf :=
  match goal with
    |- ?R _ _ => try typeclasses eauto with subterm_relation Below rec_decision
  end.

(* program_simpl includes a [typeclasses eauto with program] which solves, e.g. [nat] goals trivially.
   We remove it. *)
Ltac equations_simpl := program_simplify ; try program_solve_wf; try solve_wf.

Global Obligation Tactic := equations_simpl.

(** The sigma type used by Equations. *)

Set Primitive Projections.
Global Unset Printing Primitive Projection Parameters.
Global Unset Printing Primitive Projection Compatibility.
Polymorphic Cumulative Record sigma@{i} {A : Type@{i}} {B : A -> Type@{i}} : Type@{i} :=
  sigmaI { pr1 : A; pr2 : B pr1 }.
Unset Primitive Projections.
Arguments sigma A B : clear implicits.
Arguments sigmaI {A} B pr1 pr2.

Polymorphic Definition prod (A : Type) (B : Type) := sigma A (fun _ => B).

Set Warnings "-notation-overridden".

Module Sigma_Notations.

Notation "'∃' x .. y , P" := (sigma _ (fun x => .. (sigma _ (fun y => P)) ..))
  (at level 200, x binder, y binder, right associativity,
  format "'[  ' '[  ' ∃  x  ..  y ']' ,  '/' P ']'") : type_scope.

Notation "( x , .. , y , z )" :=
  (@sigmaI _ _ x .. (@sigmaI _ _ y z) ..)
      (right associativity, at level 0,
       format "( x ,  .. ,  y ,  z )") : equations_scope.

Notation " x .1 " := (pr1 x) (at level 3, format "x .1") : equations_scope.
Notation " x .2 " := (pr2 x) (at level 3, format "x .2") : equations_scope.

End Sigma_Notations.

Import Sigma_Notations.

(** The polymorphic equality type used by Equations. *)

Set Universe Polymorphism.

Inductive Empty@{i} : Type@{i} :=.

Scheme Empty_case := Minimality for Empty Sort Type.

Cumulative Inductive Id@{i} {A : Type@{i}} (a : A) : A -> Type@{i} :=
  id_refl : Id a a.
Arguments id_refl {A a}, [A] a.

Module Id_Notations.

  Notation " x = y " := (@Id _ x y) : equations_scope.
  Notation " x = y " := (@Id _ x y) : type_scope.
  Notation " x <> y " := (@Id _ x y -> Empty) : equations_scope.
  Notation " x <> y " := (@Id _ x y -> Empty) : type_scope.
  Notation " 1 " := (@id_refl _ _) : equations_scope.

End Id_Notations.

Import Id_Notations.

Section IdTheory.
  Universe i.
  Context {A : Type@{i}}.

  Import Id_Notations.

  Lemma id_sym {x y : A} : x = y -> y = x.
  Proof. destruct 1. apply 1. Defined.

  Lemma id_trans {x y z : A} : x = y -> y = z -> x = z.
  Proof. destruct 1. apply id. Defined.

End IdTheory.

(** Forward reference for the NoConfusion tactic. *)
Ltac noconf H := congruence || injection H; intros; subst.

(** Forward reference for Equations' [depelim] tactic, which will be defined in [DepElim]. *)
Ltac depelim x := fail "not defined yet".

(** Such a useful tactic it should be part of the stdlib. *)
Ltac forward_gen H tac :=
  match type of H with
  | ?X -> _ => let H' := fresh in assert (H':X) ; [tac|specialize (H H'); clear H']
  end.

Tactic Notation "forward" constr(H) := forward_gen H ltac:(idtac).
Tactic Notation "forward" constr(H) "by" tactic(tac) := forward_gen H tac.
