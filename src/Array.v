Require Import List Omega Ring Word Pred Prog Hoare SepAuto BasicProg.


(** * A generic array predicate: a sequence of consecutive points-to facts *)

Fixpoint array (a : addr) (vs : list valu) :=
  match vs with
    | nil => emp
    | v :: vs' => a |-> v * array (a ^+ $1) vs'
  end%pred.

(** * Reading and writing from arrays *)

Fixpoint selN (vs : list valu) (n : nat) : valu :=
  match vs with
    | nil => $0
    | v :: vs' =>
      match n with
        | O => v
        | S n' => selN vs' n'
      end
  end.

Definition sel (vs : list valu) (i : addr) : valu :=
  selN vs (wordToNat i).

Fixpoint updN (vs : list valu) (n : nat) (v : valu) : list valu :=
  match vs with
    | nil => nil
    | v' :: vs' =>
      match n with
        | O => v :: vs'
        | S n' => v' :: updN vs' n' v
      end
  end.

Definition upd (vs : list valu) (i : addr) (v : valu) : list valu :=
  updN vs (wordToNat i) v.

Lemma length_updN : forall vs n v, length (updN vs n v) = length vs.
Proof.
  induction vs; destruct n; simpl; intuition.
Qed.

Theorem length_upd : forall vs i v, length (upd vs i v) = length vs.
Proof.
  intros; apply length_updN.
Qed.

Hint Rewrite length_updN length_upd.

Lemma selN_updN_eq : forall vs n v,
  n < length vs
  -> selN (updN vs n v) n = v.
Proof.
  induction vs; destruct n; simpl; intuition; omega.
Qed.

Lemma sel_upd_eq : forall vs i v,
  wordToNat i < length vs
  -> sel (upd vs i v) i = v.
Proof.
  intros; apply selN_updN_eq; auto.
Qed.

Hint Rewrite selN_updN_eq sel_upd_eq using (simpl; omega).

Lemma firstn_updN : forall v vs i j,
  i <= j
  -> firstn i (updN vs j v) = firstn i vs.
Proof.
  induction vs; destruct i, j; simpl; intuition.
  omega.
  rewrite IHvs; auto; omega.
Qed.

Lemma firstn_upd : forall v vs i j,
  i <= wordToNat j
  -> firstn i (upd vs j v) = firstn i vs.
Proof.
  intros; apply firstn_updN; auto.
Qed.

Hint Rewrite firstn_updN firstn_upd using omega.

Lemma skipN_updN' : forall v vs i j,
  i > j
  -> skipn i (updN vs j v) = skipn i vs.
Proof.
  induction vs; destruct i, j; simpl; intuition; omega.
Qed.

Lemma skipn_updN : forall v vs i j,
  i >= j
  -> match updN vs j v with
       | nil => nil
       | _ :: vs' => skipn i vs'
     end
     = match vs with
         | nil => nil
         | _ :: vs' => skipn i vs'
       end.
Proof.
  destruct vs, j; simpl; eauto using skipN_updN'.
Qed.

Lemma skipn_upd : forall v vs i j,
  i >= wordToNat j
  -> match upd vs j v with
       | nil => nil
       | _ :: vs' => skipn i vs'
     end
     = match vs with
         | nil => nil
         | _ :: vs' => skipn i vs'
       end.
Proof.
  intros; apply skipn_updN; auto.
Qed.

Hint Rewrite skipn_updN skipn_upd using omega.


(** * Isolating an array cell *)

Lemma isolate_fwd' : forall vs i a,
  i < length vs
  -> array a vs ==> array a (firstn i vs)
     * (a ^+ $ i) |-> selN vs i
     * array (a ^+ $ i ^+ $1) (skipn (S i) vs).
Proof.
  induction vs; simpl; intuition.

  inversion H.

  destruct i; simpl.

  replace (a0 ^+ $0 ^+ $1) with (a0 ^+ $1) by words.
  cancel.

  eapply pimpl_trans; [ apply pimpl_sep_star; [ apply pimpl_refl | apply IHvs ] | ]; clear IHvs.
  instantiate (1 := i); omega.
  simpl.
  replace (a0 ^+ $1 ^+ $ i ^+ $1) with (a0 ^+ $ (S i) ^+ $1) by words.
  cancel.
Qed.  

Theorem isolate_fwd : forall (a i : addr) vs,
  wordToNat i < length vs
  -> array a vs ==> array a (firstn (wordToNat i) vs)
     * (a ^+ i) |-> sel vs i
     * array (a ^+ i ^+ $1) (skipn (S (wordToNat i)) vs).
Proof.
  intros.
  eapply pimpl_trans; [ apply isolate_fwd' | ].
  eassumption.
  rewrite natToWord_wordToNat.
  apply pimpl_refl.
Qed.

Lemma isolate_bwd' : forall vs i a,
  i < length vs
  -> array a (firstn i vs)
     * (a ^+ $ i) |-> selN vs i
     * array (a ^+ $ i ^+ $1) (skipn (S i) vs)
  ==> array a vs.
Proof.
  induction vs; simpl; intuition.

  inversion H.

  destruct i; simpl.

  replace (a0 ^+ $0 ^+ $1) with (a0 ^+ $1) by words.
  cancel.

  eapply pimpl_trans; [ | apply pimpl_sep_star; [ apply pimpl_refl | apply IHvs ] ]; clear IHvs.
  2: instantiate (1 := i); omega.
  simpl.
  replace (a0 ^+ $1 ^+ $ i ^+ $1) with (a0 ^+ $ (S i) ^+ $1) by words.
  cancel.
Qed.

Theorem isolate_bwd : forall (a i : addr) vs,
  wordToNat i < length vs
  -> array a (firstn (wordToNat i) vs)
     * (a ^+ i) |-> sel vs i
     * array (a ^+ i ^+ $1) (skipn (S (wordToNat i)) vs)
  ==> array a vs.
Proof.
  intros.
  eapply pimpl_trans; [ | apply isolate_bwd' ].
  2: eassumption.
  rewrite natToWord_wordToNat.
  apply pimpl_refl.
Qed.


(** * Opaque operations for array accesses, to guide automation *)

Module Type ARRAY_OPS.
  Parameter ArrayRead : addr -> addr -> (valu -> prog) -> prog.
  Axiom ArrayRead_eq : ArrayRead = fun a i k => Read (a ^+ i) k.

  Parameter ArrayWrite : addr -> addr -> valu -> (unit -> prog) -> prog.
  Axiom ArrayWrite_eq : ArrayWrite = fun a i v k => Write (a ^+ i) v k.
End ARRAY_OPS.

Module ArrayOps : ARRAY_OPS.
  Definition ArrayRead : addr -> addr -> (valu -> prog) -> prog :=
    fun a i k => Read (a ^+ i) k.
  Theorem ArrayRead_eq : ArrayRead = fun a i k => Read (a ^+ i) k.
  Proof.
    auto.
  Qed.

  Definition ArrayWrite : addr -> addr -> valu -> (unit -> prog) -> prog :=
    fun a i v k => Write (a ^+ i) v k.    
  Theorem ArrayWrite_eq : ArrayWrite = fun a i v k => Write (a ^+ i) v k.
  Proof.
    auto.
  Qed.
End ArrayOps.

Import ArrayOps.
Export ArrayOps.


(** * Hoare rules *)

Theorem read_ok:
  forall (a i:addr) (rx:valu->prog) (rec:prog),
  {{ exists vs F, array a vs * F
   * [[wordToNat i < length vs]]
   * [[{{ array a vs * F }} (rx (sel vs i)) >> rec]]
   * [[{{ array a vs * F }} rec >> rec]]
  }} ArrayRead a i rx >> rec.
Proof.
  intros.
  apply pimpl_ok with (exists vs F,
    array a (firstn (wordToNat i) vs)
    * (a ^+ i) |-> sel vs i
    * array (a ^+ i ^+ $1) (skipn (S (wordToNat i)) vs) * F
    * [[wordToNat i < length vs]]
    * [[{{ array a (firstn (wordToNat i) vs)
           * (a ^+ i) |-> sel vs i
           * array (a ^+ i ^+ $1) (skipn (S (wordToNat i)) vs) * F }} (rx (sel vs i)) >> rec]]
    * [[{{ array a (firstn (wordToNat i) vs)
           * (a ^+ i) |-> sel vs i
           * array (a ^+ i ^+ $1) (skipn (S (wordToNat i)) vs) * F }} rec >> rec]])%pred.

  rewrite ArrayRead_eq.
  eapply pimpl_ok.
  apply read_ok.
  cancel.
  eapply pimpl_ok; [ eassumption | cancel ].
  eapply pimpl_ok; [ eassumption | cancel ].

  cancel.
  eapply pimpl_trans; [ apply pimpl_sep_star; [ apply pimpl_refl
                                              | apply pimpl_sep_star; [ apply pimpl_refl
                                                                      | apply isolate_fwd; eassumption ] ] | ].
  cancel.
  assumption.

  eapply pimpl_ok; [ eassumption | cancel ].
  eapply pimpl_trans; [ | apply pimpl_sep_star; [ apply pimpl_refl
                                                | apply isolate_bwd; eassumption ] ].
  cancel.

  eapply pimpl_ok; [ eassumption | cancel ].
  eapply pimpl_trans; [ | apply pimpl_sep_star; [ apply pimpl_refl
                                                | apply isolate_bwd; eassumption ] ].
  cancel.
Qed.

Theorem write_ok:
  forall (a i:addr) (v:valu) (rx:unit->prog) (rec:prog),
  {{ exists vs F, array a vs * F
   * [[wordToNat i < length vs]]
   * [[{{ array a (upd vs i v) * F }} (rx tt) >> rec]]
   * [[{{ array a vs * F \/ array a (upd vs i v) * F }} rec >> rec]]
  }} ArrayWrite a i v rx >> rec.
Proof.
  intros.
  apply pimpl_ok with (exists vs F,
    array a (firstn (wordToNat i) vs)
    * (a ^+ i) |-> sel vs i
    * array (a ^+ i ^+ $1) (skipn (S (wordToNat i)) vs) * F
    * [[wordToNat i < length vs]]
    * [[{{ array a (firstn (wordToNat i) vs)
           * (a ^+ i) |-> v
           * array (a ^+ i ^+ $1) (skipn (S (wordToNat i)) vs) * F }} (rx tt) >> rec]]
    * [[{{ (array a (firstn (wordToNat i) vs)
           * (a ^+ i) |-> sel vs i
           * array (a ^+ i ^+ $1) (skipn (S (wordToNat i)) vs) * F)
           \/ (array a (firstn (wordToNat i) vs)
           * (a ^+ i) |-> v
           * array (a ^+ i ^+ $1) (skipn (S (wordToNat i)) vs) * F) }} rec >> rec]])%pred.

  rewrite ArrayWrite_eq.
  eapply pimpl_ok.
  apply write_ok.
  cancel.
  eapply pimpl_ok; [ eassumption | cancel ].
  eapply pimpl_ok; [ eassumption | cancel ].

  cancel.
  eapply pimpl_trans; [ apply pimpl_sep_star; [ apply pimpl_refl
                                              | apply pimpl_sep_star; [ apply pimpl_refl
                                                                      | apply isolate_fwd; eassumption ] ] | ].
  cancel.
  assumption.

  eapply pimpl_ok; [ eassumption | cancel ].
  eapply pimpl_trans; [ | apply pimpl_sep_star; [ apply pimpl_refl
                                                | apply isolate_bwd; autorewrite with core; eassumption ] ].
  autorewrite with core.
  cancel.
  autorewrite with core.
  cancel.

  eapply pimpl_ok; [ eassumption | apply pimpl_or; cancel ].
  eapply pimpl_trans; [ | apply pimpl_sep_star; [ apply pimpl_refl
                                                | apply isolate_bwd; autorewrite with core; eassumption ] ].
  autorewrite with core.
  cancel.
  autorewrite with core.
  cancel.

  eapply pimpl_trans; [ | apply pimpl_sep_star; [ apply pimpl_refl
                                                | apply isolate_bwd; autorewrite with core; eassumption ] ].
  autorewrite with core.
  cancel.
  autorewrite with core.
  cancel.
Qed.

Hint Extern 1 ({{_}} progseq (ArrayRead _ _) _ >> _) => apply read_ok : prog.
Hint Extern 1 ({{_}} progseq (ArrayWrite _ _ _) _ >> _) => apply write_ok : prog.


(** * Some test cases *)

Definition read_back a rx :=
  ArrayWrite a $0 $42;;
  v <- ArrayRead a $0;
  rx v.

Theorem read_back_ok : forall a rx rec,
  {{ exists vs F, array a vs * F
     * [[length vs > 0]]
     * [[ {{array a (upd vs $0 $42) * F}} rx $42 >> rec ]]
     * [[ {{(array a vs * F) \/ (array a (upd vs $0 $42) * F)}} rec >> rec ]]
  }} read_back a rx >> rec.
Proof.
  unfold read_back; hoare.
Qed.

Definition swap a i j rx :=
  vi <- ArrayRead a i;
  vj <- ArrayRead a j;
  ArrayWrite a i vj;;
  ArrayWrite a j vi;;
  rx.

Theorem swap_ok : forall a i j rx rec,
  {{ exists vs F, array a vs * F
     * [[wordToNat i < length vs]]
     * [[wordToNat j < length vs]]
     * [[ {{array a (upd (upd vs i (sel vs j)) j (sel vs i)) * F}} rx >> rec ]]
     * [[ {{(array a vs * F) \/ (array a (upd vs i (sel vs j)) * F)
            \/ (array a (upd (upd vs i (sel vs j)) j (sel vs i)) * F)}} rec >> rec ]]
  }} swap a i j rx >> rec.
Proof.
  unfold swap; hoare.
Qed.