Require Import CpdtTactics.
Require Import FsTactics.
Require Import DiskMod.
Require Import Util.
Require Import Smallstep.
Require Import Closures.
Require Import Tactics.
Require Import FsLayout.
Require Import Arith.
Require Import FunctionalExtensionality.
Open Scope fscq.


Definition inodenum := {n: nat | n < NInode}.
Definition NBlockPerInode := SizeBlock - 2.
Definition iblocknum := {n: nat | n < NBlockPerInode}.
Definition ilength := {n: nat | n <= NBlockPerInode}.

Definition eq_inodenum_dec (a b:inodenum) : {a=b}+{a<>b}.
  refine (if eq_nat_dec (proj1_sig a) (proj1_sig b) then _ else _).
  - left. apply sig_pi. auto.
  - right. apply sig_pi_ne. auto.
Defined.

Record inode := Inode {
  IFree: AllocState;
  ILen: ilength;  (* in blocks *)
  IBlocks: iblocknum -> BlocksPartDisk.addr
}.


Module InodeStore <: SmallStepLang.

Inductive prog {R:Type} : Type :=
  | Read (a:inodenum) (rx:inode->prog)
  | Write (a:inodenum) (i:inode) (rx:unit->prog)
  | Return (v:R).
Definition Prog := @prog.
Definition ReturnOp := @Return.
Definition State := inodenum -> inode.

Inductive step {R:Type} : @progstate R Prog State ->
                          @progstate R Prog State -> Prop :=
  | StepRead: forall d a rx,
    step (PS (Read a rx) d)
         (PS (rx (d a)) d)
  | StepWrite: forall d a i rx,
    step (PS (Write a i rx) d)
         (PS (rx tt) (setidx eq_inodenum_dec d a i)).
Definition Step := @step.

End InodeStore.


Module InodeToDisk <: Refines InodeStore InodePartDisk.

Ltac unfold_inode := unfold_fslayout; unfold NBlockPerInode in *.
Ltac omega'inode := omega'unfold unfold_inode.

Obligation Tactic := Tactics.program_simpl; omega'inode.

Program Definition faddr (a:inodenum) : InodePartDisk.addr := a * SizeBlock.
Program Definition laddr (a:inodenum) : InodePartDisk.addr := a * SizeBlock + 1.
Program Definition baddr (a:inodenum) (off:iblocknum) : InodePartDisk.addr :=
  a * SizeBlock + 2 + off.

Ltac unfold_inode2 := unfold faddr in *; unfold laddr in *; unfold baddr in *; unfold_inode.
Ltac omega'inode2 := auto; omega'unfold unfold_inode2.

Program Fixpoint iread_blocklist (R:Type) (a:inodenum)
                                 (n:nat) (NOK:n<=NBlockPerInode)
                                 (bl:iblocknum->BlocksPartDisk.addr) rx :
                                 InodePartDisk.Prog R :=
  match n with
  | 0 => rx bl
  | S x =>
    bx <- InodePartDisk.Read (baddr a x);
    if lt_dec bx BlocksPartSize.Size then
      @iread_blocklist R a x _ (setidxsig eq_nat_dec bl x bx) rx
    else
      @iread_blocklist R a x _ (setidxsig eq_nat_dec bl x 0) rx
  end.

Program Definition iread {R:Type} (a:inodenum) rx : InodePartDisk.Prog R :=
  free <- InodePartDisk.Read (faddr a);
  len <- InodePartDisk.Read (laddr a);
  bl <- @iread_blocklist R a NBlockPerInode _ (fun _ => 0);
  if le_dec len NBlockPerInode then
    rx (Inode (nat2alloc free) len bl)
  else
    rx (Inode (nat2alloc free) 0 bl).

Program Fixpoint iwrite_blocklist (R:Type) (a:inodenum) (i:inode)
                                  (n:nat) (NOK:n<=NBlockPerInode) rx :
                                  InodePartDisk.Prog R :=
  match n with
  | 0 => rx
  | S x =>
    InodePartDisk.Write (baddr a x) (IBlocks i x);;
    @iwrite_blocklist R a i x _ rx
  end.

Program Definition iwrite {R:Type} (a:inodenum) (i:inode) rx : InodePartDisk.Prog R :=
  InodePartDisk.Write (faddr a) (alloc2nat (IFree i));;
  InodePartDisk.Write (laddr a) (ILen i);;
  @iwrite_blocklist R a i NBlockPerInode _ rx.

Fixpoint Compile {R:Type} (p:InodeStore.Prog R) : (InodePartDisk.Prog R) :=
  match p with
  | InodeStore.Read a rx =>
    iread a (fun i => Compile (rx i))
  | InodeStore.Write a i rx =>
    iwrite a i (Compile (rx tt))
  | InodeStore.Return r =>
    InodePartDisk.Return r
  end.

Definition inode_match (i:inode) (d:InodePartDisk.State) (a:inodenum) :=
  IFree i = nat2alloc (d (faddr a)) /\
  proj1_sig (ILen i) = d (laddr a) /\
  forall off, proj1_sig (IBlocks i off) = d (baddr a off).

Inductive statematch : InodeStore.State -> InodePartDisk.State -> Prop :=
  | Match: forall (i:InodeStore.State) (d:InodePartDisk.State)
    (M: forall a, inode_match (i a) d a),
    statematch i d.
Definition StateMatch := statematch.
Hint Constructors statematch.

Lemma star_iread_blocklist:
  forall R a i len rx d (bl:iblocknum->BlocksPartDisk.addr) blfinal Hlen,
  inode_match i d a ->
  (forall off (Hoff: (proj1_sig off) >= len),
   blfinal off = bl off) ->
  (forall off,
   proj1_sig (blfinal off) = d (baddr a off)) ->
  star (InodePartDisk.Step R)
    (PS (progseq2 (iread_blocklist R a len Hlen bl) rx) d)
    (PS (rx blfinal) d).
Proof.
  induction len.
  - intros; unfold progseq2; simpl; replace bl with blfinal; [ apply star_refl | ].
    apply functional_extensionality. crush.
  - intros.
    eapply star_step; [ constructor | ].
    cbv beta.
    match goal with
    | [ |- context[lt_dec (d (baddr a ?len)) BlocksPartSize.Size] ] =>
      destruct (lt_dec (d (baddr a len)) BlocksPartSize.Size)
    end;
    apply IHlen; clear IHlen; auto; try omega; intros.
    + destruct (eq_nat_dec len (proj1_sig off));
      repeat resolve_setidx omega'inode2.
      * apply sig_pi. generalize dependent l.
        repeat rewrite exist_proj_sig. crush.
      * crush.
    + destruct n. destruct H.
      rewrite <- H1. omega'inode2.
Qed.

Lemma star_iread:
  forall R a rx disk i,
  inode_match i disk a ->
  star (InodePartDisk.Step R)
    (PS (iread a rx) disk)
    (PS (rx i) disk).
Proof.
  intros.
  eapply star_step; [ constructor | ].
  eapply star_step; [ constructor | ].
  cbv beta.
  inversion H. Tactics.destruct_pairs.

  assert (forall off, disk (baddr a off) < BlocksPartSize.Size) as Hboff;
  [ intros; rewrite <- H2; omega'inode2 | ].
  pose (blfinal:=fun (off:iblocknum) =>
              exist (fun n: nat => n < NBlockMap * SizeBlock)
                    (disk (baddr a off))
                    (Hboff off)).
  eapply star_trans.
  - eapply star_iread_blocklist with (blfinal:=blfinal); subst blfinal;
    cc; omega'inode2.
  - subst blfinal. cbv beta.
    destruct (le_dec (disk (laddr a)) NBlockPerInode);
    [| destruct n; rewrite <- H1; omega' ].
    match goal with
    | [ |- star _ (PS (rx ?I1) _) (PS (rx ?I2) _) ] =>
      assert (I1=I2); [ | subst; apply star_refl ]
    end.
    destruct i; simpl in *; rewrite <- H0.
    match goal with
    | [ |- Inode ?F1 ?L1 ?B1 = Inode ?F2 ?L2 ?B2 ] =>
      assert (L1=L2) as Hlen; [ apply sig_pi; cc | rewrite Hlen; clear Hlen ]
    end.
    match goal with
    | [ |- Inode ?F1 ?L1 ?B1 = Inode ?F2 ?L2 ?B2 ] =>
      assert (B1=B2) as Hblocks; [| cc ]
    end.
    apply functional_extensionality; intros.
    generalize dependent (Hboff x).
    rewrite <- H2; intros. apply sig_pi. cc.
Qed.

Lemma star_iwrite_blocklist:
  forall R len a i rx d Hlen,
  exists d',
  star (InodePartDisk.Step R)
    (PS (iwrite_blocklist R a i len Hlen rx) d)
    (PS rx d') /\
  (forall off, proj1_sig off < len ->
   d' (baddr a off) = proj1_sig (IBlocks i off)) /\
  (forall b, (proj1_sig b < (proj1_sig a) * SizeBlock + 2 \/
              proj1_sig b >= (proj1_sig a) * SizeBlock + 2 + len) ->
   d' b = d b).
Proof.
  induction len.
  - eexists; split; intros.
    + apply star_refl.
    + crush.
  - intros.
    edestruct IHlen; clear IHlen; Tactics.destruct_pairs.
    eexists. split; [ | split ]; intros.
    + unfold iwrite_blocklist; fold iwrite_blocklist.
      eapply star_step; [ constructor | ]. apply H.
    + destruct (eq_nat_dec (proj1_sig off) len).
      * subst.
        rewrite H1; [ | crush ].
        resolve_setidx omega'inode2; auto.
      * apply H0. omega'inode2.
    + rewrite H1; [ | crush ].
      resolve_setidx omega'inode2. auto.
Qed.

Theorem FSim:
  forall R,
  forward_simulation (InodeStore.Step R) (InodePartDisk.Step R).
Proof.
  intros; fsim_begin (@Compile R) statematch.

  - (* Read *)
    econstructor; split.
    + apply star_iread. instantiate (1:=(s1 a)). auto.
    + constructor; cc.

  - (* Write *)
    edestruct star_iwrite_blocklist. Tactics.destruct_pairs.
    econstructor; split; subst.
    + eapply star_step; [constructor|].
      eapply star_step; [constructor|].
      apply H.
    + clear H. unfold inode_match in M0.
      constructor; cc.
      constructor; [|split]; destruct (eq_inodenum_dec a a0); subst;
      try (rewrite H1; [|omega'inode2];
           repeat resolve_setidx omega'inode2; crush; apply M0; fail).
      intros. rewrite H0; [|omega'inode2]. repeat resolve_setidx omega'inode2. auto.
      intros. rewrite H1; [|omega'inode2]. repeat resolve_setidx omega'inode2. apply M0.
Qed.

End InodeToDisk.