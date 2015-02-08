Require Import Eqdep_dec Arith Omega List.
Require Import Word WordAuto Pred GenSep Rec Prog BasicProg Hoare SepAuto Array MemLog.
Require Import BFile RecArray Inode.

Set Implicit Arguments.

Section RECBFILE.

  Variable itemtype : Rec.type.
  Variable items_per_valu : addr.
  Definition item := Rec.data itemtype.
  Definition item_zero := @Rec.of_word itemtype $0.
  Definition blocktype : Rec.type := Rec.ArrayF itemtype (wordToNat items_per_valu).
  Definition block := Rec.data blocktype.
  Definition block_zero := @Rec.of_word blocktype $0.
  Variable blocksz_ok : valulen = Rec.len blocktype.

  Theorem items_per_valu_not_0 : items_per_valu <> $0.
  Proof.
    intro H.
    unfold blocktype in blocksz_ok.
    rewrite H in blocksz_ok.
    simpl in blocksz_ok.
    rewrite valulen_is in blocksz_ok.
    discriminate.
  Qed.

  Definition rep_block := RecArray.rep_block blocksz_ok.
  Definition valu_to_block := RecArray.valu_to_block itemtype items_per_valu blocksz_ok.
  Definition rep_valu_id := RecArray.rep_valu_id blocksz_ok.

  (** Get the [pos]'th item in the [block_ix]'th block of inode [inum] *)
  Definition bf_get_pair T lxp ixp inum block_ix pos ms rx : prog T :=
    v <- BFILE.bfread lxp ixp inum block_ix ms;
    let ib := valu_to_block v in
    let i := sel ib pos item_zero in
    rx i.

  (** Update the [pos]'th item in the [block_ix]'th block of inode [inum] to [i] *)
  Definition bf_put_pair T lxp ixp inum block_ix pos i ms rx : prog T :=
    v <- BFILE.bfread lxp ixp inum block_ix ms;
    let ib' := upd (valu_to_block v) pos i in
    let v' := rep_block ib' in
    ms <- BFILE.bfwrite lxp ixp inum block_ix v' ms;
    rx ms.

  Definition array_item_pairs (vs : list block) : pred :=
    ([[ Forall Rec.well_formed vs ]] *
     array $0 (map rep_block vs) $1)%pred.

  Definition array_item (vs : list item) :=
    (exists vs_nested, array_item_pairs vs_nested *
     [[ vs = fold_right (@app _) nil vs_nested ]])%pred.

  Hint Rewrite map_length.
  Hint Rewrite seq_length.
  Hint Resolve wlt_lt.
  Hint Rewrite sel_map_seq using auto.
  Hint Rewrite rep_valu_id.

  Theorem bf_get_pair_ok : forall lxp bxp ixp inum ms block_ix pos,
    {< F A mbase m flist f ilistlist,
    PRE    MEMLOG.rep lxp (ActiveTxn mbase m) ms *
           [[ (F * BFILE.rep bxp ixp flist)%pred (list2mem m) ]] *
           [[ (A * inum |-> f)%pred (list2mem flist) ]] *
           [[ array_item_pairs ilistlist (list2mem (BFILE.BFData f)) ]] *
           [[ (block_ix < $ (length (BFILE.BFData f)))%word ]] *
           [[ (pos < items_per_valu)%word ]]
    POST:r MEMLOG.rep lxp (ActiveTxn mbase m) ms *
           [[ r = sel (sel ilistlist block_ix nil) pos item_zero ]]
    CRASH  MEMLOG.log_intact lxp mbase
    >} bf_get_pair lxp ixp inum block_ix pos ms.
  Proof.
    unfold bf_get_pair.
    unfold array_item_pairs.
    hoare.
    rewrite isolate_fwd with (i:=block_ix). cancel.
    eapply list2mem_array_eq in H6; try exact $0.
    rewrite <- H6.
    admit.

    instantiate (b:=$ INODE.blocks_per_inode).
    admit.
    admit.

    autorewrite with defaults in *.

    eapply list2mem_array_eq in H6; try exact $0.
    assert (length l0 = length (BFILE.BFData b)).
    rewrite H6. autorewrite with core. reflexivity.

    subst.
    erewrite sel_map.
    autorewrite with core.
    trivial.
    rewrite Forall_forall in *. apply H11.
    apply in_selN. rewrite <- H in H5. admit.
    admit.

    instantiate (b:=$ INODE.blocks_per_inode).
    admit.
    admit.
  Qed.

  Theorem bf_put_pair_ok : forall lxp bxp ixp inum ms block_ix pos i,
    {< F A mbase m flist f ilistlist,
    PRE      MEMLOG.rep lxp (ActiveTxn mbase m) ms *
             [[ (F * BFILE.rep bxp ixp flist)%pred (list2mem m) ]] *
             [[ (A * inum |-> f)%pred (list2mem flist) ]] *
             [[ array_item_pairs ilistlist (list2mem (BFILE.BFData f)) ]] *
             [[ (block_ix < $ (length (BFILE.BFData f)))%word ]] *
             [[ (pos < items_per_valu)%word ]] *
             [[ Rec.well_formed i ]]
    POST:ms' exists m' flist' f',
             MEMLOG.rep lxp (ActiveTxn mbase m') ms' *
             [[ (F * BFILE.rep bxp ixp flist')%pred (list2mem m') ]] *
             [[ (A * inum |-> f')%pred (list2mem flist') ]] *
             [[ array_item_pairs (upd ilistlist block_ix (upd (sel ilistlist block_ix nil) pos i)) (list2mem (BFILE.BFData f')) ]]
    CRASH    MEMLOG.log_intact lxp mbase
    >} bf_put_pair lxp ixp inum block_ix pos i ms.
  Proof.
    unfold bf_put_pair.
    unfold array_item_pairs.

    step.
    rewrite isolate_fwd with (i:=block_ix). cancel.
    eapply list2mem_array_eq in H7; try exact $0.
    admit.

    instantiate (b:=$ INODE.blocks_per_inode).
    admit.
    admit.

    step.
    rewrite isolate_fwd with (i:=block_ix). cancel.
    eapply list2mem_array_eq in H7; try exact $0.
    admit.

    instantiate (b:=$ INODE.blocks_per_inode).
    admit.
    admit.

    step.
    rewrite <- isolate_bwd with (i:=block_ix) (vs:=(map rep_block _)).
    autorewrite with defaults in *.
    simpl; autorewrite with core.
    cancel.
    erewrite sel_map.
    autorewrite with defaults.
    rewrite sel_upd_eq.
    autorewrite with core.
    cancel.

    rewrite Forall_forall in H12. eapply H12.
    apply in_sel.
    admit.
    admit.
    admit.
    admit.

    apply Forall_upd; eauto.
    autorewrite with core. intuition eauto.
    rewrite Forall_forall in H12. apply H12. apply in_sel.
    admit.

    apply Forall_upd; eauto.
    rewrite Forall_forall in H12. apply H12. apply in_sel.
    admit.
  Admitted.

  Hint Extern 1 ({{_}} progseq (bf_get_pair _ _ _ _ _ _) _) => apply bf_get_pair_ok : prog.
  Hint Extern 1 ({{_}} progseq (bf_put_pair _ _ _ _ _ _ _) _) => apply bf_put_pair_ok : prog.

  Definition bf_get T lxp ixp inum idx ms rx : prog T :=
    i <- bf_get_pair lxp ixp inum (idx ^/ items_per_valu) (idx ^% items_per_valu) ms;
    rx i.

  Definition bf_put T lxp ixp inum idx v ms rx : prog T :=
    ms <- bf_put_pair lxp ixp inum (idx ^/ items_per_valu) (idx ^% items_per_valu) v ms;
    rx ms.

  Theorem bf_get_ok : forall lxp bxp ixp inum idx ms,
    {< F A mbase m flist f ilist,
    PRE    MEMLOG.rep lxp (ActiveTxn mbase m) ms *
           [[ (F * BFILE.rep bxp ixp flist)%pred (list2mem m) ]] *
           [[ (A * inum |-> f)%pred (list2mem flist) ]] *
           [[ array_item ilist (list2mem (BFILE.BFData f)) ]] *
           [[ (idx < $ (length (BFILE.BFData f)) ^* items_per_valu)%word ]]
    POST:r MEMLOG.rep lxp (ActiveTxn mbase m) ms *
           [[ r = sel ilist idx item_zero ]]
    CRASH  MEMLOG.log_intact lxp mbase
    >} bf_get lxp ixp inum idx ms.
  Proof.
    unfold bf_get, array_item.
    pose proof items_per_valu_not_0.

    step.
    admit.
(*
    word2nat_auto.
    apply Nat.div_lt_upper_bound; eauto;
    rewrite mult_comm; eauto.
*)

    apply wmod_upper_bound; eauto.

    step.
    subst.
    unfold array_item_pairs in H6. unfold rep_block in H6. destruct_lift H6.
    apply nested_sel_divmod_concat; auto.
    eapply Forall_impl; [| apply H6].
    intro a. simpl. tauto.
  Qed.


  Theorem upd_divmod : forall (l : list block) (pos : addr) (v : item),
    Forall Rec.well_formed l
    -> Array.upd (fold_right (@app _) nil l) pos v =
       fold_right (@app _) nil (Array.upd l (pos ^/ items_per_valu)
         (Array.upd (sel l (pos ^/ items_per_valu) nil) (pos ^% items_per_valu) v)).
  Proof.
    pose proof items_per_valu_not_0.
    intros. unfold upd.
    rewrite <- updN_concat with (m := wordToNat items_per_valu).
    word2nat_auto. rewrite Nat.mul_comm. rewrite Nat.add_comm. rewrite <- Nat.div_mod.
    trivial. assumption. word2nat_auto.
    rewrite Forall_forall in *; intros; apply H0; assumption.
  Qed.

  Theorem bf_put_ok : forall lxp bxp ixp inum idx v ms,
    {< F A mbase m flist f ilist,
    PRE      MEMLOG.rep lxp (ActiveTxn mbase m) ms *
             [[ (F * BFILE.rep bxp ixp flist)%pred (list2mem m) ]] *
             [[ (A * inum |-> f)%pred (list2mem flist) ]] *
             [[ array_item ilist (list2mem (BFILE.BFData f)) ]] *
             [[ (idx < $ (length (BFILE.BFData f)) ^* items_per_valu)%word ]] *
             [[ Rec.well_formed v ]]
    POST:ms' exists m' flist' f', MEMLOG.rep lxp (ActiveTxn mbase m') ms' *
             [[ (F * BFILE.rep bxp ixp flist')%pred (list2mem m') ]] *
             [[ (A * inum |-> f')%pred (list2mem flist') ]] *
             [[ array_item (upd ilist idx v) (list2mem (BFILE.BFData f')) ]]
    CRASH  MEMLOG.log_intact lxp mbase
    >} bf_put lxp ixp inum idx v ms.
  Proof.
    unfold bf_put, array_item, array_item_pairs.
    pose proof items_per_valu_not_0.
    step.

    unfold array_item_pairs.
    cancel.
    apply wdiv_lt_upper_bound; try rewrite wmult_comm; auto.
    apply wmod_upper_bound; auto.

    eapply pimpl_ok2.
    eauto with prog.
    intros; simpl; subst.
    unfold array_item_pairs.
    cancel.

    rewrite upd_divmod; auto.
  Qed.

End RECBFILE.

Hint Extern 1 ({{_}} progseq (bf_get _ _ _ _ _ _ _ _) _) => apply bf_get_ok : prog.
Hint Extern 1 ({{_}} progseq (bf_put _ _ _ _ _ _ _ _ _) _) => apply bf_put_ok : prog.


(* Two BFileRec arrays should always be equal *)
Hint Extern 0 (okToUnify (array_item ?a ?b ?c _) (array_item ?a ?b ?c _)) =>
  unfold okToUnify; constructor : okToUnify.