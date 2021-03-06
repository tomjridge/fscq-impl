Require Import Mem.
Require Import Prog.
Require Import Log.
Require Import BFile.
Require Import Word.
Require Import BasicProg.
Require Import Bool.
Require Import Pred.
Require Import Hoare.
Require Import GenSep.
Require Import GenSepN.
Require Import SepAuto.
Require Import Idempotent.
Require Import Inode.
Require Import List.
Require Import Balloc.
Require Import Arith.
Require Import Array.
Require Import FSLayout.
Require Import Cache.
Require Import Rec.
Require Import RecArray.
Require Import Omega.
Require Import Eqdep_dec.
Require Import Bytes.
Require Import ProofIrrelevance.
Require Import BFileRec Rounding.

Set Implicit Arguments.
Import ListNotations.

(** SlowByteFile is built on top of BFileRec using bytes as the records.
It provides a byte abstraction to a BFILE by looping over single-byte
operations in BFileRec. Read and write take lists of bytes as inputs.
The "slow" part comes from doing operations byte at a time instead of
block at a time, as well as from using lists instead of words as input. *)
Module SLOWBYTEFILE.

  Definition byte_type := Rec.WordF 8.
  Definition itemsz := Rec.len byte_type.
  Definition items_per_valu : addr := $ valubytes.
  Theorem itemsz_ok : valulen = wordToNat items_per_valu * itemsz.
  Proof.
    unfold items_per_valu.
    rewrite valulen_is, valubytes_is.
    reflexivity.
  Qed.

  (* The bytes of a file are mapped onto a list of blocks:   *)
  (*   [ block 0 ... block n]                                *)
  (*   <-- allbytes      -->                                 *)
  (*   <-- bytes     -->                                     *)

  Definition bytes_rep f (allbytes : list byte) :=
    BFileRec.array_item_file byte_type items_per_valu itemsz_ok f allbytes /\
    # (natToWord addrlen (length allbytes)) = length allbytes.

  Definition rep (bytes : list byte) (f : BFILE.bfile) :=
    exists allbytes,
    bytes_rep f allbytes /\
    firstn (# (f.(BFILE.BFAttr).(INODE.ISize))) allbytes = bytes /\
    length bytes = (# (f.(BFILE.BFAttr).(INODE.ISize))) /\
    divup # (INODE.ISize (BFILE.BFAttr f)) valubytes * valubytes = length allbytes.

  Fixpoint apply_bytes (allbytes : list byte) (off : nat) (newdata : list byte) :=
    match newdata with
    | nil => allbytes
    | b :: rest => updN (apply_bytes allbytes (off+1) rest) off b
    end.

  Lemma apply_bytes_length : forall newdata allbytes off,
    length (apply_bytes allbytes off newdata) = length allbytes.
  Proof.
    induction newdata; simpl; intros; auto.
    rewrite length_updN. eauto.
  Qed.

  Lemma apply_bytes_upd_comm:
    forall rest allbytes off off' b, 
      off < off' ->
      apply_bytes (updN allbytes off b) off' rest = updN (apply_bytes allbytes off' rest) off b.
  Proof.
    induction rest.
    simpl. reflexivity.
    simpl.
    intros.
    rewrite IHrest.
    rewrite updN_comm.
    reflexivity.
    omega.
    omega.
  Qed.

  Definition hidden (P : Prop) : Prop := P.
  Opaque hidden.

  Definition update_bytes T fsxp inum (off : nat) (newdata : list byte) mscs (rx : _ -> prog T) :=
    let^ (mscs, finaloff) <- ForEach b rest newdata
      Ghost [ mbase F Fm A f allbytes ]
      Loopvar [ mscs boff ]
      Continuation lrx
      Invariant
        exists m' flist' f' allbytes',
          LOG.rep fsxp.(FSXPLog) F (ActiveTxn mbase m') mscs  *
          [[ (Fm * BFILE.rep fsxp.(FSXPBlockAlloc) fsxp.(FSXPInode) flist')%pred (list2mem m') ]] *
          [[ (A * #inum |-> f')%pred (list2nmem flist') ]] *
          [[ bytes_rep f' allbytes' ]] *
          [[ apply_bytes allbytes' boff rest = apply_bytes allbytes off newdata ]] *
          [[ boff <= length allbytes' ]] *
          [[ off + length newdata = boff + length rest ]] *
          [[ hidden (length allbytes = length allbytes') ]] *
          [[ hidden (BFILE.BFAttr f = BFILE.BFAttr f') ]]
      OnCrash
        exists m',
          LOG.rep fsxp.(FSXPLog) F (ActiveTxn mbase m') mscs
      Begin
         mscs <- BFileRec.bf_put byte_type items_per_valu itemsz_ok
            fsxp.(FSXPLog) fsxp.(FSXPInode) inum ($ boff) b mscs;
          lrx ^(mscs, boff + 1)
      Rof ^(mscs, off);
      rx mscs.

  Definition read_byte T fsxp inum (off:nat) mscs rx : prog T :=
  let^ (mscs, b) <- BFileRec.bf_get byte_type items_per_valu itemsz_ok
     fsxp.(FSXPLog) fsxp.(FSXPInode) inum ($ off) mscs;
     rx ^(mscs, b).

  Definition read_bytes T fsxp inum (off:nat) len mscs rx : prog T :=
    let^ (mscs, databytes) <- For i < len
      Ghost [ m mbase F Fm A f flist bytes ]
      Loopvar [ mscs l ]
      Continuation lrx
      Invariant
          LOG.rep fsxp.(FSXPLog) F (ActiveTxn mbase m) mscs *
          [[ (Fm * BFILE.rep fsxp.(FSXPBlockAlloc) fsxp.(FSXPInode) flist)%pred (list2mem m) ]] *
          [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
          [[ rep bytes f ]] *
          [[ l = firstn #i (skipn off bytes) ]]
     OnCrash
      exists m',
        LOG.rep fsxp.(FSXPLog) F (ActiveTxn mbase m') mscs
     Begin
      let^ (mscs, b) <- BFileRec.bf_get byte_type items_per_valu itemsz_ok
        fsxp.(FSXPLog) fsxp.(FSXPInode) inum ($ (off + #i)) mscs;
      lrx ^(mscs, l ++ [b])
    Rof ^(mscs, nil);
    rx ^(mscs, databytes).

  Lemma bound_helper : forall a b,
    # (natToWord addrlen b) = b -> a <= b -> a <= # (natToWord addrlen b).
  Proof.
    intuition.
  Qed.

  Lemma boff_le_length : forall T boff (l l' : list T) off x y z q,
    off + x = boff + S z ->
    off + y <= length (firstn q l') ->
    hidden (length l' = length l) ->
    x = y ->
    boff + 1 <= length l.
  Proof.
    intros.
    subst.
    rewrite firstn_length in *.
    eapply le_trans. eapply le_trans; [ | apply H0 ].
    omega.
    rewrite H1.
    apply Min.le_min_r.
  Qed.

  Lemma le_lt_S : forall a b,
    a + 1 <= b ->
    a < b.
  Proof.
    intros; omega.
  Qed.

  Hint Resolve bound_helper.
  Hint Resolve boff_le_length.
  Hint Resolve le_lt_S.

  Lemma apply_bytes_arrayN : forall olddata newdata oldbytes newbytes off F x,
    newbytes = apply_bytes oldbytes off newdata ->
    length newdata = length olddata ->
    (F * arrayN off olddata)%pred (list2nmem (firstn x oldbytes)) ->
    (F * arrayN off newdata)%pred (list2nmem (firstn x newbytes)).
  Proof.
    induction olddata; simpl; intros.
    - destruct newdata; simpl in *; try omega.
      congruence.
    - destruct newdata; simpl in *; try omega.
      subst.
      rewrite updN_firstn_comm.
      rewrite listupd_memupd.
      apply sep_star_comm. apply sep_star_assoc.
      eapply ptsto_upd.
      apply sep_star_assoc. apply sep_star_comm. apply sep_star_assoc.
      replace (off + 1) with (S off) by omega.
      eapply IHolddata; eauto.
      apply sep_star_assoc. apply H1.

      rewrite firstn_length.
      rewrite apply_bytes_length.
      apply sep_star_assoc in H1. apply sep_star_comm in H1. apply sep_star_assoc in H1.
      apply list2nmem_ptsto_bound in H1. rewrite firstn_length in H1. auto.
  Qed.


  Theorem read_byte_ok: forall fsxp inum off mscs,
    {< m mbase F Fx Fm A flist f bytes v,
    PRE LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
          [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist)%pred (list2mem m) ]] *
          [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
          [[ rep bytes f ]] *
          [[ (Fx * off |-> v)%pred (list2nmem bytes) ]]
    POST RET:^(mscs, b)
          LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
          [[ b = v ]]
    CRASH LOG.would_recover_old (FSXPLog fsxp) F mbase
     >} read_byte fsxp inum off mscs.
  Proof.
    unfold read_byte.
    unfold rep, bytes_rep.
    step.
    apply list2nmem_ptsto_bound in H4.
    rewrite firstn_length in H4.
    apply Nat.min_glb_lt_iff in H4. destruct H4.
    erewrite wordToNat_natToWord_bound.
    assumption.
    apply Nat.lt_le_incl. eassumption.
    step.
    Search ptsto list2nmem selN.
    eapply list2nmem_sel in H4 as H4'.

    apply list2nmem_ptsto_bound in H4.
    rewrite firstn_length in H4.
    Search lt Init.Nat.min.
    apply Nat.min_glb_lt_iff in H4. destruct H4.

    rewrite selN_firstn in H4' by eauto.
    unfold sel in H13.
    erewrite wordToNat_natToWord_bound in H13.
    rewrite H13.
    rewrite H4'.
    reflexivity.
    apply Nat.lt_le_incl. eassumption.
  Qed.

  Theorem read_bytes_ok: forall fsxp inum off len mscs,
  {< m mbase F Fx Fm A flist f bytes v,
  PRE LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
      [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist)%pred (list2mem m) ]] *
      [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
      [[ rep bytes f ]] *
      [[ length v = #len ]] *
      [[ (Fx * arrayN off v)%pred (list2nmem bytes) ]] *
      [[ off + #len <= length bytes ]]
   POST RET:^(mscs, databytes)
      LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
      [[ databytes = v ]]
   CRASH LOG.would_recover_old (FSXPLog fsxp) F mbase
   >} read_bytes fsxp inum off len mscs.
   Proof.
    unfold read_bytes, rep, bytes_rep.

    step. (* enter loop *)
    exists allbytes.
    split;  auto.

    step. (* bf_get *)
    (* we assert and prove this lemma first because it is used twice *)
    assert (Hoffm1: off + #(m1) < length allbytes0).
      (* without the bounds checking, this proof goes:
      m1 < off -> m1 < len
      -> off + m1 < off + len
      off + len < min( f.isize, length allbytes ) (firstn_length)
      length allbytes0 >= f.isize (from divup_ok)
      -> off + len < f.isize <= length allbytes0
      -> off + m1 < length allbytes0 *)
    apply le_trans with (off + #(len)).
    apply plus_lt_compat_l. apply wlt_lt. assumption.
    rewrite firstn_length in H4.
    apply Nat.min_glb_l in H4.
    apply le_trans with (# (INODE.ISize (BFILE.BFAttr f))). assumption.
    rewrite <- H22.
    apply divup_ok.
    erewrite wordToNat_natToWord_bound.
    apply Hoffm1.
    instantiate (bound := $ (length allbytes0)).
    rewrite H20.
    omega.

    step.
    exists allbytes; split; auto.
    subst.
      (* same charade as above *)
      assert (Hoffm1: off + #(m1) < #(INODE.ISize (BFILE.BFAttr f))).
      rewrite firstn_length in H4.
      apply Nat.min_glb_l in H4.
      apply le_trans with (off + #(len)).
      apply plus_lt_compat_l. apply wlt_lt. assumption.
      assumption.
    replace (# (m1 ^+ $ (1))) with (# (m1) + 1).
    erewrite firstn_plusone_selN.
    f_equal.
    f_equal.
    rewrite <- H16.
    unfold sel.

    erewrite wordToNat_natToWord_bound.
    apply selN_skip_first.
    apply Hoffm1.
    apply Nat.lt_le_incl.
    eassumption.
    rewrite skipn_length.
    apply Nat.lt_add_lt_sub_r.
    rewrite plus_comm.
    rewrite H18.
    apply Hoffm1.
    rewrite H18.
    omega.
    (* need to convert ^+ $(1) to +1 using bounds *)
      rewrite wplus_alt.
      unfold wplusN, wordBinN.
      simpl.
      erewrite wordToNat_natToWord_bound.
      reflexivity.
      (* same as H3, after some massaging *)
      apply wlt_lt in H3.
      unfold lt in H3.
      instantiate (bound := len).
      replace (# (m1) + 1) with (S # (m1)) by omega.
      eassumption.
    step.

    apply arrayN_list2nmem in H5.
    symmetry.
    rewrite <- H6.
    apply H5.
    (* Using arrayN_list2nmem requires a default value, which is never used,
        so we have to provide some value of type byte.
        This is seems like a bug in arrayN_list2nmem. *)
    apply ($ 0).

    apply LOG.activetxn_would_recover_old.

    Grab Existential Variables.
    exact tt.
  Qed.


  Theorem update_bytes_ok: forall fsxp inum off newdata mscs,
      {< m mbase F Fm A flist f bytes olddata Fx,
       PRE LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist)%pred (list2mem m) ]] *
           [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
           [[ rep bytes f ]] *
           [[ (Fx * arrayN off olddata)%pred (list2nmem bytes) ]] *
           [[ hidden (length olddata = length newdata) ]] *
           [[ off + length newdata <= length bytes ]]
      POST RET:mscs
           exists m', LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m') mscs *
           exists flist' f' bytes',
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist')%pred (list2mem m') ]] *
           [[ (A * #inum |-> f')%pred (list2nmem flist') ]] *
           [[ rep bytes' f' ]] *
           [[ (Fx * arrayN off newdata)%pred (list2nmem bytes') ]] *
           [[ hidden (BFILE.BFAttr f = BFILE.BFAttr f') ]]
       CRASH LOG.would_recover_old (FSXPLog fsxp) F mbase 
      >} update_bytes fsxp inum off newdata mscs.
  Proof.
    unfold update_bytes, rep, bytes_rep.

    step.   (* step into loop *)

    rewrite firstn_length in *.

    eapply le_trans. eapply le_plus_l. eapply le_trans. apply H4.

    apply Min.le_min_r.

    constructor.

    step.   (* bf_put *)

    erewrite wordToNat_natToWord_bound by eauto.
    eauto.

    constructor.


    step.
    rewrite length_upd. auto.
    rewrite <- H21.
    rewrite <- apply_bytes_upd_comm by omega.
    unfold upd.

    erewrite wordToNat_natToWord_bound by eauto.
    auto.

    rewrite length_upd.
    eauto.

    rewrite H18. rewrite length_upd. constructor.
    subst; simpl; auto.

    step.

    eexists.
    intuition.
    eauto.
    eauto.
    rewrite <- H15.
    rewrite firstn_length in *.
    rewrite <- H16.
    eauto.

    rewrite <- H15.
    rewrite <- H16.
    eauto.

    rewrite <- H15.
    eapply apply_bytes_arrayN. eauto.
    instantiate (olddata := olddata).
    eauto.
    eauto.

    apply LOG.activetxn_would_recover_old.
    Grab Existential Variables.
    exact tt. 
  Qed.

  Hint Extern 1 ({{_}} progseq (update_bytes _ _ _ _ _) _) => apply update_bytes_ok : prog.
  
  Definition grow_blocks T fsxp inum nblock mscs rx : prog T := 
    let^ (mscs) <- For i < nblock
      Ghost [ mbase F Fm A f bytes ]
      Loopvar [ mscs ]
      Continuation lrx
      Invariant
      exists m' flist f',
         LOG.rep fsxp.(FSXPLog) F (ActiveTxn mbase m') mscs  *
          [[ (Fm * BFILE.rep fsxp.(FSXPBlockAlloc) fsxp.(FSXPInode) flist)%pred (list2mem m') ]] *
          [[ (A * #inum |-> f')%pred (list2nmem flist) ]] *
          [[ bytes_rep f' (bytes ++ (repeat $0 (#i * valubytes)))  ]] *
          [[ hidden (BFILE.BFAttr f = BFILE.BFAttr f') ]]
      OnCrash
        exists m',
          LOG.rep fsxp.(FSXPLog) F (ActiveTxn mbase m') mscs
      Begin
       let^ (mscs, n) <- BFileRec.bf_getlen items_per_valu fsxp.(FSXPLog) fsxp.(FSXPInode) inum mscs;
       If (wlt_dec n (natToWord addrlen INODE.blocks_per_inode ^* items_per_valu)) {
         let^ (mscs, ok) <- BFileRec.bf_extend byte_type items_per_valu itemsz_ok fsxp.(FSXPLog) fsxp.(FSXPBlockAlloc) fsxp.(FSXPInode) inum $0 mscs;
         If (bool_dec ok true) {
           lrx ^(mscs)
         } else {
           rx ^(mscs, false)
         }
       } else {
         rx ^(mscs, false)
       }
    Rof ^(mscs);
    rx ^(mscs, true).

  Lemma item0_upd:
    (upd (item0_list byte_type items_per_valu itemsz_ok) $0 $0) = repeat $0 valubytes.
  Proof.
    rewrite BFileRec.item0_list_repeat.
    unfold items_per_valu. replace (# ($ valubytes)) with (valubytes).
    destruct valubytes; reflexivity.
    rewrite valubytes_is; reflexivity.
  Qed.

  Lemma natplus1_wordplus1_eq:
    forall (a:addr) (bound:addr),
      (a < bound)%word ->
      # (a) + 1 = # (a ^+ $ (1)).
  Proof.
    intros.
    rewrite wplus_alt. unfold wplusN, wordBinN. simpl.
    erewrite wordToNat_natToWord_bound. reflexivity.
    apply wlt_lt in H.
    instantiate (bound:=bound). omega.
  Qed.

  Lemma bytes_grow_oneblock_ok:
    forall bytes nblock f (bound:addr),
    (nblock < bound) % word ->
    array_item_file byte_type items_per_valu itemsz_ok f 
       ((bytes ++ repeat $ (0) (@wordToNat addrlen (nblock) * valubytes)) ++ 
        (upd (item0_list byte_type items_per_valu itemsz_ok) $0 $0)) ->
    array_item_file byte_type items_per_valu itemsz_ok f 
       (bytes ++ repeat $ (0) (@wordToNat addrlen (nblock ^+ $ (1)) * valubytes)).
  Proof.
    intros.
    pose proof item0_upd.
    rewrite  H1 in H0.
    rewrite <- app_assoc in H0.
    rewrite repeat_app in H0.
    replace (# (nblock ^+ $ (1)) * valubytes) with (# (nblock) * valubytes + valubytes).
    auto.

    replace (# (nblock ^+ $1)) with (#nblock + 1).
    rewrite Nat.mul_add_distr_r.
    omega.
    eapply natplus1_wordplus1_eq.
    instantiate (bound:=bound); eauto.
  Qed.


Hint Resolve bytes_grow_oneblock_ok.

  Lemma length_grow_oneblock_ok:
    forall (bytes: list byte) (nblock:addr) (bound:addr),
      (nblock < bound) % word ->
      ($ (length bytes + # (nblock) * valubytes) <
         $ (INODE.blocks_per_inode) ^* items_per_valu)%word ->
      @wordToNat addrlen ($ (length (bytes ++ repeat $ (0) (# (nblock) * valubytes)))) =
         length (bytes ++ repeat $ (0) (# (nblock) * valubytes))  ->
      @wordToNat addrlen ($ (length (bytes ++ repeat $ (0) (# (nblock ^+ $ (1)) * valubytes)))) =
      length (bytes ++ repeat $ (0) (# (nblock ^+ $ (1)) * valubytes)).
  Proof.
    intros.
    replace (# (nblock ^+ $1)) with (#nblock + 1).
    rewrite Nat.mul_add_distr_r.
    simpl.
    rewrite <- repeat_app.
    repeat rewrite app_length.
    repeat rewrite repeat_length.
    erewrite wordToNat_natToWord_bound. reflexivity.
    apply wlt_lt in H0.
    rewrite app_length in H1. rewrite repeat_length in H1. rewrite H1 in H0.
    instantiate (bound := $ (INODE.blocks_per_inode) ^* items_per_valu ^+ items_per_valu ^+ $1).
    unfold INODE.blocks_per_inode in *. unfold INODE.nr_direct, INODE.nr_indirect in *.
    unfold items_per_valu in *. rewrite valubytes_is. rewrite valubytes_is in H0.
    apply le_trans with (4097 + # ($ (12 + 512) ^* natToWord addrlen 4096)). omega.
    apply Nat.eq_le_incl.
    reflexivity.
    eapply natplus1_wordplus1_eq.
    instantiate (bound:=bound); eauto.
  Qed.

Hint Resolve length_grow_oneblock_ok.

  Theorem grow_blocks_ok: forall fsxp inum nblock mscs,
      {< m mbase F Fm flist f A bytes,
       PRE LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist)%pred (list2mem m) ]] *
           [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
           [[ bytes_rep f bytes ]]
      POST RET:^(mscs, ok)
           exists m', LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m') mscs *
            ([[ ok = false ]] \/      
           [[ ok = true ]] * exists flist' f',
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist')%pred (list2mem m') ]] *
           [[ (A * #inum |-> f')%pred (list2nmem flist') ]] *
           [[ hidden (BFILE.BFAttr f = BFILE.BFAttr f') ]] *
           [[ bytes_rep f' (bytes ++ (repeat $0 (# nblock * valubytes))) ]])
       CRASH LOG.would_recover_old (FSXPLog fsxp) F mbase 
       >} grow_blocks fsxp inum nblock mscs.
  Proof.
    unfold grow_blocks, rep, bytes_rep.
    step. (* step into loop *)
    rewrite app_nil_r.
    eauto.
    rewrite app_nil_r.
    eauto.
    constructor.
    step. (* getlen *)
    step. (* if *)
    step. (* bf_extend *)
    constructor.
    step. (* if statement *)
    step.
    step.
    (* true branch *)
    step.
    step.
    step.
    step.
   
    eapply pimpl_or_r; right; cancel.
    eauto.
    rewrite app_length in H18.
    eapply H18.
    apply LOG.activetxn_would_recover_old.

    Grab Existential Variables.
    all: eauto.
    exact tt.
  Qed.

  Hint Extern 1 ({{_}} progseq (grow_blocks _ _ _ _) _) => apply grow_blocks_ok : prog.


   Definition grow_file T fsxp inum newlen mscs rx : prog T :=
     let^ (mscs, oldattr) <- BFILE.bfgetattr fsxp.(FSXPLog) fsxp.(FSXPInode) inum mscs;
     let curlen := oldattr.(INODE.ISize) in
     let curblocks := divup #curlen valubytes  in
     let newblocks := divup newlen valubytes in
     let nblock := newblocks - curblocks in
     mscs <- BFILE.bfsetattr fsxp.(FSXPLog) fsxp.(FSXPInode) inum
                              (INODE.Build_iattr ($ (curblocks*valubytes))
                                                 (INODE.IMTime oldattr)
                                                 (INODE.IType oldattr)) mscs;
     mscs <- update_bytes fsxp inum #curlen (repeat $0 (curblocks*valubytes-#curlen)) mscs;
     let^ (mscs, ok) <- grow_blocks fsxp inum ($ nblock) mscs;
     If (bool_dec ok true) {
       mscs <- BFILE.bfsetattr fsxp.(FSXPLog) fsxp.(FSXPInode) inum
                              (INODE.Build_iattr ($ newlen)
                                                 (INODE.IMTime oldattr)
                                                 (INODE.IType oldattr)) mscs;
       rx ^(mscs, true)
     } else {
       rx ^(mscs, false)
     }.



  Lemma nblock_ok:
    forall oldlen newlen boundary nblock,
      oldlen <= newlen ->
      boundary = (divup oldlen valubytes) * valubytes ->
      nblock = (divup newlen valubytes) - (divup oldlen valubytes)->
      newlen - oldlen <= boundary - oldlen + nblock * valubytes.
  Proof.
    intros; subst.
    rewrite Nat.mul_sub_distr_r.
    rewrite <- Nat.add_sub_swap by apply divup_ok.
    apply Nat.sub_le_mono_r.
    rewrite Nat.add_sub_assoc by ( apply le_roundup; omega ).
    rewrite plus_comm.
    rewrite <- Nat.add_sub_assoc by reflexivity.
    rewrite <- minus_diag_reverse.
    rewrite <- plus_n_O.
    apply divup_ok.
  Qed.

  (* layout is [0 .. oldlen ...0... boundary ... nblock 0s ... ) *)
  (*           <-- bytes-->                                        *)
  (*           <-------- allbytes-->                               *)
  (* newlen is larger than oldlen, and perhaps larger than boundary *)
  (* lemma says that extending bytes with 0s to newlen is the same as  *)
  (* extending allbytes with with nblock 0s and taking firstn newlen. *)
  Lemma eq_bytes_allbytes_ext0_to_newlen:
    forall (allbytes: list byte) (oldlen:nat) (newlen:nat) bytes nbytes nblock,
      oldlen <= newlen ->
      (divup oldlen valubytes) * valubytes = length allbytes ->
      bytes = firstn oldlen allbytes ->
      nbytes = (length allbytes) - oldlen ->
      nblock = (divup newlen valubytes) - (divup oldlen valubytes) ->
      firstn newlen ((bytes ++ (repeat $0 nbytes)) ++ repeat $0 (nblock * valubytes)) = 
        (firstn oldlen allbytes) ++ (repeat $0 (newlen - oldlen)).
  Proof.
    intros.
    assert (length bytes = oldlen).
    subst. rewrite firstn_length. apply Nat.min_l.
    rewrite <- H0.
    apply divup_ok.
    rewrite <- app_assoc.
    rewrite firstn_app_le by omega.
    f_equal; auto.
    rewrite repeat_app.
    rewrite firstn_repeat_le.
    rewrite H4.
    eauto.
    rewrite H4.
    rewrite H2.
    apply nblock_ok; auto.
  Qed.

  Lemma grow_to_end_of_block_ok:
    forall f f' allbytes,
      array_item_file byte_type items_per_valu itemsz_ok f allbytes ->
      @wordToNat addrlen ($ (length allbytes)) = length allbytes ->
      divup # (INODE.ISize (BFILE.BFAttr f)) valubytes * valubytes = length allbytes ->
      f' =
      {|
      BFILE.BFData := BFILE.BFData f;
      BFILE.BFAttr := {|
                      INODE.ISize := $
                                     (divup # (INODE.ISize (BFILE.BFAttr f))
                                        valubytes * valubytes);
                      INODE.IMTime := INODE.IMTime (BFILE.BFAttr f);
                      INODE.IType := INODE.IType (BFILE.BFAttr f) |} |} ->
      rep allbytes f'.
   Proof.
    intros.
    unfold rep, bytes_rep in *.
    eexists.
    instantiate (allbytes := allbytes).
    intuition eauto.
    unfold array_item_file in *.
    subst; simpl in *.
    eauto.
    rewrite H2.
    simpl.
    rewrite H1.
    rewrite firstn_oob; eauto.
    subst; simpl.
    rewrite H1.
    eauto.
    subst; simpl.
    erewrite wordToNat_natToWord_bound.
    rewrite divup_divup_eq with (x := # (INODE.ISize (BFILE.BFAttr f))).
    rewrite H1.
    instantiate (bound := $ ( (divup # (INODE.ISize (BFILE.BFAttr f)) valubytes) * valubytes)).
    eauto.
    rewrite H1.
    eauto.
  Qed.

  Hint Resolve grow_to_end_of_block_ok.

   
  Lemma olddata_exists_in_block:
        forall f (allbytes: list byte),
        divup # (INODE.ISize (BFILE.BFAttr f)) valubytes * valubytes = length allbytes ->
        @wordToNat addrlen ($ (length allbytes)) = length allbytes ->
        (arrayN 0 (firstn # (INODE.ISize (BFILE.BFAttr f)) allbytes) *
          arrayN # (INODE.ISize (BFILE.BFAttr f))
           (skipn # (INODE.ISize (BFILE.BFAttr f)) allbytes))%pred (list2nmem allbytes).
  Proof.
       intros.
       replace (# (INODE.ISize (BFILE.BFAttr f))) with (0 + # (INODE.ISize (BFILE.BFAttr f))) at 2 by omega.
       apply arrayN_split.
       rewrite <- H.
       apply divup_ok.
       apply list2nmem_array.
  Qed.

  Hint Resolve olddata_exists_in_block.

  Lemma length_updatebytes_ok:
      forall f (allbytes: list byte),
        @wordToNat addrlen ($ (length allbytes)) = length allbytes ->
        divup # (INODE.ISize (BFILE.BFAttr f)) valubytes * valubytes = length allbytes ->
          length (skipn (@wordToNat addrlen (INODE.ISize (BFILE.BFAttr f))) allbytes) =
          length (repeat (@natToWord addrlen 0) ((divup (@wordToNat addrlen (INODE.ISize (BFILE.BFAttr f))) valubytes) * valubytes 
                                 - (@wordToNat addrlen (INODE.ISize (BFILE.BFAttr f))))).
  Proof.
      intros.
      rewrite skipn_length.
      rewrite repeat_length.
      eauto.
      rewrite <- H0.
      apply divup_ok.
  Qed.

  Hint Resolve length_updatebytes_ok.

  Lemma after_grow_to_block_bytes_rep_ok:
        forall f f' (bytes' : list byte) (allbytes: list byte),
          (arrayN 0 (firstn # (INODE.ISize (BFILE.BFAttr f)) allbytes) *
            arrayN # (INODE.ISize (BFILE.BFAttr f))
             (repeat $ (0)
                (divup # (INODE.ISize (BFILE.BFAttr f)) valubytes * valubytes -
                    # (INODE.ISize (BFILE.BFAttr f)))))%pred (list2nmem bytes') ->
          divup # (INODE.ISize (BFILE.BFAttr f)) valubytes * valubytes = length allbytes ->
          rep bytes' f' ->
          # (INODE.ISize (BFILE.BFAttr f')) = divup # (INODE.ISize (BFILE.BFAttr f)) valubytes * valubytes ->
          bytes_rep f' ((firstn # (INODE.ISize (BFILE.BFAttr f)) allbytes) ++ (repeat $ (0)
            (divup # (INODE.ISize (BFILE.BFAttr f)) valubytes *
             valubytes - # (INODE.ISize (BFILE.BFAttr f))))).
  Proof.
       intros.
       unfold rep in *.
       destruct H1.
       intuition.
       apply arrayN_combine with (off := # (INODE.ISize (BFILE.BFAttr f))) in H.
       eapply list2nmem_array_eq in H.
       rewrite <- H4 in H1.
       rewrite firstn_oob in H1.
       rewrite H1 in H3.
       rewrite H in H3.
       assumption.
       rewrite <- H6.
       rewrite  H4.
       rewrite H2.
       rewrite divup_divup_eq.
       omega.
       rewrite firstn_length.
       rewrite Nat.min_l.
       eauto.
       rewrite <- H0.
       apply divup_ok.
  Qed.

  Lemma divup_newlen_minus_oldlen_goodSize:
    forall oldlen newlen a,
      newlen = @wordToNat addrlen a ->
      goodSize addrlen (divup newlen valubytes - divup oldlen valubytes).
  Proof.
    intros.
    unfold goodSize.
    apply lt_minus'.
    subst.
    apply divup_goodSize.
  Qed.

  
  Lemma len_oldlenext_newlen_eq:
    forall oldlen newlen,
      divup newlen valubytes * valubytes =
       oldlen + divup oldlen valubytes * valubytes - oldlen +
        divup newlen valubytes * valubytes -
        divup oldlen valubytes * valubytes.
  Proof.
    intros.
    rewrite minus_plus.
    rewrite minus_plus.
    eauto.
 Qed.

   Lemma after_grow_rep_ok:
      forall f f'' (bytes: list byte) (allbytes: list byte) newlen oldlen,
         divup # (INODE.ISize (BFILE.BFAttr f)) valubytes * valubytes = length allbytes ->
         newlen = # (INODE.ISize (BFILE.BFAttr f'')) ->
         oldlen = # (INODE.ISize (BFILE.BFAttr f)) ->
         oldlen <= newlen ->
         bytes_rep f'' ((firstn oldlen allbytes ++
          repeat $ (0) (divup oldlen valubytes * valubytes - oldlen)) ++
          repeat $ (0) (@wordToNat addrlen ($ (divup newlen valubytes -
                     divup oldlen valubytes)) * valubytes)) -> 
          rep (firstn oldlen allbytes ++ repeat $ (0) (newlen - oldlen)) f''.
   Proof.
     intros.
     unfold rep.
     eexists.
     instantiate (allbytes := ((firstn # (INODE.ISize (BFILE.BFAttr f)) allbytes ++
          repeat $ (0)
            (divup # (INODE.ISize (BFILE.BFAttr f)) valubytes *
             valubytes - # (INODE.ISize (BFILE.BFAttr f)))) ++
         repeat $ (0)
           (# ($
               (divup newlen valubytes -
                divup # (INODE.ISize (BFILE.BFAttr f)) valubytes)) *
            valubytes))).
    intuition.
    eauto.
    unfold bytes_rep in H1.
    rewrite <- H1.
    eauto.
    rewrite <- H1.
    rewrite <- H0.
    erewrite eq_bytes_allbytes_ext0_to_newlen with (oldlen := oldlen) (allbytes := allbytes).
    eauto.
    eauto.
    subst; eauto.
    eauto.
    subst; eauto.
    erewrite wordToNat_natToWord_idempotent'.
    eauto.
    eapply divup_newlen_minus_oldlen_goodSize with (a := (INODE.ISize (BFILE.BFAttr f''))); eauto.
    rewrite app_length.
    rewrite firstn_length.
    rewrite repeat_length.
    rewrite Nat.min_l.
    omega.
    rewrite <- H.
    subst.
    apply divup_ok.
    repeat rewrite app_length.
    rewrite firstn_length.
    repeat rewrite repeat_length.
    rewrite Nat.min_l.
    repeat rewrite <- H0.
    repeat rewrite <- H1.
    erewrite wordToNat_natToWord_idempotent'.
    rewrite Nat.mul_sub_distr_r.
    repeat rewrite Nat.add_sub_assoc.
    apply len_oldlenext_newlen_eq.
    unfold ge.
    apply divup_ok.
    apply le_roundup; eauto.
    eapply divup_newlen_minus_oldlen_goodSize with (a := (INODE.ISize (BFILE.BFAttr f''))); eauto.
    eapply le_trans.
    apply divup_ok.
    omega.
   Qed.


  Theorem grow_file_ok: forall fsxp inum newlen mscs,
    {< m mbase F Fm A flist f bytes,
      PRE LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist)%pred (list2mem m) ]] *
           [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
           [[ rep bytes f ]] *
           [[ (# (INODE.ISize (BFILE.BFAttr f))) <= newlen ]] *
           [[ goodSize addrlen newlen ]]
      POST RET:^(mscs, ok)
           exists m', LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m') mscs *
           ([[ ok = false ]] \/
           [[ ok = true ]] * exists flist' f' bytes' fdata' attr,
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist')%pred (list2mem m') ]] *
           [[ (A * #inum |-> f')%pred (list2nmem flist') ]] *
           [[ bytes' = (bytes ++ (repeat $0 (newlen -  (# (INODE.ISize (BFILE.BFAttr f)))))) ]] *
           [[ rep bytes' f']] *
           [[ attr = INODE.Build_iattr ($ newlen) (f.(BFILE.BFAttr).(INODE.IMTime)) (f.(BFILE.BFAttr).(INODE.IType))]] *
           [[ f' = BFILE.Build_bfile fdata' attr]])
       CRASH LOG.would_recover_old (FSXPLog fsxp) F mbase 
     >} grow_file fsxp inum newlen mscs.
   Proof.
     unfold grow_file, rep, bytes_rep.
     step.  (* getattr *)
     step.  (* set attributes *)
     step.  (* update bytes *)

     rewrite length_updatebytes_ok.
     repeat rewrite repeat_length.
     constructor; eauto.
     eauto.
     eauto.
     eauto.

     rewrite repeat_length.
     rewrite H10.
     subst; simpl.
     rewrite le_plus_minus_r; try omega.
     eapply le_trans.
     apply divup_ok.
     omega.

     step.  (* grow blocks *)

     eapply after_grow_to_block_bytes_rep_ok with (bytes' := bytes'); eauto.

     rewrite <- H17.
     simpl.

     unfold rep, bytes_rep in *.
     deex.

     eapply bfrec_bound in H0; eauto.
     rewrite H10.
     erewrite wordToNat_natToWord_bound; eauto.

     step.
     step.
     step.
     step.
     step.
     eapply pimpl_or_r; right; cancel.

     assert (rep (firstn (@wordToNat addrlen (INODE.ISize (BFILE.BFAttr f))) allbytes ++
         repeat $ (0) (newlen - (@wordToNat addrlen (INODE.ISize (BFILE.BFAttr f))))) 
           {|
           BFILE.BFData := BFILE.BFData f'0;
           BFILE.BFAttr := {|
                         INODE.ISize := $ (newlen);
                         INODE.IMTime := INODE.IMTime (BFILE.BFAttr f);
                         INODE.IType := INODE.IType (BFILE.BFAttr f) |} |} ) as Hrep 
      by (eapply after_grow_rep_ok; eauto; simpl; rewrite wordToNat_natToWord_idempotent'; eauto).
    unfold rep in Hrep.
    intuition; eauto.

    step.
    Grab Existential Variables.
    all: eauto. 
    exact (FSXPBlockAlloc fsxp).
   Qed.

  Hint Extern 1 ({{_}} progseq (grow_file _ _ _ _) _) => apply grow_file_ok : prog.

  
  Definition write_bytes T fsxp inum (off : nat) (data : list byte) mscs rx : prog T :=
    let newlen := off + length data in
    let^ (mscs, oldattr) <- BFILE.bfgetattr fsxp.(FSXPLog) fsxp.(FSXPInode) inum mscs;
    let curlen := oldattr.(INODE.ISize) in      
    If (wlt_dec curlen ($ newlen)) {
         let^ (mscs, ok) <- grow_file fsxp inum newlen mscs;
         If (bool_dec ok true) {
           mscs <-  update_bytes fsxp inum off data mscs;
           rx ^(mscs, ok)
        } else {
           rx ^(mscs, false)
        }
    } else {
        mscs <-  update_bytes fsxp inum off data mscs;
        rx ^(mscs, true)
    }.

  Lemma off_in_bounds_ext:
    forall off f bytes (newdata: list byte),
      rep bytes f ->
        off <= length (bytes ++ repeat $ (0) (off + length newdata - # (INODE.ISize (BFILE.BFAttr f)))).
  Proof.
    intros.
    rewrite app_length.
    rewrite repeat_length.
    unfold rep in H.
    destruct H.
    intuition.
  Qed.

  Lemma length_rep:
    forall f bytes,
      rep bytes f -> length bytes = # (INODE.ISize (BFILE.BFAttr f)).
  Proof.
    intros.
    unfold rep in H.
    destruct H.
    intuition.
  Qed.

  Lemma helper_sep_star_comm_middle : forall AT AEQ V (m : @mem AT AEQ V) a b c,
    ((a * b) * c)%pred m -> (a * c * b)%pred m.
  Proof.
    intros; pred_apply; cancel.
  Qed.

  Lemma len_olddata_newdata_grown_eq:
      forall f (newdata: list byte) (bytes: list byte) off,
        goodSize addrlen (off + length newdata) ->
        rep bytes f ->
        (INODE.ISize (BFILE.BFAttr f) < $ (off + length newdata))%word ->
        length (skipn off (bytes ++ 
            repeat $ (0) (off + length newdata - # (INODE.ISize (BFILE.BFAttr f))))) =
          length newdata.
  Proof.
      intros.
      rewrite skipn_length.
      rewrite app_length.
      rewrite repeat_length.
      unfold rep in H0.
      destruct H0.
      intuition.
      rewrite H3.
      rewrite Nat.add_sub_assoc.
      rewrite minus_plus.
      rewrite minus_plus.
      eauto.
      apply wlt_lt in H1.
      erewrite wordToNat_natToWord_idempotent' in H1 by eauto.
      apply Nat.lt_le_incl. 
      eauto.
      apply off_in_bounds_ext.
      eauto.
  Qed.

  Lemma olddata_exists_in_grown_file:
       forall f (newdata: list byte) (bytes: list byte) off,
        rep bytes f ->
 (arrayN 0
   (firstn off
      (bytes ++ repeat $ (0) (off + length newdata - # (INODE.ISize (BFILE.BFAttr f))))) *
 arrayN off
   (skipn off
      (bytes ++ repeat $ (0) (off + length newdata - # (INODE.ISize (BFILE.BFAttr f))))))%pred
  (list2nmem
     (bytes ++ repeat $ (0) (off + length newdata - # (INODE.ISize (BFILE.BFAttr f))))).
  Proof.
    intros.
    apply arrayN_split.
     apply off_in_bounds_ext; eauto.
    eapply list2nmem_array.
  Qed.

   Lemma off_le_bytes:
      forall off len lenbytes,
        off + len <= lenbytes -> off <= lenbytes.
   Proof.
     intros.
     omega.
   Qed.

   Lemma olddata_exists_in_file:
      forall f (newdata: list byte) (bytes: list byte) off,
        rep bytes f ->
        off + length newdata <= length bytes ->
         (arrayN 0 (firstn off bytes) *
          arrayN (off + length newdata) (skipn (length newdata) (skipn off bytes)) *
          arrayN off (firstn (length newdata) (skipn off bytes)))%pred (list2nmem bytes).
   Proof.
    intros.
    apply helper_sep_star_comm_middle.
    rewrite arrayN_combine.  
    apply arrayN_combine.
    rewrite app_length.
    rewrite firstn_length.
    rewrite Nat.min_l.
    rewrite firstn_length.
    rewrite Nat.min_l.
    omega.
    rewrite skipn_length.
    erewrite plus_le_reg_l with (p := off) (m := (length bytes - off)). 
    omega.
    rewrite Nat.add_sub_assoc.
    rewrite minus_plus.
    eauto.
    rewrite off_le_bytes with (len := length newdata) (lenbytes := length bytes); eauto.
    rewrite off_le_bytes with (len := length newdata) (lenbytes := length bytes); eauto.
    rewrite off_le_bytes with (len := length newdata) (lenbytes := length bytes); eauto.
    rewrite <- app_assoc.
    rewrite firstn_skipn.
    rewrite firstn_skipn.
    apply list2nmem_array.
    rewrite firstn_length.
    rewrite Nat.min_l.
    eauto.
    rewrite off_le_bytes with (len := length newdata) (lenbytes := length bytes); eauto.
   Qed.

   Lemma len_olddata_newdata_eq:
      forall f (newdata: list byte) off (bytes: list byte),
      off + length newdata <= length bytes ->
      rep bytes f ->
      length (firstn (length newdata) (skipn off bytes)) = length newdata.
    Proof.
      intros.
      rewrite firstn_length.
      rewrite Nat.min_l.
      eauto.
      rewrite skipn_length.
      omega.
      rewrite off_le_bytes with (len := length newdata) (lenbytes := length bytes); eauto.
    Qed.

  Lemma off_length_in_bounds:
    forall f off (bytes: list byte) (newdata: list byte),
      goodSize addrlen (off+length newdata) ->
      rep bytes f ->
      ((INODE.ISize (BFILE.BFAttr f) < $ (off + length newdata))%word -> False) ->
      off + length newdata <= length bytes.
  Proof.
    intros.
    apply wle_le in H1.
    erewrite wordToNat_natToWord_idempotent' in H1 by auto.
    rewrite length_rep with (f := f) (bytes := bytes); eauto.
  Qed.

  Theorem write_bytes_ok: forall fsxp inum (off:nat) (newdata: list byte) mscs,
    {< m mbase F Fm A flist f bytes,
      PRE LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist)%pred (list2mem m) ]] *
           [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
           [[ rep bytes f ]] *
           [[ goodSize addrlen (off+length newdata) ]]
       POST RET:^(mscs, ok)
           exists m', LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m') mscs *
           ([[ ok = false ]] \/
           [[ ok = true ]] * exists flist' f' bytes' Fx,
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist')%pred (list2mem m') ]] *
           [[ (A * #inum |-> f')%pred (list2nmem flist') ]] *
           [[ rep bytes' f' ]] *
           [[ (Fx * arrayN off newdata)%pred (list2nmem bytes')]])
       CRASH LOG.would_recover_old (FSXPLog fsxp) F mbase 
      >} write_bytes fsxp inum off newdata mscs.
  Proof.
    unfold write_bytes. (* rep, bytes_rep. *)
    step.  (* bfgetattr *)
    step.  (* If *)
    step.  (* grow_file *)

    step.
    step.
    step.

    step.

    apply olddata_exists_in_grown_file; eauto.

    Transparent hidden.
    unfold hidden.

    apply len_olddata_newdata_grown_eq; eauto.

    (* off + length newdata <= length bytes + length (repeat $ (0)
     (off + length newdata - # (INODE.ISize (BFILE.BFAttr f)))) *)
    rewrite repeat_length.
    erewrite length_rep with (bytes := bytes) (f := f); eauto.
    omega.

    step.
    step.
    step.

    (* false branch *)
    apply olddata_exists_in_file with (f := f) (newdata := newdata); eauto.

    rewrite off_length_in_bounds with (bytes := bytes) (newdata := newdata); eauto.

    erewrite len_olddata_newdata_eq with (f := f); eauto.
    constructor.

    rewrite off_length_in_bounds with (bytes := bytes) (newdata := newdata); eauto.
    rewrite off_length_in_bounds with (bytes := bytes) (newdata := newdata); eauto.
  
    step. (* return *)

    Grab Existential Variables.
    all: eauto. 
    exact emp.

  Qed.

End SLOWBYTEFILE.
