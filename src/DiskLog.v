Require Import Arith.
Require Import Bool.
Require Import List.
Require Import Eqdep_dec.
Require Import Classes.SetoidTactics.
Require Import Pred.
Require Import Prog.
Require Import Hoare.
Require Import SepAuto.
Require Import BasicProg.
Require Import Omega.
Require Import Word.
Require Import Rec.
Require Import Array.
Require Import GenSep.
Require Import WordAuto.
Require Import Cache.
Require Import FSLayout.

Import ListNotations.

Set Implicit Arguments.

Definition log_contents := list (addr * valu).

Inductive state :=
| Synced (l: log_contents)
(* The log is synced on disk *)

| Shortened (old: log_contents) (new_length: nat)
(* The log has been shortened; the contents are still synced but the length is potentially unsynced *)

| ExtendedDescriptor (old: log_contents)
(* The log is being extended; only the descriptor has been updated (unsynced) *)

| Extended (old: log_contents) (appended: log_contents).
(* The log has been extended; the new contents are synced but the length is potentially unsynced *)

Module DISKLOG.

  Definition header_type := Rec.RecF ([("length", Rec.WordF addrlen)]).
  Definition header := Rec.data header_type.
  Definition mk_header (len : nat) : header := ($ len, tt).

  Theorem header_sz_ok : Rec.len header_type <= valulen.
  Proof.
    rewrite valulen_is. apply leb_complete. compute. trivial.
  Qed.

  Theorem plus_minus_header : Rec.len header_type + (valulen - Rec.len header_type) = valulen.
  Proof.
    apply le_plus_minus_r; apply header_sz_ok.
  Qed.

  Definition header_to_valu (h : header) : valu.
    set (zext (Rec.to_word h) (valulen - Rec.len header_type)) as r.
    rewrite plus_minus_header in r.
    refine r.
  Defined.
  Arguments header_to_valu : simpl never.

  Definition valu_to_header (v : valu) : header.
    apply Rec.of_word.
    rewrite <- plus_minus_header in v.
    refine (split1 _ _ v).
  Defined.

  Definition header_valu_id : forall h,
    valu_to_header (header_to_valu h) = h.
  Proof.
    unfold valu_to_header, header_to_valu.
    unfold eq_rec_r, eq_rec.
    intros.
    rewrite <- plus_minus_header.
    unfold zext.
    autorewrite with core.
    apply Rec.of_to_id.
    simpl; destruct h; tauto.
  Qed.
  Hint Rewrite header_valu_id.

  Definition addr_per_block := valulen / addrlen.
  Definition descriptor_type := Rec.ArrayF (Rec.WordF addrlen) addr_per_block.
  Definition descriptor := Rec.data descriptor_type.
  Theorem descriptor_sz_ok : valulen = Rec.len descriptor_type.
  Proof.
    simpl. unfold addr_per_block. rewrite valulen_is. vm_compute. reflexivity.
  Qed.

  Definition descriptor_to_valu (d : descriptor) : valu.
    rewrite descriptor_sz_ok.
    apply Rec.to_word; auto.
  Defined.
  Arguments descriptor_to_valu : simpl never.

  Definition valu_to_descriptor (v : valu) : descriptor.
    rewrite descriptor_sz_ok in v.
    apply Rec.of_word; auto.
  Defined.

  Theorem valu_descriptor_id : forall v,
    descriptor_to_valu (valu_to_descriptor v) = v.
  Proof.
    unfold descriptor_to_valu, valu_to_descriptor.
    unfold eq_rec_r, eq_rec.
    intros.
    rewrite Rec.to_of_id.
    rewrite <- descriptor_sz_ok.
    autorewrite with core.
    trivial.
  Qed.
  Hint Rewrite valu_descriptor_id.

  Theorem descriptor_valu_id : forall d,
    Rec.well_formed d -> valu_to_descriptor (descriptor_to_valu d) = d.
  Proof.
    unfold descriptor_to_valu, valu_to_descriptor.
    unfold eq_rec_r, eq_rec.
    intros.
    rewrite descriptor_sz_ok.
    autorewrite with core.
    apply Rec.of_to_id; auto.
  Qed.

  Theorem valu_to_descriptor_length : forall v,
    length (valu_to_descriptor v) = addr_per_block.
  Proof.
    unfold valu_to_descriptor.
    intros.
    pose proof (@Rec.of_word_length descriptor_type).
    unfold Rec.well_formed in H.
    simpl in H.
    apply H.
  Qed.
  Hint Resolve valu_to_descriptor_length.

  Lemma descriptor_to_valu_zeroes: forall l n,
    descriptor_to_valu (l ++ repeat $0 n) = descriptor_to_valu l.
  Proof.
    unfold descriptor_to_valu.
    unfold eq_rec_r, eq_rec.
    intros.
    rewrite descriptor_sz_ok.
    autorewrite with core.
    apply Rec.to_word_append_zeroes.
  Qed.

  Definition valid_xp xp :=
    wordToNat (LogLen xp) <= addr_per_block /\
    (* The log shouldn't overflow past the end of disk *)
    goodSize addrlen (# (LogData xp) + # (LogLen xp)).

  Definition avail_region start len : @pred addr (@weq addrlen) valuset :=
    (exists l, [[ length l = len ]] * array start l $1)%pred.

  Theorem avail_region_shrink_one : forall start len,
    len > 0
    -> avail_region start len =p=>
       start |->? * avail_region (start ^+ $1) (len - 1).
  Proof.
    destruct len; intros; try omega.
    unfold avail_region.
    norm'l; unfold stars; simpl.
    destruct l; simpl in *; try congruence.
    cancel.
  Qed.

  Definition synced_list m: list valuset := List.combine m (repeat nil (length m)).

  Lemma length_synced_list : forall l,
    length (synced_list l) = length l.
  Proof.
    unfold synced_list; intros.
    rewrite combine_length. autorewrite with core. auto.
  Qed.

  Definition valid_size xp (l: log_contents) :=
    length l <= wordToNat (LogLen xp).

  (** On-disk representation of the log *)
  Definition log_rep_synced xp (l: log_contents) : @pred addr (@weq addrlen) valuset :=
     ([[ valid_size xp l ]] *
      exists rest,
      (LogDescriptor xp) |=> (descriptor_to_valu (map fst l ++ rest)) *
      [[ @Rec.well_formed descriptor_type (map fst l ++ rest) ]] *
      array (LogData xp) (synced_list (map snd l)) $1 *
      avail_region (LogData xp ^+ $ (length l))
                         (wordToNat (LogLen xp) - length l))%pred.

  Definition log_rep_extended_descriptor xp (l: log_contents) : @pred addr (@weq addrlen) valuset :=
     ([[ valid_size xp l ]] *
      exists rest rest2,
      (LogDescriptor xp) |-> (descriptor_to_valu (map fst l ++ rest), [descriptor_to_valu (map fst l ++ rest2)]) *
      [[ @Rec.well_formed descriptor_type (map fst l ++ rest) ]] *
      [[ @Rec.well_formed descriptor_type (map fst l ++ rest2) ]] *
      array (LogData xp) (synced_list (map snd l)) $1 *
      avail_region (LogData xp ^+ $ (length l))
                         (wordToNat (LogLen xp) - length l))%pred.

  Definition rep_inner xp (st: state) :=
    (* For now, support just one descriptor block, at the start of the log. *)
    ([[ valid_xp xp ]] *
    match st with
    | Synced l =>
      (LogHeader xp) |=> header_to_valu (mk_header (length l))
    * log_rep_synced xp l

    | Shortened old len =>
      [[ len <= length old ]]
    * (LogHeader xp) |-> (header_to_valu (mk_header len), header_to_valu (mk_header (length old)) :: [])
    * log_rep_synced xp old

    | ExtendedDescriptor old =>
      (LogHeader xp) |=> header_to_valu (mk_header (length old))
    * log_rep_extended_descriptor xp old

    | Extended old new =>
      (LogHeader xp) |-> (header_to_valu (mk_header (length old + length new)), header_to_valu (mk_header (length old)) :: [])
    * log_rep_synced xp (old ++ new)

    end)%pred.

  Definition rep xp F st cs := (exists d,
    BUFCACHE.rep cs d * [[ (F * rep_inner xp st)%pred d ]])%pred.

  Ltac disklog_unfold := unfold rep, rep_inner, valid_xp, log_rep_synced, log_rep_extended_descriptor, valid_size, synced_list.

  Ltac word2nat_clear := try clear_norm_goal; repeat match goal with
    | [ H : forall _, {{ _ }} _ |- _ ] => clear H
    | [ H : _ =p=> _ |- _ ] => clear H
    | [ H: ?a ?b |- _ ] =>
      match type of a with
      | pred => clear H
      end
    end.

  Lemma skipn_1_length': forall T (l: list T),
    length (match l with [] => [] | _ :: l' => l' end) = length l - 1.
  Proof.
    destruct l; simpl; omega.
  Qed.

  Hint Rewrite app_length firstn_length skipn_length combine_length map_length repeat_length length_upd
    skipn_1_length' : lengths.

  Ltac solve_lengths' :=
    repeat (progress (autorewrite with lengths; repeat rewrite Nat.min_l by solve_lengths'; repeat rewrite Nat.min_r by solve_lengths'));
    simpl; try word2nat_solve.

  Ltac solve_lengths_prepare :=
    intros; word2nat_clear; simpl;
    (* Stupidly, this is like 5x faster than [rewrite Map.cardinal_1 in *] ... *)
    repeat match goal with
    | [ H : context[Map.cardinal] |- _ ] => rewrite Map.cardinal_1 in H
    | [ |- context[Map.cardinal] ] => rewrite Map.cardinal_1
    end.

  Ltac solve_lengths_prepped :=
    try (match goal with
      | [ |- context[{{ _ }} _] ] => fail 1
      | [ |- _ =p=> _ ] => fail 1
      | _ => idtac
      end;
      word2nat_clear; word2nat_simpl; word2nat_rewrites; solve_lengths').

  Ltac solve_lengths := solve_lengths_prepare; solve_lengths_prepped.

  Theorem firstn_map : forall A B n l (f: A -> B),
    firstn n (map f l) = map f (firstn n l).
  Proof.
    induction n; simpl; intros.
    reflexivity.
    destruct l; simpl.
    reflexivity.
    f_equal.
    eauto.
  Qed.

  Lemma combine_one: forall A B (a: A) (b: B), [(a, b)] = List.combine [a] [b].
  Proof.
    intros; auto.
  Qed.

  Lemma cons_combine : forall A B (a: A) (b: B) x y,
    (a, b) :: List.combine x y = List.combine (a :: x) (b :: y).
    trivial.
  Qed.

  Definition emp_star_r' : forall V AT AEQ P, P * (emp (V:=V) (AT:=AT) (AEQ:=AEQ)) =p=> P.
  Proof.
    cancel.
  Qed.


  Definition unifiable_array := @array valuset.

  Hint Extern 0 (okToUnify (unifiable_array _ _ _) (unifiable_array _ _ _)) => constructor : okToUnify.

  Lemma make_unifiable: forall a l s,
    array a l s <=p=> unifiable_array a l s.
  Proof.
    split; cancel.
  Qed.


  Ltac word_assert P := let H := fresh in assert P as H by
      (word2nat_simpl; repeat rewrite wordToNat_natToWord_idempotent'; word2nat_solve); clear H.

  Ltac array_sort' :=
    eapply pimpl_trans; rewrite emp_star; [ apply pimpl_refl |];
    set_evars;
    repeat rewrite <- sep_star_assoc;
    subst_evars;
    match goal with
    | [ |- ?p =p=> ?p ] => fail 1
    | _ => idtac
    end;
    repeat match goal with
    | [ |- context[(?p * array ?a1 ?l1 ?s * array ?a2 ?l2 ?s)%pred] ] =>
      word_assert (a2 <= a1)%word;
      first [
        (* if two arrays start in the same place, try to prove one of them is empty and eliminate it *)
        word_assert (a1 = a2)%word;
        first [
          let H := fresh in assert (length l1 = 0) by solve_lengths;
          apply length_nil in H; try rewrite H; clear H; simpl; rewrite emp_star_r'
        | let H := fresh in assert (length l2 = 0) by solve_lengths;
          apply length_nil in H; try rewrite H; clear H; simpl; rewrite emp_star_r'
        | fail 2
        ]
      | (* otherwise, just swap *)
        rewrite (sep_star_assoc p (array a1 l1 s));
        rewrite (sep_star_comm (array a1 l1 s)); rewrite <- (sep_star_assoc p (array a2 l2 s))
      ]
    end;
    (* make sure we can prove it's sorted *)
    match goal with
    | [ |- context[(?p * array ?a1 ?l1 ?s * array ?a2 ?l2 ?s)%pred] ] =>
      (word_assert (a1 <= a2)%word; fail 1) || fail 2
    | _ => idtac
    end;
    eapply pimpl_trans; rewrite <- emp_star; [ apply pimpl_refl |].

  Ltac array_sort :=
    word2nat_clear; word2nat_auto; [ array_sort' | .. ].

  Lemma singular_array: forall T a (v: T),
    a |-> v <=p=> array a [v] $1.
  Proof.
    intros. split; cancel.
  Qed.

  Lemma equal_arrays: forall T (l1 l2: list T) a1 a2,
    a1 = a2 -> l1 = l2 -> array a1 l1 $1 =p=> array a2 l2 $1.
  Proof.
    cancel.
  Qed.

  Ltac rewrite_singular_array :=
    repeat match goal with
    | [ |- context[@ptsto addr (@weq addrlen) ?V ?a ?v] ] =>
      setoid_replace (@ptsto addr (@weq addrlen) V a v)%pred
      with (array a [v] $1) by (apply singular_array)
    end.

  Ltac array_cancel_trivial :=
    fold unifiable_array;
    match goal with
    | [ |- _ =p=> ?x * unifiable_array ?a ?l ?s ] => first [ is_evar x | is_var x ]; unfold unifiable_array; rewrite (make_unifiable a l s)
    | [ |- _ =p=> unifiable_array ?a ?l ?s * ?x ] => first [ is_evar x | is_var x ]; unfold unifiable_array; rewrite (make_unifiable a l s)
    end;
    solve [ cancel ].


  (* Slightly different from CPDT [equate] *)
  Ltac equate x y :=
    let tx := type of x in
    let ty := type of y in
    let H := fresh in
    assert (x = y) as H by reflexivity; clear H.

  Ltac split_pair_list_evar :=
    match goal with
    | [ |- context [ ?l ] ] =>
      is_evar l;
      match type of l with
      | list (?A * ?B) =>
        let l0 := fresh in
        let l1 := fresh in
        evar (l0 : list A); evar (l1 : list B);
        let l0' := eval unfold l0 in l0 in
        let l1' := eval unfold l1 in l1 in
        equate l (@List.combine A B l0' l1');
        clear l0; clear l1
      end
    end.

  Theorem combine_upd: forall A B i a b (va: A) (vb: B),
    List.combine (upd a i va) (upd b i vb) = upd (List.combine a b) i (va, vb).
  Proof.
    unfold upd; intros.
    apply combine_updN.
  Qed.

  Lemma updN_0_skip_1: forall A l (a: A),
    length l > 0 -> updN l 0 a = a :: skipn 1 l .
  Proof.
    intros; destruct l.
    simpl in H. omega.
    reflexivity.
  Qed.

  Lemma cons_app: forall A l (a: A),
    a :: l = [a] ++ l.
  Proof.
    auto.
  Qed.

  Lemma combine_map_fst_snd: forall A B (l: list (A * B)),
    List.combine (map fst l) (map snd l) = l.
  Proof.
    induction l.
    auto.
    simpl; rewrite IHl; rewrite <- surjective_pairing; auto.
  Qed.

  Lemma map_fst_combine: forall A B (a: list A) (b: list B),
    length a = length b -> map fst (List.combine a b) = a.
  Proof.
    unfold map, List.combine; induction a; intros; auto.
    destruct b; try discriminate; simpl in *.
    rewrite IHa; [ auto | congruence ].
  Qed.

  Lemma map_snd_combine: forall A B (a: list A) (b: list B),
    length a = length b -> map snd (List.combine a b) = b.
  Proof.
    unfold map, List.combine.
    induction a; destruct b; simpl; auto; try discriminate.
    intros; rewrite IHa; eauto.
  Qed.

  Hint Rewrite firstn_combine_comm skipn_combine_comm selN_combine map_fst_combine map_snd_combine
    removeN_combine List.combine_split combine_nth combine_one cons_combine updN_0_skip_1 skipn_selN : lists.
  Hint Rewrite <- combine_updN combine_upd combine_app : lists.

  Ltac split_pair_list_vars :=
    set_evars;
    repeat match goal with
    | [ H : list (?A * ?B) |- _ ] =>
      match goal with
      | |- context[ List.combine (map fst H) (map snd H) ] => fail 1
      | _ => idtac
      end;
      rewrite <- combine_map_fst_snd with (l := H)
    end;
    subst_evars.

  Ltac split_lists :=
    unfold upd_prepend, upd_sync, valuset_list;
    unfold sel, upd;
    repeat split_pair_list_evar;
    split_pair_list_vars;
    autorewrite with lists; [
      match goal with
      | [ |- ?f _ = ?f _ ] => set_evars; f_equal; subst_evars
      | [ |- ?f _ _ = ?f _ _ ] => set_evars; f_equal; subst_evars
      | _ => idtac
      end | solve_lengths .. ].

  Ltac lists_eq :=
    subst; autorewrite with core; rec_simpl;
    word2nat_clear; word2nat_auto;
    autorewrite with lengths in *;
    solve_lengths_prepare;
    split_lists;
    repeat rewrite firstn_oob by solve_lengths_prepped;
    repeat erewrite firstn_plusone_selN by solve_lengths_prepped;
    unfold sel; repeat rewrite selN_app1 by solve_lengths_prepped; repeat rewrite selN_app2 by solve_lengths_prepped.
    (* intuition. *) (* XXX sadly, sometimes evars are instantiated the wrong way *)

  Ltac log_simp :=
    repeat rewrite descriptor_valu_id by (hnf; intuition; solve_lengths).

  Ltac chop_arrays a1 l1 a2 l2 s := idtac;
    match type of l2 with
     | list ?T =>
       let l1a := fresh in evar (l1a : list T);
       let l1b := fresh in evar (l1b : list T);
       let H := fresh in
       cut (l1 = l1a ++ l1b); [
         intro H; replace (array a1 l1 s) with (array a1 (l1a ++ l1b) s) by (rewrite H; trivial); clear H;
         rewrite <- (@array_app T l1a l1b a1 a2); [
           rewrite <- sep_star_assoc; apply pimpl_sep_star; [ | apply equal_arrays ]
         | ]
       | eauto ]
     end.

  Lemma cons_app1 : forall T (x: T) xs, x :: xs = [x] ++ xs. trivial. Qed.

  Ltac chop_shortest_suffix := idtac;
    match goal with
    | [ |- _ * array ?a1 ?l1 ?s =p=> _ * array ?a2 ?l2 ?s ] =>
      (let H := fresh in assert (a1 = a2)%word as H by
        (word2nat_simpl; repeat rewrite wordToNat_natToWord_idempotent'; word2nat_solve);
       apply pimpl_sep_star; [ | apply equal_arrays; [ try rewrite H; trivial | eauto ] ]) ||
      (word_assert (a1 <= a2)%word; chop_arrays a1 l1 a2 l2 s) ||
      (word_assert (a2 <= a1)%word; chop_arrays a2 l2 a1 l1 s)
    end.

  Ltac array_match_prepare :=
    unfold unifiable_array in *;
    match goal with (* early out *)
    | [ |- _ =p=> _ * array _ _ _ ] => idtac
    | [ |- _ =p=> _ * _ |-> _ ] => idtac
    | [ |- _ =p=> array _ _ _ ] => idtac
    end;
    solve_lengths_prepare;
    rewrite_singular_array;
    array_sort;
    eapply pimpl_trans; rewrite emp_star; [ apply pimpl_refl |];
    set_evars; repeat rewrite <- sep_star_assoc.

  Ltac array_match' :=
    array_match_prepare;
    repeat (progress chop_shortest_suffix);
    subst_evars; [ apply pimpl_refl | .. ].

  Ltac array_match_goal :=
      match goal with
      | [ |- @eq ?T ?a ?b ] =>
        match T with
        | list ?X =>
          (is_evar a; is_evar b; fail 1) || (* XXX this works around a Coq anomaly... *)
          lists_eq; auto; repeat match goal with
          | [ |- context[?a :: ?b] ] => match b with | nil => fail 1 | _ => idtac end; rewrite (cons_app1 a b); auto
          end
        | _ => idtac
        end
      | _ => idtac
      end.

  Ltac array_match :=
    array_match'; array_match_goal; array_match_goal; solve_lengths.

  Ltac or_r := apply pimpl_or_r; right.
  Ltac or_l := apply pimpl_or_r; left.


  Definition read_log T (xp : log_xparams) cs rx : prog T :=
    let^ (cs, d) <- BUFCACHE.read (LogDescriptor xp) cs;
    let desc := valu_to_descriptor d in
    let^ (cs, h) <- BUFCACHE.read (LogHeader xp) cs;
    let len := (valu_to_header h) :-> "length" in
    let^ (cs, log) <- For i < len
    Ghost [ cur log_on_disk F ]
    Loopvar [ cs log_prefix ]
    Continuation lrx
    Invariant
      rep xp F (Synced log_on_disk) cs
    * [[ log_prefix = firstn (# i) log_on_disk ]]
    OnCrash
      exists cs, rep xp F (Synced cur) cs
    Begin
      let^ (cs, v) <- BUFCACHE.read_array (LogData xp) i cs;
      lrx ^(cs, log_prefix ++ [(sel desc i $0, v)])
    Rof ^(cs, []);
    rx ^(log, cs).


  Theorem read_log_ok: forall xp cs,
    {< l F,
    PRE
      rep xp F (Synced l) cs
    POST RET:^(r,cs)
      [[ r = l ]] * rep xp F (Synced l) cs
    CRASH
      exists cs', rep xp F (Synced l) cs'
    >} read_log xp cs.
  Proof.
    unfold read_log; disklog_unfold.
    intros. (* XXX this hangs: autorewrite_fast_goal *)
    eapply pimpl_ok2; [ eauto with prog | ].
    unfold valid_size.
    cancel.
    eapply pimpl_ok2; [ eauto with prog | ].
    unfold valid_size.
    cancel.
    eapply pimpl_ok2; [ eauto with prog | ].
    unfold valid_size.
    cancel.
    eapply pimpl_ok2; [ eauto with prog | ].
    unfold valid_size.
    subst.
    rewrite header_valu_id in *.
    rec_simpl.
    cancel.
    fold unifiable_array; cancel_with solve_lengths.
    solve_lengths.
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    unfold log_contents in *.
    log_simp.
    lists_eq; reflexivity.
    cancel.
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    lists_eq; reflexivity.
    cancel.
    cancel.
    cancel.
  Qed.

  Hint Extern 1 ({{_}} progseq (read_log _ _) _) => apply read_log_ok : prog.


  Definition extend_unsync T xp (cs: cachestate) (old: log_contents) (oldlen: addr) (new: log_contents) rx : prog T :=
    cs <- BUFCACHE.write (LogDescriptor xp)
      (descriptor_to_valu (map fst (old ++ new))) cs;
    let^ (cs) <- For i < $ (length new)
    Ghost [ crash F ]
    Loopvar [ cs ]
    Continuation lrx
    Invariant
      exists d', BUFCACHE.rep cs d' *
      [[ (F
          * exists l', [[ length l' = # i ]]
          * array (LogData xp ^+ $ (length old)) (List.combine (firstn (# i) (map snd new)) l') $1
          * avail_region (LogData xp ^+ $ (length old) ^+ i) (# (LogLen xp) - length old - # i))%pred d' ]]
    OnCrash crash
    Begin
      cs <- BUFCACHE.write_array (LogData xp ^+ oldlen ^+ i) $0
        (sel (map snd new) i $0) cs;
      lrx ^(cs)
    Rof ^(cs);
    rx ^(cs).

  Definition extend_sync T xp (cs: cachestate) (old: log_contents) (oldlen: addr) (new: log_contents) rx : prog T :=
    cs <- BUFCACHE.sync (LogDescriptor xp) cs;
    let^ (cs) <- For i < $ (length new)
    Ghost [ crash F ]
    Loopvar [ cs ]
    Continuation lrx
    Invariant
      exists d', BUFCACHE.rep cs d' *
      [[ (F
          * array (LogData xp ^+ $ (length old)) (firstn (# i) (synced_list (map snd new))) $1
          * exists l', [[ length l' = length new - # i ]]
          * array (LogData xp ^+ $ (length old) ^+ i) (List.combine (skipn (# i) (map snd new)) l') $1
          * avail_region (LogData xp ^+ $ (length old) ^+ $ (length new)) (# (LogLen xp) - length old - length new))%pred d' ]]
    OnCrash crash
    Begin
      cs <- BUFCACHE.sync_array (LogData xp ^+ oldlen ^+ i) $0 cs;
      lrx ^(cs)
    Rof ^(cs);
    cs <- BUFCACHE.write (LogHeader xp) (header_to_valu (mk_header (length old + length new))) cs;
    cs <- BUFCACHE.sync (LogHeader xp) cs;
    rx ^(cs).

  Definition extend T xp (cs: cachestate) (old: log_contents) (oldlen: addr) (new: log_contents) rx : prog T :=
    If (lt_dec (wordToNat (LogLen xp)) (length old + length new)) {
      rx ^(^(cs), false)
    } else {
      (* Write... *)
      let^ (cs) <- extend_unsync xp cs old oldlen new;
      (* ... and sync *)
      let^ (cs) <- extend_sync xp cs old oldlen new;
      rx ^(^(cs), true)
    }.

  Definition extended_unsynced xp (old: log_contents) (new: log_contents) : @pred addr (@weq addrlen) valuset :=
     ([[ valid_size xp (old ++ new) ]] *
      (LogHeader xp) |=> (header_to_valu (mk_header (length old))) *
      exists rest rest2,
      (LogDescriptor xp) |-> (descriptor_to_valu (map fst (old ++ new) ++ rest),
                              [descriptor_to_valu (map fst old ++ rest2)]) *
      [[ @Rec.well_formed descriptor_type (map fst (old ++ new) ++ rest) ]] *
      [[ @Rec.well_formed descriptor_type (map fst old ++ rest2) ]] *
      array (LogData xp) (synced_list (map snd old)) $1 *
      exists unsynced, (* XXX unsynced is the wrong word for the old values *)
      [[ length unsynced = length new ]] *
      array (LogData xp ^+ $ (length old)) (List.combine (map snd new) unsynced) $1 *
      avail_region (LogData xp ^+ $ (length old) ^+ $ (length new))
                         (# (LogLen xp) - length old - length new))%pred.

  Lemma in_1 : forall T (x y: T), In x [y] -> x = y.
    intros.
    inversion H.
    congruence.
    inversion H0.
  Qed.


  Theorem extend_unsync_ok : forall xp cs old oldlen new,
    {< F,
    PRE
      [[ # oldlen = length old ]] *
      [[ valid_size xp (old ++ new) ]] *
      rep xp F (Synced old) cs
    POST RET:^(cs)
      exists d, BUFCACHE.rep cs d *
      [[ (F * extended_unsynced xp old new)%pred d ]]
    CRASH
      exists cs' : cachestate,
      rep xp F (Synced old) cs' \/ rep xp F (ExtendedDescriptor old) cs'
    >} extend_unsync xp cs old oldlen new.
  Proof.
    unfold extend_unsync; disklog_unfold; unfold avail_region, extended_unsynced.
    intros.
    solve_lengths_prepare.
    (* step. (* XXX takes a very long time *) *)
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    word2nat_clear.
    autorewrite with lengths in *.
    word2nat_auto.
    rewrite Nat.add_0_r.
    fold unifiable_array.
    cancel.
    instantiate (1 := nil); auto.
    solve_lengths.
    autorewrite with lengths in *.
    (* step. *)
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    word2nat_clear; word2nat_auto.
    fold unifiable_array; cancel.
    solve_lengths.
    (* step. *)
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    word2nat_clear; word2nat_auto.
    cancel.
    array_match.
    solve_lengths.
    solve_lengths.
    cancel.
    or_r; cancel.
    unfold valuset_list; simpl; rewrite map_app.
    rewrite <- descriptor_to_valu_zeroes with (n := addr_per_block - length old - length new).
    rewrite <- app_assoc.
    word2nat_clear.
    cancel.
    array_match.
    solve_lengths.
    rewrite Forall_forall; intuition.
    solve_lengths.
    rewrite Forall_forall; intuition.
    solve_lengths.

    or_r; cancel.
    unfold valuset_list; simpl; rewrite map_app.
    rewrite <- descriptor_to_valu_zeroes with (n := addr_per_block - length old - length new).
    rewrite <- app_assoc.
    cancel.
    (* unpack [array_match] due to "variable H4 unbound" anomaly *)
    array_match_prepare.
    chop_shortest_suffix.
    chop_shortest_suffix.
    chop_shortest_suffix.
    apply pimpl_refl.
    all: subst_evars.
    array_match_goal.
    2: array_match_goal.
    3: reflexivity.
    solve_lengths.
    solve_lengths.
    solve_lengths.
    rewrite Forall_forall; intuition.
    unfold upd_prepend.
    solve_lengths.
    rewrite Forall_forall; intuition.
    unfold upd_prepend.
    solve_lengths.

    (* step. *)
    eapply pimpl_ok2; [ eauto with prog | ].
    word2nat_clear.
    autorewrite with lengths in *.
    word2nat_auto.
    (* XXX once again we have to unpack [cancel] because otherwise [Forall_nil] gets incorrectly applied *)
    intros. norm. cancel'.
    unfold avail_region.
    intuition. pred_apply.
    norm. cancel'. unfold stars; simpl; eapply pimpl_trans; [ apply star_emp_pimpl |].
    unfold valuset_list.
    simpl.
    rewrite <- descriptor_to_valu_zeroes with (n := addr_per_block - length old - length new).
    cancel.
    unfold synced_list.
    array_match.
    intuition.
    unfold valid_size; solve_lengths.
    solve_lengths.
    rewrite Forall_forall; intuition.
    solve_lengths.
    congruence.
    congruence.
    autorewrite with lengths in *.
    cancel.
    or_r; cancel. (* this is a strange goal *)
    instantiate (m := d').
    pred_apply.
    cancel.
    unfold valuset_list.
    simpl.
    rewrite <- descriptor_to_valu_zeroes with (n := addr_per_block - length old - length new).
    rewrite map_app; rewrite <- app_assoc.
    cancel.
    solve_lengths.
    rewrite Forall_forall; intuition.
    solve_lengths.
    rewrite Forall_forall; intuition.
    solve_lengths.
    cancel.
    cancel.
    or_r; cancel.
    unfold valuset_list.
    simpl.
    rewrite <- descriptor_to_valu_zeroes with (n := addr_per_block - length old - length new).
    rewrite map_app; rewrite <- app_assoc.
    cancel.
    word2nat_clear; autorewrite with lengths in *.
    solve_lengths.
    rewrite Forall_forall; intuition.
    word2nat_clear; autorewrite with lengths in *.
    solve_lengths.
    rewrite Forall_forall; intuition.
    solve_lengths.

    Unshelve.
    all: eauto; constructor.
  Qed.

  Hint Extern 1 ({{_}} progseq (extend_unsync _ _ _ _ _) _) => apply extend_unsync_ok : prog.


  Theorem extend_sync_ok : forall xp cs old oldlen new,
    {< F,
    PRE
      [[ # oldlen = length old ]] *
      [[ valid_xp xp ]] *
      [[ valid_size xp (old ++ new) ]] *
      exists d, BUFCACHE.rep cs d *
      [[ (F * extended_unsynced xp old new)%pred d ]]
    POST RET:^(cs')
      rep xp F (Synced (old ++ new)) cs'
    CRASH
      exists cs' : cachestate,
      rep xp F (ExtendedDescriptor old) cs' \/ rep xp F (Synced old) cs' \/ rep xp F (Extended old new) cs' \/ rep xp F (Synced (old ++ new)) cs'
    >} extend_sync xp cs old oldlen new.
  Proof.
    unfold extend_sync; disklog_unfold; unfold avail_region, extended_unsynced.
    intros.
    solve_lengths_prepare.
    (* step. (* XXX takes a very long time *) *)
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    eapply pimpl_ok2; [ eauto with prog | ].
    unfold avail_region.
    cancel.
    word2nat_clear; word2nat_auto.
    rewrite Nat.add_0_r.
    fold unifiable_array; cancel.
    solve_lengths.
    solve_lengths.
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    word2nat_clear; word2nat_auto.
    fold unifiable_array; cancel.
    solve_lengths.
    unfold valid_size in *.
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    word2nat_clear.
    autorewrite with lengths in *.
    word2nat_auto.
    array_match_prepare.
    repeat chop_shortest_suffix.
    auto.
    (* subst_evars here would cause an anomaly trying to instantiate H14 *)
    subst H14.
    reflexivity.
    auto.
    subst_evars; reflexivity.
    subst H14.
    solve_lengths.
    (* XXX revise once the anomalies are fixed *)
    subst H14 H19.
    erewrite firstn_plusone_selN by solve_lengths.
    trivial.
    trivial.
    subst H12; trivial.
    subst H11.
    solve_lengths.
    unfold upd_sync.
    subst H11 H12.
    unfold sel, upd; simpl.
    instantiate (l'0 := skipn 1 l').
    subst H4.
    repeat rewrite selN_combine.
    lists_eq.
    subst H6.
    trivial.
    solve_lengths.
    autorewrite with lengths in *.
    solve_lengths.
    solve_lengths.
    cancel.
    or_r; or_l. norm. cancel'.
    repeat constructor. pred_apply.

    rewrite map_app.
    rewrite <- app_assoc.
    cancel.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    array_match.
    unfold synced_list. autorewrite with lengths. trivial.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    rewrite Forall_forall; intuition.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    solve_lengths.

    or_r; or_l; cancel.
    rewrite map_app.
    rewrite <- app_assoc.
    cancel.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    array_match.
    unfold synced_list. autorewrite with lengths. trivial.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    unfold upd_sync.
    solve_lengths.
    unfold upd_sync.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    rewrite Forall_forall; intuition.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    unfold upd_sync.
    solve_lengths.

    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    word2nat_clear.
    autorewrite with lengths in *.
    rewrite map_app.
    cancel.
    unfold synced_list.
    array_match_prepare.
    repeat chop_shortest_suffix.
    auto.
    subst_evars.
    reflexivity.
    reflexivity.
    subst H6. (* subst_evars here leads to an anomaly *)
    reflexivity.
    subst H4.
    solve_lengths.
    subst H4 H6.
    unfold valid_size in *.
    autorewrite with lengths in *.
    lists_eq.
    trivial.
    rewrite app_repeat.
    trivial.
    subst_evars.
    trivial.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.

    cancel.
    or_r; or_r; or_l; cancel.
    word2nat_clear. unfold valid_size in *. autorewrite with lengths in *.
    unfold synced_list.
    array_match_prepare.
    repeat chop_shortest_suffix.
    auto.
    subst_evars. reflexivity.
    reflexivity.
    (* subst_evars here gives an anomaly *) subst H6. reflexivity.
    subst H4. solve_lengths.
    subst H4 H6. lists_eq.
    trivial.
    rewrite app_repeat. trivial.
    subst H1. reflexivity.
    word2nat_clear. unfold valid_size in *. autorewrite with lengths in *.
    solve_lengths.

    or_r; or_r; or_r; cancel.
    word2nat_clear. unfold valid_size in *. autorewrite with lengths in *.
    unfold synced_list.
    cancel.
    array_match_prepare.
    repeat chop_shortest_suffix.
    auto.
    subst_evars. reflexivity.
    reflexivity.
    (* subst_evars here gives an anomaly *) subst H6. reflexivity.
    subst H4. solve_lengths.
    subst H4 H6. lists_eq.
    trivial.
    rewrite app_repeat. trivial.
    subst H1. reflexivity.
    word2nat_clear. unfold valid_size in *. autorewrite with lengths in *.
    solve_lengths.

    cancel.
    or_r; or_l; cancel.
    rewrite map_app.
    rewrite <- app_assoc.
    cancel.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    array_match.
    unfold synced_list. autorewrite with lengths. trivial.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    unfold upd_sync.
    solve_lengths.
    unfold upd_sync.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    rewrite Forall_forall; intuition.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    unfold upd_sync.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    unfold upd_sync.
    solve_lengths.

    cancel.
    or_r; or_r; or_l; cancel.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    unfold synced_list.
    array_match_prepare.
    repeat chop_shortest_suffix.
    auto.
    subst_evars. reflexivity.
    reflexivity.
    (* subst_evars here gives an anomaly *) subst H6. reflexivity.
    subst H4. solve_lengths.
    subst H4 H6. lists_eq.
    trivial.
    rewrite app_repeat. trivial.
    subst H1. reflexivity.
    word2nat_clear. unfold valid_size in *. autorewrite with lengths in *.
    solve_lengths.

    cancel.
    or_r; or_l; cancel.
    instantiate (1 := d').
    pred_apply. cancel.
    rewrite map_app.
    rewrite <- app_assoc.
    cancel.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    array_match.
    unfold synced_list. autorewrite with lengths. trivial.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    unfold upd_sync.
    solve_lengths.
    unfold upd_sync.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    rewrite Forall_forall; intuition.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    unfold upd_sync.
    solve_lengths.

    cancel.
    rewrite map_app.
    rewrite <- app_assoc.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    cancel.
    array_match.
    unfold synced_list. autorewrite with lengths. trivial.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    unfold upd_sync.
    solve_lengths.
    unfold upd_sync.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    solve_lengths.
    rewrite Forall_forall; intuition.
    word2nat_clear.
    unfold valid_size in *.
    autorewrite with lengths in *.
    unfold upd_sync.
    solve_lengths.

    Unshelve.
    all: auto.
  Qed.


  Hint Extern 1 ({{_}} progseq (extend_sync _ _ _ _ _) _) => apply extend_sync_ok : prog.

  Theorem extend_ok : forall xp cs old new rx,
    {< F,
    PRE
      rep xp F (Synced old) cs
    POST RET:^(cs,r)
      ([[ r = true ]] * rep xp F (Synced new) cs \/
      ([[ r = false ]] * rep xp F (Synced old) cs
    CRASH
      exists cs' : cachestate,
      rep xp F (ExtendedDescriptor old) cs' \/ rep xp F (Synced old) cs' \/ rep xp F (Extended old new) cs' \/ rep xp F (Synced (old ++ new)) cs'
    >} extend xp old new cs.
  Proof.
    unfold extend.
    step.
    step.
    step.
    step.
    step.
    or_l. cancel.
  Qed.

  Hint Extern 1 ({{_}} progseq (extend _ _ _ _) _) => apply extend_ok : prog.


  Definition shorten T xp newlen cs rx : prog T :=
    cs <- BUFCACHE.write (LogHeader xp) (header_to_valu (mk_header newlen)) cs;
    cs <- BUFCACHE.sync (LogHeader xp) cs;
    rx ^(cs).

  Theorem shorten_ok: forall xp newlen cs,
    {< F old,
    PRE
      [[ newlen <= length old ]] *
      rep xp F (Synced old) cs
    POST RET:^(cs)
      exists new cut,
      [[ old = new ++ cut ]] *
      [[ length new = newlen ]] *
      rep xp F (Synced new) cs
    CRASH
      exists cs' : cachestate,
      rep xp F (Synced old) cs' \/ rep xp F (Shortened old newlen) cs' \/
      exists new cut,
      [[ old = new ++ cut ]] *
      [[ length new = newlen ]] *
      rep xp F (Synced new) cs'
    >} shorten xp newlen cs.
  Proof.
    unfold shorten; disklog_unfold; unfold avail_region, valid_size.
    intros.
    solve_lengths_prepare.
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    eapply pimpl_ok2; [ eauto with prog | ].
    cancel.
    eapply pimpl_ok2; [ eauto with prog | ].
    intros. norm.
    cancel'. repeat constructor.
    (* XXX this looks rather hard to automate *)
    rewrite (firstn_skipn newlen).
    trivial.
    solve_lengths.
    pred_apply.
    cancel.
    (* XXX this is also hard to automate *)
    replace (map fst old) with (map fst (firstn newlen old ++ skipn newlen old)).
    rewrite map_app. rewrite <- app_assoc.
    autorewrite with lengths.
    rewrite Nat.min_l by auto.
    cancel.
    array_match_prepare.
    repeat chop_shortest_suffix.
    auto.
    subst_evars. reflexivity.
    reflexivity.
    subst_evars. reflexivity.
    subst H3. solve_lengths.
    subst H3 H4. lists_eq. rewrite firstn_skipn. trivial.
    rewrite app_repeat. (* XXX solve_lengths here gives an anomaly *)
    autorewrite with lengths. rewrite Nat.min_r by auto.
    (* XXX also not sure how to automate this *)
    instantiate (1 := length old - newlen).
    rewrite le_plus_minus_r by auto.
    trivial.
    trivial.
    subst_evars. trivial.
    subst_evars. solve_lengths.
    subst H1. solve_lengths.
    subst H1. solve_lengths.
    subst H0 H1 H2. trivial.
    rewrite firstn_skipn. trivial.
    solve_lengths.
    word2nat_clear. autorewrite with lengths in *.
    solve_lengths.
    trivial.
    rewrite Forall_forall; intuition.
    word2nat_clear. autorewrite with lengths in *.
    solve_lengths.
    solve_lengths.
    congruence.
    congruence.

    cancel.
    or_r; or_l; cancel.
    or_r; or_r.
    norm. cancel'.
    constructor. (* [intuition] screws up here... *)
    word2nat_clear. unfold valid_size in *. autorewrite with lengths in *.
    constructor.
    rewrite (firstn_skipn newlen).
    trivial.
    solve_lengths.
    intuition.
    pred_apply.
    cancel.
    replace (map fst old) with (map fst (firstn newlen old ++ skipn newlen old)).
    rewrite map_app. rewrite <- app_assoc.
    autorewrite with lengths.
    rewrite Nat.min_l by auto.
    cancel.
    array_match_prepare.
    repeat chop_shortest_suffix.
    auto.
    subst_evars. reflexivity.
    reflexivity.
    subst_evars. reflexivity.
    subst H3. solve_lengths.
    subst H3 H4. lists_eq. rewrite firstn_skipn. trivial.
    rewrite app_repeat. (* XXX solve_lengths here gives an anomaly *)
    autorewrite with lengths. rewrite Nat.min_r by auto.
    (* XXX also not sure how to automate this *)
    instantiate (1 := length old - newlen).
    rewrite le_plus_minus_r by auto.
    trivial.
    trivial.
    subst_evars. trivial.
    subst_evars. solve_lengths.
    subst H1. solve_lengths.
    subst H1. solve_lengths.
    subst H0 H1 H2. trivial.
    rewrite firstn_skipn. trivial.
    solve_lengths.
    word2nat_clear. autorewrite with lengths in *.
    solve_lengths.
    trivial.
    rewrite Forall_forall; intuition.
    word2nat_clear. autorewrite with lengths in *.
    solve_lengths.
    solve_lengths.

    cancel.
    or_l; cancel.
    or_r; or_l; cancel.
  Qed.

  Hint Extern 1 ({{_}} progseq (shorten _ _ _ _) _) => apply shorten_ok : prog.


  Lemma crash_invariant_synced_array: forall l start stride,
    crash_xform (array start (List.combine l (repeat nil (length l))) stride) =p=>
    array start (List.combine l (repeat nil (length l))) stride.
  Proof.
    unfold array.
    induction l; intros; simpl; auto.
    autorewrite with crash_xform.
    cancel.
    auto.
  Qed.
  Hint Rewrite crash_invariant_synced_array : crash_xform.

  Definition possible_crash_list (l: list valuset) (l': list valu) :=
    length l = length l' /\ forall i, i < length l -> In (selN l' i $0) (valuset_list (selN l i ($0, nil))).

  Lemma crash_xform_array: forall l start stride,
    crash_xform (array start l stride) =p=>
      exists l', [[ possible_crash_list l l' ]] * array start (List.combine l' (repeat nil (length l'))) stride.
  Proof.
    unfold array, possible_crash_list.
    induction l; intros.
    cancel.
    instantiate (1 := nil).
    simpl; auto.
    auto.
    autorewrite with crash_xform.
    rewrite IHl.
    cancel.
    instantiate (1 := v' :: l').
    all: simpl; auto; fold repeat; try cancel;
      destruct i; simpl; auto;
      destruct (H4 i); try omega; simpl; auto.
  Qed.

  Lemma crash_invariant_avail_region: forall start len,
    crash_xform (avail_region start len) =p=> avail_region start len.
  Proof.
    unfold avail_region.
    intros.
    autorewrite with crash_xform.
    norm'l.
    unfold stars; simpl.
    autorewrite with crash_xform.
    rewrite crash_xform_array.
    unfold possible_crash_list.
    cancel.
    solve_lengths.
  Qed.
  Hint Rewrite crash_invariant_avail_region : crash_xform.

  Definition would_recover_either' xp old cur :=
   (rep_inner xp (Synced old) \/
    (exists cut, [[ old = cur ++ cut ]] * rep_inner xp (Shortened old (length cur))) \/
    (exists new, [[ cur = old ++ new ]] * rep_inner xp (Extended old new)) \/
    rep_inner xp (Synced cur))%pred.

  Definition after_crash' xp old cur :=
   (rep_inner xp (Synced old) \/
    rep_inner xp (Synced cur))%pred.

  Lemma sep_star_or_distr_r: forall AT AEQ V (a b c: @pred AT AEQ V),
    (a \/ b) * c <=p=> a * c \/ b * c.
  Proof.
    intros.
    rewrite sep_star_comm.
    rewrite sep_star_or_distr.
    split; cancel.
  Qed.

  Lemma or_exists_distr : forall T AT AEQ V (P Q: T -> @pred AT AEQ V),
    (exists t: T, P t \/ Q t) =p=> (exists t: T, P t) \/ (exists t: T, Q t).
  Proof.
    firstorder.
  Qed.

  Lemma lift_or : forall AT AEQ V P Q,
    @lift_empty AT AEQ V (P \/ Q) =p=> [[ P ]] \/ [[ Q ]].
  Proof.
    firstorder.
  Qed.

  Lemma crash_xform_would_recover_either' : forall fsxp old cur,
    crash_xform (would_recover_either' fsxp old cur) =p=>
    after_crash' fsxp old cur.
  Proof.
    unfold would_recover_either', after_crash'; disklog_unfold; unfold avail_region, valid_size.
    intros.
    autorewrite with crash_xform.
(* XXX this hangs:
    setoid_rewrite crash_xform_sep_star_dist. *)
    repeat setoid_rewrite crash_xform_sep_star_dist at 1.
    setoid_rewrite crash_invariant_avail_region.
    setoid_rewrite crash_xform_exists_comm.
    setoid_rewrite crash_invariant_synced_array.
    repeat setoid_rewrite crash_xform_sep_star_dist at 1.
    setoid_rewrite crash_invariant_avail_region.
    setoid_rewrite crash_invariant_synced_array.
    cancel; autorewrite with crash_xform.
    + unfold avail_region; cancel_with solve_lengths.
    + cancel.
      or_r. subst. unfold avail_region. cancel_with solve_lengths.
      repeat rewrite map_app.
      rewrite <- app_assoc.
      cancel.
      autorewrite with lengths in *.
      array_match_prepare.
      repeat chop_shortest_suffix.
      auto.
      all: subst_evars.
      all: try reflexivity.
      solve_lengths.
      lists_eq.
      reflexivity.
      rewrite repeat_app.
      reflexivity.
      solve_lengths.
      autorewrite with lengths in *.
      solve_lengths.
      autorewrite with lengths in *.
      solve_lengths.
      rewrite Forall_forall; intuition.
      autorewrite with lengths in *.
      solve_lengths.
      exact (fun x => None).
      or_l. subst. unfold avail_region. unfold valid_size in *. cancel.
    + or_l. unfold avail_region. unfold valid_size in *.
      simpl.
      setoid_rewrite lift_or.
      repeat setoid_rewrite sep_star_or_distr_r.
      setoid_rewrite or_exists_distr.
      cancel.
      subst; cancel.
      all: trivial.
      subst; cancel.
      all: trivial.
    + cancel; subst.
      or_r. autorewrite with lengths. unfold avail_region. cancel.
      autorewrite with lengths in *. trivial.
      or_l. unfold avail_region. cancel.
      repeat rewrite map_app.
      rewrite <- app_assoc.
      cancel.
      autorewrite with lengths in *.
      array_match_prepare.
      repeat chop_shortest_suffix.
      auto.
      all: subst_evars.
      all: try reflexivity.
      solve_lengths.
      lists_eq.
      reflexivity.
      rewrite repeat_app.
      reflexivity.
      solve_lengths.
      autorewrite with lengths in *.
      solve_lengths.
      autorewrite with lengths in *.
      solve_lengths.
      rewrite Forall_forall; intuition.
      autorewrite with lengths in *.
      solve_lengths.
    + cancel.
      or_r. subst. unfold avail_region. unfold valid_size in *. cancel.
  Qed.

End DISKLOG.