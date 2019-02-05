(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2015-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

module Config = struct
  let naturalsize = MachSize.Word
  let moreedges = false
  let fullmixed = false
end

module Make
    (C:sig
      val naturalsize : MachSize.sz
      val moreedges : bool
      val fullmixed : bool
    end) = struct

open Code
open Printf

include AArch64Base

(* Little endian *)
let tr_endian = Misc.identity

module ScopeGen = ScopeGen.NoGen

(* Mixed size *)
module Mixed =
  MachMixed.Make
    (struct
      let naturalsize = Some C.naturalsize
      let fullmixed = C.fullmixed
    end)

(* AArch64 has more atoms that others *)
let bellatom = false
type atom_rw =  PP | PL | AP | AL
type atom_acc = Plain | Acq | AcqPc | Rel | Atomic of atom_rw
type atom = atom_acc * MachMixed.t option

let default_atom = Atomic PP,None

let applies_atom (a,_) d = match a,d with
| Acq,R
| AcqPc,R
| Rel,W
| (Plain|Atomic _),(R|W)
  -> true
| _ -> false

let applies_atom_rmw ar aw = match ar,aw with
| (Some ((Acq|AcqPc),_)|None),(Some (Rel,_)|None) -> true
| _ -> false

   let pp_plain = "P"
(* Annotation A is taken by load aquire *)
   let pp_as_a = None

   let pp_atom_rw = function
     | PP -> ""
     | PL -> "L"
     | AP -> "A"
     | AL -> "AL"

   let pp_atom_acc = function
     | Atomic rw -> sprintf "X%s" (pp_atom_rw rw)
     | Rel -> "L"
     | Acq -> "A"
     | AcqPc -> "Q"
     | Plain -> "P"

   let pp_atom (a,m) = match a with
   | Plain ->
       begin
         match m with
         | None -> ""
         | Some m -> Mixed.pp_mixed m
       end
   | _ ->
     let pp_acc = pp_atom_acc a in
     match m with
     | None -> pp_acc
     | Some m -> sprintf "%s.%s" pp_acc  (Mixed.pp_mixed m)

   let compare_atom = Pervasives.compare
   let equal_atom a1 a2 = a1 = a2

   let fold_mixed f r =
     Mixed.fold_mixed
       (fun m r -> f (Plain,Some m) r)
       r

   let fold_atom_rw f r = f PP (f PL (f AP (f AL r)))

   let fold_acc f r =
     f Acq (f AcqPc (f Rel (fold_atom_rw (fun rw -> f (Atomic rw)) r)))

   let fold_non_mixed f r = fold_acc (fun acc r -> f (acc,None) r) r

   let fold_atom f r =
     fold_acc
       (fun acc r ->
         Mixed.fold_mixed
           (fun m r -> f (acc,Some m) r)
           (f (acc,None) r))
       (fold_mixed f r)

   let worth_final (a,_) = match a with
     | Atomic _ -> true
     | Acq|AcqPc|Rel|Plain -> false


   let varatom_dir _d f r = f None r

   let merge_atoms a1 a2 = match a1,a2 with
   | ((Plain,sz),(a,None))
   | ((a,None),(Plain,sz)) -> Some (a,sz)
   | ((a1,None),(a2,sz))
   | ((a1,sz),(a2,None)) when a1=a2 -> Some (a1,sz)
   | ((Plain,sz1),(a,sz2))
   | ((a,sz1),(Plain,sz2)) when sz1=sz2 -> Some (a,sz1)
   | _,_ ->
       if equal_atom a1 a2 then Some a1 else None

   let tr_value ao v = match ao with
   | None| Some (_,None) -> v
   | Some (_,Some (sz,_)) -> Mixed.tr_value sz v

   module ValsMixed =
     MachMixed.Vals
       (struct
         let naturalsize () = C.naturalsize
         let endian = endian
       end)

let overwrite_value v ao w = match ao with
  | None| Some ((Atomic _|Acq|AcqPc|Rel|Plain),None) -> w (* total overwrite *)
  | Some ((Atomic _|Acq|AcqPc|Rel|Plain),Some (sz,o)) ->
      ValsMixed.overwrite_value v sz o w

 let extract_value v ao = match ao with
  | None| Some ((Atomic _|Acq|AcqPc|Rel|Plain),None) -> v
  | Some ((Atomic _|Acq|AcqPc|Rel|Plain),Some (sz,o)) ->
      ValsMixed.extract_value v sz o

(* End of atoms *)

(**********)
(* Fences *)
(**********)

type fence = barrier

let is_isync = function
  | ISB -> true
  | _ -> false

let compare_fence = barrier_compare

let default = DMB (SY,FULL)
let strong = default

let pp_fence f = do_pp_barrier "." f

let fold_cumul_fences f k = do_fold_dmb_dsb C.moreedges f k

let fold_all_fences f k = fold_barrier  C.moreedges f k

let fold_some_fences f k =
  let k = f ISB k  in
  let k = f (DMB (SY,FULL)) k in
  let k = f (DMB (SY,ST)) k in
  let k = f (DMB (SY,LD)) k in
  k

let orders f d1 d2 = match f,d1,d2 with
| ISB,_,_ -> false
| (DSB (_,FULL)|DMB (_,FULL)),_,_ -> true
| (DSB (_,ST)|DMB (_,ST)),W,W -> true
| (DSB (_,ST)|DMB (_,ST)),_,_ -> false
| (DSB (_,LD)|DMB (_,LD)),Code.R,(W|Code.R) -> true
| (DSB (_,LD)|DMB (_,LD)),_,_ -> false


let var_fence f r = f default r

(********)
(* Deps *)
(********)
include Dep

let pp_dp = function
  | ADDR -> "Addr"
  | DATA -> "Data"
  | CTRL -> "Ctrl"
  | CTRLISYNC -> "CtrlIsb"

include
    ArchExtra_gen.Make
    (struct
      type arch_reg = reg

      let is_symbolic = function
        | Symbolic_reg _ -> true
        | _ -> false

      let pp_reg = pp_reg
      let free_registers = allowed_for_symb
    end)

end
